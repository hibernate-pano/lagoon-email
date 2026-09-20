import Foundation

/// Response payload of GET /api/accounts. Shared between server and client.
///
/// This is the OAuth completion handshake for M0: the macOS app is a bare
/// SwiftPM executable with no `Info.plist`, so it cannot register a custom URL
/// scheme and the server cannot deep-link the new `accountId` back to it.
/// Instead the client polls this endpoint while the connect screen is visible.
///
/// `isActive` is the server's single sync owner. Other accounts remain stored
/// but dormant. `unreadCount` is the local cached count for this mailbox.
public struct ConnectedAccount: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let provider: MailProviderKind
    public let email: String
    public let isActive: Bool
    public let unreadCount: Int
    public let syncHealth: SyncHealth
    public let capabilities: MailCapabilities

    public init(
        id: UUID,
        provider: MailProviderKind,
        email: String,
        isActive: Bool = false,
        unreadCount: Int = 0,
        syncHealth: SyncHealth,
        capabilities: MailCapabilities
    ) {
        self.id = id
        self.provider = provider
        self.email = email
        self.isActive = isActive
        self.unreadCount = unreadCount
        self.syncHealth = syncHealth
        self.capabilities = capabilities
    }
}
