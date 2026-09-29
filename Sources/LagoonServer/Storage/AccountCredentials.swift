import Foundation
import GRDB
import LagoonKit

public enum StoreError: Error {
    case insertFailed
}

/// Provider-tagged credential payload stored (AES-GCM sealed) in
/// `accounts.credentials`.
///
/// One case, but the enum shape and the `kind` tag stay: the tag is what makes
/// a sealed blob self-describing, so a future provider with a different payload
/// adds a case here instead of reinterpreting existing bytes. The decoder
/// rejects any unknown `kind` rather than guessing.
public enum AccountCredentials: Codable, Sendable, Equatable {
    case imap(username: String, authCode: String)

    private enum CodingKeys: String, CodingKey {
        case kind, username, authCode
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .imap(let username, let authCode):
            try c.encode("imap", forKey: .kind)
            try c.encode(username, forKey: .username)
            try c.encode(authCode, forKey: .authCode)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
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
        db: LagoonDB
    ) async throws {
        try db.write {
            try $0.execute(
                sql: "UPDATE accounts SET credentials = ?, updated_at = strftime('%Y-%m-%d %H:%M:%f','now') WHERE id = ?",
                arguments: [try seal(credentials), accountId]
            )
        }
    }

    public static func read(
        accountId: UUID,
        db: LagoonDB
    ) async throws -> AccountCredentials {
        return try db.read { db in
            let blob: Data? = try Row.fetchOne(
                db,
                sql: "SELECT credentials FROM accounts WHERE id = ?",
                arguments: [accountId]
            )?["credentials"]
            guard let blob else { throw AccountStoreError.notFound }
            return try open(blob)
        }
    }
}
