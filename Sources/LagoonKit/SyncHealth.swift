import Foundation

/// Sync health surfaced by `GET /api/accounts` and rendered by the client.
/// `needsReconnect` stops the retry loop until credentials are re-entered.
public struct SyncHealth: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case ok
        case degraded
        case needsReconnect
        case error
    }

    public var status: Status
    public var lastSyncAt: Date?
    public var lastError: String?

    public init(status: Status, lastSyncAt: Date? = nil, lastError: String? = nil) {
        self.status = status
        self.lastSyncAt = lastSyncAt
        self.lastError = lastError
    }
}
