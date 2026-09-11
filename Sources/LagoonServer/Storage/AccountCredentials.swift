import Foundation
import PostgresNIO
import LagoonKit

/// Provider-tagged credential payload stored (AES-GCM sealed) in
/// `accounts.credentials`. Adding a provider means adding a case here and in
/// `MailProviderKind`; nothing else in storage needs to know the shape.
public enum AccountCredentials: Codable, Sendable, Equatable {
    case gmail(accessToken: String, refreshToken: String, expiresAt: Date)
    case imap(username: String, authCode: String)

    private enum CodingKeys: String, CodingKey {
        case kind, accessToken, refreshToken, expiresAt, username, authCode
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .gmail(let accessToken, let refreshToken, let expiresAt):
            try c.encode("gmail", forKey: .kind)
            try c.encode(accessToken, forKey: .accessToken)
            try c.encode(refreshToken, forKey: .refreshToken)
            try c.encode(expiresAt, forKey: .expiresAt)
        case .imap(let username, let authCode):
            try c.encode("imap", forKey: .kind)
            try c.encode(username, forKey: .username)
            try c.encode(authCode, forKey: .authCode)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "gmail":
            self = .gmail(
                accessToken: try c.decode(String.self, forKey: .accessToken),
                refreshToken: try c.decode(String.self, forKey: .refreshToken),
                expiresAt: try c.decode(Date.self, forKey: .expiresAt)
            )
        case "imap":
            self = .imap(
                username: try c.decode(String.self, forKey: .username),
                authCode: try c.decode(String.self, forKey: .authCode)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c, debugDescription: "unknown credential kind"
            )
        }
    }
}

/// The only reader/writer of `accounts.credentials`: AES-GCM sealed JSON.
/// Never log a reader's result — both cases hold live secrets.
public enum CredentialVault {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public static func seal(_ credentials: AccountCredentials) throws -> Data {
        let json = try encoder.encode(credentials)
        return try AccessTokenCipher.seal(String(decoding: json, as: UTF8.self))
    }

    public static func open(_ blob: Data) throws -> AccountCredentials {
        let json = try AccessTokenCipher.open(blob)
        guard let data = json.data(using: .utf8) else { throw TokenCipherError.notUTF8 }
        return try decoder.decode(AccountCredentials.self, from: data)
    }

    public static func write(
        _ credentials: AccountCredentials,
        accountId: UUID,
        db: PostgresConnection
    ) async throws {
        try await db.query(
            "UPDATE accounts SET credentials = $2, updated_at = now() WHERE id = $1",
            [PostgresData(uuid: accountId), PostgresData(bytes: try seal(credentials))]
        ).get()
    }

    public static func read(
        accountId: UUID,
        db: PostgresConnection
    ) async throws -> AccountCredentials {
        let result = try await db.query(
            "SELECT credentials FROM accounts WHERE id = $1",
            [PostgresData(uuid: accountId)]
        ).get()
        guard let row = result.rows.first,
              let blob = try row.makeRandomAccess()["credentials"].decode(Data?.self)
        else { throw AccountStoreError.notFound }
        return try open(blob)
    }
}
