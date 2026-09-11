import Foundation

public struct Account: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let provider: MailProviderKind
    public let oauthUser: String
    public let email: String
    /// AES-GCM sealed `AccountCredentials` blob. nil only for legacy rows
    /// created before migration 008, which surface as `needsReconnect`.
    public let credentials: Data?
    public let syncState: MailSyncState
    public let capabilities: MailCapabilities
    public let isActive: Bool
    public let syncHealth: SyncHealth

    public init(
        id: UUID,
        provider: MailProviderKind,
        oauthUser: String,
        email: String,
        credentials: Data?,
        syncState: MailSyncState = MailSyncState(),
        capabilities: MailCapabilities = .unknown,
        isActive: Bool = false,
        syncHealth: SyncHealth = SyncHealth(status: .ok)
    ) {
        self.id = id
        self.provider = provider
        self.oauthUser = oauthUser
        self.email = email
        self.credentials = credentials
        self.syncState = syncState
        self.capabilities = capabilities
        self.isActive = isActive
        self.syncHealth = syncHealth
    }
}
