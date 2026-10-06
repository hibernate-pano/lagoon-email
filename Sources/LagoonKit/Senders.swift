import Foundation

// 发件人排行（`GET /api/senders`）的共享 wire 类型。
//
// 与 Server + client 各自编码解码同一份定义 —— 合同漂移会在编译期暴露。

/// One sender's row in the ranking.
///
/// `totalCount` and `unreadCount` are separate because the interesting cases are
/// the *mismatches*: 340 messages with 0 unread means the user stopped reading
/// them a long time ago, and 3 messages with 3 unread means they just arrived.
/// A single number cannot distinguish those, and the distinction is the whole
/// point of the panel — it is the answer to Inbox Zero's most-used question,
/// "who sends me the most mail".
public struct SenderSummary: Codable, Equatable, Sendable, Identifiable {
    /// The address itself — stable across regenerations, unlike a display name.
    public let address: String
    /// Best available display name, or nil when the mail carried none.
    public let displayName: String?
    public let totalCount: Int
    public let unreadCount: Int
    public let latestAt: Date

    public var id: String { address }

    public init(
        address: String,
        displayName: String?,
        totalCount: Int,
        unreadCount: Int,
        latestAt: Date
    ) {
        self.address = address
        self.displayName = displayName
        self.totalCount = totalCount
        self.unreadCount = unreadCount
        self.latestAt = latestAt
    }

    /// Whether this sender has mail the user has not opened.
    ///
    /// A heuristic, stated as one: "many messages, none still unread" is the
    /// shape of a subscription the user has silently stopped reading. It is
    /// offered in the UI as a *question* — file this sender, unsubscribe? —
    /// never as the decision (constitution §2 rule 5).
    public var looksUnread: Bool { unreadCount > 0 }

    /// True when there is enough mail for that question to be worth asking.
    ///
    /// Below the threshold the row is just a correspondent, and offering
    /// "archive this sender" for someone who wrote twice is noise.
    public var isWorthCollapsing: Bool { totalCount >= 10 }
}

public struct SenderListResponse: Codable, Equatable, Sendable {
    public let senders: [SenderSummary]
    public init(senders: [SenderSummary]) {
        self.senders = senders
    }
}