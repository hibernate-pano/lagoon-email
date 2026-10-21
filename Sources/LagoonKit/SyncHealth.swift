import Foundation

/// Sync health surfaced by `GET /api/accounts` and rendered by the client.
/// `needsReconnect` stops the retry loop until credentials are re-entered.
public struct SyncHealth: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case ok
        case degraded
        case needsReconnect
        case error
        /// The account row **could not be found** by the id the client holds.
        ///
        /// This is not a health problem the user can fix by re-entering their
        /// authorization code, and it is not one the user caused. It means
        /// the store and the client's idea of the account have diverged —
        /// the row is missing, or it is stored under an id the server cannot
        /// match.
        ///
        /// It exists as its own status because the alternative was a lie. A
        /// missing row used to end up as `needsReconnect`, which the client
        /// rendered as "your authorization code expired" — and the user was
        /// sent to re-enter a perfectly good authorization code, which
        /// changed nothing, because the write went to a row the server
        /// still could not find. The user was stuck in a loop, being told
        /// the wrong thing, with no way out.
        ///
        /// A distinct status lets the client say what is actually true: the
        /// mailbox is not reachable *from this store*, and re-entering the
        /// code will not help.
        case accountMissing
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
