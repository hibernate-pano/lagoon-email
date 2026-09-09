import Foundation

/// Lightweight progress marker returned from /api/messages
/// so the client knows whether to poll again or wait.
public struct SyncCursor: Codable, Equatable, Sendable {
    public let accountId: UUID
    public let lastFetchedAt: Date
    public let totalUnread: Int

    public init(accountId: UUID, lastFetchedAt: Date, totalUnread: Int) {
        self.accountId = accountId
        self.lastFetchedAt = lastFetchedAt
        self.totalUnread = totalUnread
    }
}