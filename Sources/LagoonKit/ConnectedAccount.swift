import Foundation

/// Response payload of GET /api/accounts. Shared between server and client.
///
/// This is the OAuth completion handshake for M0: the macOS app is a bare
/// SwiftPM executable with no `Info.plist`, so it cannot register a custom URL
/// scheme and the server cannot deep-link the new `accountId` back to it.
/// Instead the client polls this endpoint while the connect screen is visible.
///
/// Contract: HTTP 200, `application/json; charset=utf-8`, a JSON array in any
/// order (empty array when nothing is connected). No other fields are added
/// without bumping the client.
public struct ConnectedAccount: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let provider: MailProvider
    public let email: String

    public init(id: UUID, provider: MailProvider, email: String) {
        self.id = id
        self.provider = provider
        self.email = email
    }
}
