import XCTest
import Foundation
@testable import Lagoon

/// `SenderSheet` 的两个批量动词必须是**有界**扇出。
///
/// ## 这里防的是什么
///
/// `deleteAll` 和 `bulk` 曾经把每个 id 直接 `group.addTask` 扔进
/// `withTaskGroup`——`withTaskGroup` 自己不设上限，所以那和它替换掉的
/// `for` 循环一样没有边界。这段代码原来的注释替这个决定背书，理由是
/// 「单个发件人也就几十封」。那个假设是错的：发件人面板列的是该发件人的
/// **全部**历史邮件，营销/通知类地址几百上千封是常态。用户点「全部删除」
/// 或「全部标为已读」时，就是几百个写请求同时打向那条唯一的 IMAP 连接，
/// 30 秒一次的轮询排在它们后面，界面看起来像卡死。
///
/// 这个仓库里有两次同样的修复（`MessageListView.runBulk`、
/// `BriefingFeedView.markBulk`），它们的形状都是**先填满窗口、再每完成
/// 一个放行一个**。这里守的就是这个形状，防止第三次回退。
///
/// ## 为什么是源码级
///
/// 这两个方法挂在 SwiftUI 视图上，依赖 `APIClient.shared` 和真实账号，
/// 单测跑不起来。能检查、也确实坏过的，是调度形状本身：有没有窗口、
/// 窗口是不是在补位、有没有退回一次性全扔。行为语义（失败统计、
/// `firstError`、banner）有别的测试覆盖，这里只钉住调度。
final class SenderBulkConcurrencyTests: XCTestCase {

    private func senderSource() throws -> String {
        try ViewSource.read("SenderSheet")
    }

    /// 截出源码里某一个方法的完整函数体。
    ///
    /// 刻意**不用** `ViewSource.code(after:in:limit:)` 的固定 `limit`：
    /// 那个参数是**字符数**不是行数，函数体一改长就会被无声截断，
    /// 截断后的区域里断言「不含某写法」永远成立——一个因为没读到代码
    /// 而通过的守卫，比没有守卫更糟。这里按方法自己的收尾花括号（缩进
    /// 恰好四格的 `}`）定位终点，长度随源码走。
    private func functionBody(signature: String, in source: String) throws -> String {
        let start = try XCTUnwrap(
            source.range(of: signature),
            "找不到方法签名：\(signature)"
        )
        let rest = source[start.upperBound...]
        // 方法体内部的闭包/分支都比四格更深，所以第一行恰好是四格 `}`
        // 的位置就是方法自己的收尾。
        let end = try XCTUnwrap(
            rest.range(of: "\n    }\n"),
            "找不到方法结束的花括号：\(signature)"
        )
        let limit = source.distance(from: start.lowerBound, to: end.upperBound)
        return ViewSource.code(after: start.lowerBound, in: source, limit: limit)
    }

    // MARK: - 两个批量动词都有窗口

    /// `deleteAll` 必须先填窗再补位，而不是一次性全扔。
    func test_deleteAll_usesABoundedWindow() throws {
        let body = try functionBody(
            signature: "private func deleteAll() async {",
            in: try senderSource()
        )
        try assertBoundedWindow(in: body, name: "deleteAll")
    }

    /// `bulk(_:)`（mark-all-read 的执行体）同理。
    func test_markReadBulk_usesABoundedWindow() throws {
        let body = try functionBody(
            signature: "private func bulk(",
            in: try senderSource()
        )
        try assertBoundedWindow(in: body, name: "bulk")
    }

    /// 有界窗口的骨架，和 `MessageListView.runBulk` 同一套写法：
    ///
    /// 1. 一个游标 `next` 从 0 开始；
    /// 2. 先填满 `min(bulkConcurrency, count)` 个任务；
    /// 3. 每 `group.next()` 拿到一个结果，放行一个；
    /// 4. 没有 `for id in ids` 那种一次全扔的循环。
    private func assertBoundedWindow(in body: String, name: String) throws {
        XCTAssertTrue(
            body.contains("var next = 0"),
            "\(name) must use a cursor to fill the window; body was:\n\(body)"
        )
        XCTAssertTrue(
            body.contains("while next < min(Self.bulkConcurrency, ids.count)"),
            "\(name) must prime the window to the cap; body was:\n\(body)"
        )
        XCTAssertTrue(
            body.contains("guard next < ids.count else { continue }"),
            "\(name) must top the window up per completion; body was:\n\(body)"
        )
        XCTAssertFalse(
            body.contains("for id in ids"),
            "\(name) must not fire every id at once — that is the unbounded shape this guard exists for"
        )
        // 两个 addTask：填窗一次、补位一次。退回一次性全扔会只剩一个
        // （在 `for` 里），窗口被删掉则一个都不剩。
        let addTasks = body.components(separatedBy: "group.addTask").count - 1
        XCTAssertEqual(
            addTasks, 2,
            "\(name) must add tasks exactly twice (fill + top-up), found \(addTasks)"
        )
    }

    // MARK: - 上限本身

    /// 上限是 8，和「全部邮件」页同一个数、同一段理由。
    func test_theCapIsEight() throws {
        let source = try senderSource()
        XCTAssertTrue(
            source.contains("private static let bulkConcurrency = 8"),
            "SenderSheet must define its own cap, matching MessageListView.bulkConcurrency"
        )
    }

    /// 上限的注释必须交代真实理由：共享连接 + 30 秒轮询。
    ///
    /// 这条不是给注释挑字眼——上一轮的错误就在于注释在为一个错误决定
    /// 背书（「几十封，几秒就完成」）。理由写错，下一个人就会照着它把
    /// 窗口删掉。
    func test_theCapComment_statesTheRealReason() throws {
        let source = try senderSource()
        let cap = try XCTUnwrap(
            source.range(of: "private static let bulkConcurrency = 8"),
            "cap constant missing"
        )
        // 常量声明上方是它的文档注释；取前 1200 个字符足够覆盖，注释行
        // 被 `code(after:)` 保留（该方法只删 `//` 开头的行，块注释外）。
        let prefixStart = source.range(
            of: "/// 批量请求同时在途的上限。", range: source.startIndex..<cap.lowerBound
        )
        XCTAssertNotNil(prefixStart, "the cap must keep its explanatory doc comment")
        let doc = source[prefixStart!.lowerBound..<cap.upperBound]
        XCTAssertTrue(doc.contains("IMAP"), "the cap comment must name the shared IMAP connection")
        XCTAssertTrue(doc.contains("30 秒"), "the cap comment must name the 30s poll it protects")
    }

    /// 那个为错误决定背书的旧说法不许回来。
    func test_theOldVolumeAssumptionIsGone() throws {
        let source = try senderSource()
        XCTAssertFalse(
            source.contains("dozens, not thousands"),
            "the \"a sender only has dozens\" assumption was false (hundreds is normal) and must not return"
        )
        XCTAssertFalse(
            source.contains("几十封，不是几千封"),
            "the Chinese version of the same false assumption must not return either"
        )
    }
}
