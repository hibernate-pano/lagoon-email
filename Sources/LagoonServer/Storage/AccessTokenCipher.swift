import Foundation
import Crypto
import PostgresNIO
import LagoonKit

public enum TokenCipherError: Error {
    case missingKey
    case badKey
    case notUTF8
}

/// Server-side AES-256-GCM for OAuth token blobs.
///
/// The key is `LAGOON_TOKEN_KEY`: base64 of exactly 32 random bytes.
/// Stored blobs are `AES.GCM.SealedBox.combined` (nonce || ciphertext || tag).
/// This is intentionally fail-closed: a missing or malformed key throws and we
/// never read or write a plaintext token. (A client-keychain key is impossible
/// here — the server must decrypt the token to call Gmail on the user's behalf.)
public enum AccessTokenCipher {
    public struct StoredCredentials: Sendable {
        public let accessToken: String
        public let refreshToken: String
        public let expiresAt: Date

        public init(accessToken: String, refreshToken: String, expiresAt: Date) {
            self.accessToken = accessToken
            self.refreshToken = refreshToken
            self.expiresAt = expiresAt
        }
    }

    /// Encrypt `plaintext` into `AES.GCM.SealedBox.combined`.
    public static func seal(_ plaintext: String) throws -> Data {
        let key = try loadKey()
        let sealed = try AES.GCM.seal(Data(plaintext.utf8), using: key)
        guard let combined = sealed.combined else { throw TokenCipherError.badKey }
        return combined
    }

    /// Decrypt an `AES.GCM.SealedBox.combined` blob back to a UTF-8 string.
    public static func open(_ blob: Data) throws -> String {
        let key = try loadKey()
        let box = try AES.GCM.SealedBox(combined: blob)
        let plaintext = try AES.GCM.open(box, using: key)
        guard let text = String(data: plaintext, encoding: .utf8) else {
            throw TokenCipherError.notUTF8
        }
        return text
    }

    /// Read and decrypt both token blobs for an account.
    public static func read(
        accountId: UUID,
        db: PostgresConnection
    ) async throws -> StoredCredentials {
        let sql = "SELECT access_token, refresh_token, token_expires_at FROM accounts WHERE id = $1"
        let result = try await db.query(sql, [PostgresData(uuid: accountId)]).get()
        guard let row = result.rows.first else { throw AccountStoreError.notFound }
        let r = row.makeRandomAccess()
        let accessBlob: Data = try r["access_token"].decode(Data.self)
        let refreshBlob: Data = try r["refresh_token"].decode(Data.self)
        let expiresAt: Date = try r["token_expires_at"].decode(Date.self)
        return StoredCredentials(
            accessToken: try open(accessBlob),
            refreshToken: try open(refreshBlob),
            expiresAt: expiresAt
        )
    }

    /// Validate `LAGOON_TOKEN_KEY` without touching any data. Called at startup.
    public static func validateKey() throws {
        _ = try loadKey()
    }

    private static func loadKey() throws -> SymmetricKey {
        guard let raw = ProcessInfo.processInfo.environment["LAGOON_TOKEN_KEY"], !raw.isEmpty else {
            throw TokenCipherError.missingKey
        }
        guard let data = Data(base64Encoded: raw), data.count == 32 else {
            throw TokenCipherError.badKey
        }
        return SymmetricKey(data: data)
    }
}
