import Foundation

// 侧边栏计数（`GET /api/folder-counts`）的共享 wire 类型。
//
// 与 Server + client 各自编码解码同一份定义 —— 合同漂移会在编译期暴露，
// 而不是等到某个计数在侧边栏里默默变成 0。
//
// 设计取舍：不用一个固定 struct，而是「稳定字符串 id → 计数」的字典。
// 侧边栏的行是 UI 的关切（会随产品增减），而写进共享 wire 类型意味着每加
// 一行都要两端一起改。`FolderCountKey` 把固定的那几个键名固定下来，
// 测试断言它们，防止拼错静默发货。

/// One sidebar destination's tally.
public struct FolderCount: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let count: Int

    public init(id: String, count: Int) {
        self.id = id
        self.count = count
    }
}

/// The fixed keys `FolderCounts.asCounts` emits.
public enum FolderCountKey {
    public static let live = "live"
    public static let unread = "unread"
    public static let archived = "archived"
    public static let pinned = "pinned"
    public static let deleted = "deleted"
    /// 已发送 (R1). Counted from the local table, which only knows about sent
    /// mail once 已发送 has been opened at least once — the badge is honest
    /// about being a lower bound rather than guessing.
    public static let sent = "sent"

    public static let all: [String] = [live, unread, archived, pinned, deleted, sent]
}

/// `GET /api/folder-counts?accountId=` response.
///
/// Only the buckets that no other endpoint answers for: the user's 聚合规则
/// counts ride along with `/api/stacks` (each `StackSummary` carries its own
/// `count`), and 订阅噪音 is a classifier verdict rather than a stored column,
/// so the feed links to it instead of restating it here.
public struct FolderCounts: Codable, Equatable, Sendable {
    public let live: Int
    public let unread: Int
    public let archived: Int
    public let pinned: Int
    public let deleted: Int
    /// 已发送 (R1). Optional so a payload encoded before this field existed
    /// still decodes — the client then simply shows no badge rather than 0,
    /// which would be a claim it cannot support yet.
    public let sent: Int?

    public init(
        live: Int,
        unread: Int,
        archived: Int,
        pinned: Int,
        deleted: Int,
        sent: Int? = nil
    ) {
        self.live = live
        self.unread = unread
        self.archived = archived
        self.pinned = pinned
        self.deleted = deleted
        self.sent = sent
    }

    public var asCounts: [FolderCount] {
        [
            FolderCount(id: FolderCountKey.live, count: live),
            FolderCount(id: FolderCountKey.unread, count: unread),
            FolderCount(id: FolderCountKey.archived, count: archived),
            FolderCount(id: FolderCountKey.pinned, count: pinned),
            FolderCount(id: FolderCountKey.deleted, count: deleted),
        ] + (sent.map { [FolderCount(id: FolderCountKey.sent, count: $0)] } ?? [])
    }
}

public struct FolderCountsResponse: Codable, Equatable, Sendable {
    public let counts: [FolderCount]

    public init(counts: FolderCounts) {
        self.counts = counts.asCounts
    }
}