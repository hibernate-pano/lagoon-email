import Foundation
import Crypto

public enum TokenCipherError: Error {
    case missingKey
    case badKey
    case notUTF8
}

/// Server-side AES-256-GCM for secret blobs (OAuth tokens, IMAP auth codes).
///
/// The key is `LAGOON_TOKEN_KEY`: base64 of exactly 32 random bytes.
/// Stored blobs are `AES.GCM.SealedBox.combined` (nonce || ciphertext || tag).
/// This is intentionally fail-closed: a missing or malformed key throws and we
/// never read or write a plaintext secret.
///
/// In the embedded (V3) runtime the key never touches an environment file:
/// the app loads it from the Keychain and injects it through `keyProvider`
/// before the server starts. The CLI keeps the env-var contract.
public enum AccessTokenCipher {
    /// Embedded runtime seam: non-nil return values replace the env lookup.
    public static var keyProvider: (() throws -> SymmetricKey)?

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

    /// Validate the configured key without touching any data. Called at startup.
    public static func validateKey() throws {
        _ = try loadKey()
    }

    private static func loadKey() throws -> SymmetricKey {
        if let keyProvider {
            return try keyProvider()
        }
        guard let raw = ProcessInfo.processInfo.environment["LAGOON_TOKEN_KEY"], !raw.isEmpty else {
            throw TokenCipherError.missingKey
        }
        guard let data = Data(base64Encoded: raw), data.count == 32 else {
            throw TokenCipherError.badKey
        }
        return SymmetricKey(data: data)
    }
}
