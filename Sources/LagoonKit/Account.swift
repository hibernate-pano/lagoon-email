import Foundation

public enum MailProvider: String, Codable, Sendable, CaseIterable {
    case gmail
}

public struct Account: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let provider: MailProvider
    public let oauthUser: String
    public let email: String
    public let tokenExpiresAt: Date
    public let historyId: String?

    public init(
        id: UUID,
        provider: MailProvider,
        oauthUser: String,
        email: String,
        tokenExpiresAt: Date,
        historyId: String?
    ) {
        self.id = id
        self.provider = provider
        self.oauthUser = oauthUser
        self.email = email
        self.tokenExpiresAt = tokenExpiresAt
        self.historyId = historyId
    }
}