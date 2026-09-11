import Foundation

/// Response payload of GET /api/accounts. Shared between server and client.
///
/// This is the OAuth completion handshake for M0: the macOS app is a bare
/// SwiftPM executable with no `Info.plist`, so it cannot register a custom URL
/// scheme and the server cannot deep-link the new `accountId` back to it.
/// Instead the client polls this endpoint while the connect screen is visible.
///
/// M1.5 adds `isActive` / `syncHealth` / `capabilities` so the client can show
/// sync state and disable unreachable verbs (e.g. archive without a folder).
public struct ConnectedAccount: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let provider: MailProviderKind
    public let email: String
    public let isActive: Bool
    public let syncHealth: SyncHealth
    public let capabilities: MailCapabilities

    public init(
        id: UUID,
        provider: MailProviderKind,
        email: String,
        isActive: Bool,
        syncHealth: SyncHealth,
        capabilities: MailCapabilities
    ) {
        self.id = id
        self.provider = provider
        self.email = email
        self.isActive = isActive
        self.syncHealth = syncHealth
        self.capabilities = capabilities
    }
}
