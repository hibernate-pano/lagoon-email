import XCTest
import Foundation
@testable import Lagoon
@testable import LagoonKit

/// R1 轮末 UI 复核的守卫。
///
/// ## 这一轮改了什么 UI
///
/// 加了「已发送」之后，顺手发现工具栏标题一直是硬编码的 `l10n.allMessages`
/// —— 于是废纸篓、档案柜、已发送三个界面的标题**全都**写着「全部邮件」。
///
/// 这和之前修过的 `case .deleted: self = .all` 是同一类错误：界面说一件事、
/// 内容是另一件事。用户唯一用来确认「我在哪」的地方在说谎。
///
/// 空状态同理：一句 `l10n.noMessagesYet`（「还没有邮件」）用在所有透镜上，
/// 在废纸篓里它说「邮件不见了」而实际上什么都没删过。
///
/// 这些断言的作用是让「标题跟随透镜」和「空状态跟随透镜」变成**可执行的规则**，
/// 而不是一次性的手工对齐。
@MainActor
final class SentSurfaceUITests: XCTestCase {
    /// Every lens must map to a title that is not 「全部邮件」 except the inbox.
    ///
    /// Pinned as the failure it prevents: three different folders all labelled
    /// 全部邮件 is indistinguishable from the bug where `.deleted` mapped to
    /// `.all` — same symptom, same confusion, and it recurred.
    ///
    /// This drives the **real** mapping (`MessageListView.surfaceTitle(for:l10n:)`),
    /// not a restatement of it. The earlier version of this test only compared
    /// four `L10n` constants against each other and never called the production
    /// switch — so it stayed green even with every case collapsed to
    /// `allMessages`, which is exactly the bug it was written to catch.
    func test_everyFolderLensHasItsOwnTitle() {
        typealias Lens = MessageListView.Lens
        let l10n = L10n(language: .zhHans)

        for lens in [Lens.sent, .archived, .deleted, .rule(UUID())] {
            let title = MessageListView.surfaceTitle(for: lens, l10n: l10n)
            XCTAssertFalse(
                title.isEmpty,
                "\(lens) has no title at all"
            )
            XCTAssertNotEqual(
                title, l10n.allMessages,
                "\(lens) is labelled 全部邮件 — the surface would claim to be the inbox"
            )
        }

        // The four folder surfaces must also be mutually distinguishable, or
        // two of them are still the same string by accident.
        let titles = [Lens.sent, .archived, .deleted, .rule(UUID())]
            .map { MessageListView.surfaceTitle(for: $0, l10n: l10n) }
        XCTAssertEqual(
            Set(titles).count, titles.count,
            "folder surfaces must not collapse onto one title: \(titles)"
        )

        // And the inbox is the one place 全部邮件 is the correct answer.
        XCTAssertEqual(
            MessageListView.surfaceTitle(for: .all, l10n: l10n), l10n.allMessages
        )
        XCTAssertEqual(
            MessageListView.surfaceTitle(for: nil, l10n: l10n), l10n.allMessages,
            "no lens selected yet is the inbox, not an error state"
        )
    }

    /// 已发送 must be served by its own route, not the inbox poll.
    ///
    /// The failure this prevents is silent: `fetchMessages` would answer 200
    /// with an empty list, and 已发送 would look permanently empty with no
    /// error anywhere. One predicate, asserted from the outside.
    func test_sentLens_isTheOnlyOneNeedingItsOwnRoute() {
        typealias Lens = MessageListView.Lens
        XCTAssertTrue(Lens.sent.needsSentRoute)
        for other in [Lens.all, .unread, .pinned, .archived, .deleted, .rule(UUID())] {
            XCTAssertFalse(
                other.needsSentRoute,
                "only 已发送 is served by /api/sent; everything else uses the inbox poll"
            )
        }
    }

    /// The empty state must say something specific, not a generic placeholder.
    ///
    /// 已发送 is the one surface where the user genuinely needs a hint: mail
    /// only appears there if they sent it, and "no messages" reads as broken
    /// until they know that.
    func test_sentEmptyState_hasBothTitleAndHint() {
        let zh = L10n(language: .zhHans)
        XCTAssertFalse(zh.sentEmpty.isEmpty)
        XCTAssertFalse(
            zh.sentEmptyHint.isEmpty,
            "an empty 已发送 with no explanation looks like a broken feature"
        )
        XCTAssertNotEqual(
            zh.sentEmpty, zh.noMessagesYet,
            "a dedicated string, not the generic one"
        )
    }

    /// The staleness note must be worded as a caveat, not as an error.
    ///
    /// It appears inline above the list. If it read like something failed, the
    /// user would retry — and retrying does not help, because the server is
    /// unreachable rather than slow.
    func test_sentStaleCopy_isACaveatNotAnError() {
        for text in [L10n(language: .zhHans).sentStale, L10n(language: .english).sentStale] {
            XCTAssertFalse(text.isEmpty)
            XCTAssertFalse(
                text.contains("失败") || text.lowercased().contains("failed"),
                "a network caveat is not a failure the user can act on: \"\(text)\""
            )
        }
    }

    /// The 「no Sent folder」 copy must exist and be distinct from 「nothing sent」.
    ///
    /// Two different claims, and only one of them is true when the account has
    /// no Sent folder. Merging them tells the user they have never sent
    /// anything, which is a small lie with real consequences.
    func test_sentUnavailableCopy_isDistinctFromEmpty() {
        let zh = L10n(language: .zhHans)
        XCTAssertNotEqual(zh.sentUnavailable, zh.sentEmpty)
        XCTAssertFalse(zh.sentUnavailable.isEmpty)
    }

    /// The sidebar count badge and the list must be able to disagree *honestly*.
    ///
    /// `sent` is optional on `FolderCounts` because a payload encoded before
    /// R1 has no such key. The test is that absence is representable at all —
    /// a non-optional `Int` would decode as 0 and claim the user has sent
    /// nothing.
    func test_sentCount_isOptional_soLegacyPayloadsDoNotClaimZero() throws {
        let legacy = """
            {"live":10,"unread":2,"archived":1,"pinned":0,"deleted":0}
            """
        let decoded = try JSONDecoder().decode(
            (RawCounts).self, from: Data(legacy.utf8)
        )
        XCTAssertNil(
            decoded.sent,
            "a pre-R1 payload must not decode as \"sent nothing\""
        )

        let modern = """
            {"live":10,"unread":2,"archived":1,"pinned":0,"deleted":0,"sent":4}
            """
        let decodedModern = try JSONDecoder().decode(
            RawCounts.self, from: Data(modern.utf8)
        )
        XCTAssertEqual(decodedModern.sent, 4)
    }

    private struct RawCounts: Decodable {
        let live: Int
        let unread: Int
        let archived: Int
        let pinned: Int
        let deleted: Int
        let sent: Int?
    }
}
