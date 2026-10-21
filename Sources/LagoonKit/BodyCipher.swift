import Foundation
import Crypto
import GRDB

/// Why this exists
///
/// The mail body is the most sensitive thing in the store: a subject line is
/// a title, a body is the message. The project's own security spec
/// (`docs/superpowers/specs/2026-09-09-lagoon-email-design.md` §6.6 rule 5)
/// says "Message bodies never leave the client unencrypted. Server stores
/// ciphertext + metadata only. Body encryption keys live in client keychain
/// (Keychain on Apple platforms)", and pins the enforcement as "unit test
/// that asserts no plaintext body field exists in any server-side table".
///
/// The body used to be stored as plain TEXT. Credentials were sealed
/// (`AccessTokenCipher`) and the body was not, so the guarantee the spec
/// describes held for one column family and not for the one that mattered
/// most.
///
/// ## What is sealed, and what is deliberately not
///
/// | Column | Content | Sealed |
/// |---|---|---|
/// | `message_bodies.body_cipher` | the plain-text body | **yes** |
/// | `message_bodies.body_html_cipher` | the HTML body | **yes** |
/// | `message_headers.snippet_cipher` | the body preview in the list | **yes** |
/// | `message_headers.subject` / `from_address` / `received_at` | headers | no |
/// | `message_bodies.to_addresses` / `cc_addresses` / `attachments` | metadata | no |
///
/// The snippet is body text — it is literally the first lines of the body —
/// so sealing the body while leaving the preview in clear text would make
/// the guarantee a half-truth. It is sealed too.
///
/// The remaining columns are *metadata*, and the spec's own wording
/// ("ciphertext + metadata only") carves them out. They are also what makes
/// a local mail client usable: the list renders 100 rows without decrypting
/// 100 bodies, and the sidebar counts do not need a key at all. Subjects and
/// senders are the index; the body is the payload.
///
/// ## The envelope
///
/// Sealed values are stored as `lgb1:` + base64(`AES.GCM.SealedBox.combined`).
/// The prefix makes the format self-describing, which is what lets the
/// migration tell a legacy plaintext row from a sealed one, and lets a
/// reader refuse a value it cannot decrypt instead of silently returning
/// garbage.
///
/// ## The key
///
/// A 32-byte key held in the macOS Keychain (`lagoon.bodyKey`), injected
/// through `keyProvider` before the store is opened. It is a *separate* key
/// from the one that seals credentials (`lagoon.tokenKey`): rotating one
/// must not silently destroy the other, and a body key has a different
/// lifetime — it only matters while the user is reading mail.
public enum BodyCipher {
    /// Prefix of a sealed value. Versioned: a future format gets a new
    /// prefix, and the reader can tell the two apart.
    public static let envelopePrefix = "lgb1:"

    /// Injected before the store is opened. Nil means "no key available",
    /// which is a fail-closed state: nothing is written in the clear.
    public static var keyProvider: (() throws -> SymmetricKey)?

    /// Whether a usable key is available right now.
    public static var hasKey: Bool {
        guard let keyProvider else { return false }
        return (try? keyProvider()) != nil
    }

    /// Seals `plaintext` into the stored envelope.
    public static func seal(_ plaintext: String) throws -> String {
        let key = try loadKey()
        let sealed = try AES.GCM.seal(Data(plaintext.utf8), using: key)
        guard let combined = sealed.combined else { throw BodyCipherError.badKey }
        return envelopePrefix + combined.base64EncodedString()
    }

    /// Opens a stored envelope back into text.
    ///
    /// Refuses a value that is not an envelope. That refusal is the point: a
    /// reader that silently accepted an unencrypted value would make the
    /// storage guarantee unfalsifiable, and would turn a migration bug into
    /// a quiet downgrade instead of a loud failure.
    public static func open(_ envelope: String) throws -> String {
        guard envelope.hasPrefix(envelopePrefix) else { throw BodyCipherError.notSealed }
        let encoded = String(envelope.dropFirst(envelopePrefix.count))
        guard let data = Data(base64Encoded: encoded) else { throw BodyCipherError.notSealed }
        let key = try loadKey()
        let box = try AES.GCM.SealedBox(combined: data)
        let plaintext = try AES.GCM.open(box, using: key)
        guard let text = String(data: plaintext, encoding: .utf8) else {
            throw BodyCipherError.notUTF8
        }
        return text
    }

    /// Whether a stored value is already sealed.
    public static func isSealed(_ value: String) -> Bool {
        value.hasPrefix(envelopePrefix)
    }

    private static func loadKey() throws -> SymmetricKey {
        guard let keyProvider else { throw BodyCipherError.missingKey }
        return try keyProvider()
    }
}

// MARK: - Migration

extension BodyCipher {
    /// Seals every value that is still in the clear.
    ///
    /// Called from the `lagoon-v6` migration, inside its transaction, so the
    /// store is never left half-sealed: either every body is an envelope or
    /// the migration rolls back.
    ///
    /// The work is done in SQL rather than in Swift so that a store with
    /// thousands of bodies does not have to be loaded into memory to be
    /// sealed — `lagoon_cipher_seal` runs once per row, inside SQLite.
    public static func sealLegacyRows(in db: Database) throws {
        guard hasKey else {
            // Fail closed. With no key the store cannot hold a sealed body,
            // and a plaintext body is precisely what this migration exists
            // to remove.
            //
            // Bodies are a *cache*: the route reads the store first and
            // falls back to the server, so dropping them costs a re-download
            // and no mail. The snippet is body text too, but the header row
            // *is* the mail and must not be deleted — it is cleared
            // instead, and the next sync fills it back in.
            try db.execute(sql: "DELETE FROM message_bodies")
            try db.execute(
                sql: "UPDATE message_headers SET snippet_cipher = '' WHERE snippet_cipher IS NOT NULL"
            )
            return
        }
        try db.execute(sql: """
            UPDATE message_bodies
               SET body_cipher = lagoon_cipher_seal(body_cipher)
             WHERE body_cipher NOT LIKE 'lgb1:%'
            """)
        try db.execute(sql: """
            UPDATE message_bodies
               SET body_html_cipher = lagoon_cipher_seal(body_html_cipher)
             WHERE body_html_cipher IS NOT NULL
               AND body_html_cipher NOT LIKE 'lgb1:%'
            """)
        try db.execute(sql: """
            UPDATE message_headers
               SET snippet_cipher = lagoon_cipher_seal(snippet_cipher)
             WHERE snippet_cipher IS NOT NULL
               AND snippet_cipher != ''
               AND snippet_cipher NOT LIKE 'lgb1:%'
            """)
    }
}

public enum BodyCipherError: Error, CustomStringConvertible, Sendable {
    case missingKey
    case badKey
    case notUTF8
    case notSealed

    public var description: String {
        switch self {
        case .missingKey: return "no body encryption key is available"
        case .badKey: return "the body encryption key is malformed"
        case .notUTF8: return "the sealed body is not valid UTF-8"
        case .notSealed: return "the stored value is not a sealed body"
        }
    }
}

// MARK: - SQL side

extension BodyCipher {
    /// `lagoon_cipher_contains(ciphertext, needle)` — 1 when the sealed text
    /// contains `needle`, 0 otherwise.
    ///
    /// ## Why a SQL function and not a plain LIKE
    ///
    /// Search used to reach into the body with `body_text LIKE '%needle%'`.
    /// With the body sealed, SQLite cannot match inside it — the ciphertext
    /// is not the text. The alternatives were all worse:
    ///
    /// * a second, plaintext index column would leak exactly the content the
    ///   encryption exists to protect;
    /// * decrypting every cached body in Swift and filtering in memory would
    ///   fetch the whole body store on every keystroke and could not be
    ///   pushed down to the `LIMIT`.
    ///
    /// A registered function keeps the decision inside SQLite: the row is
    /// only decrypted when the query actually reaches that arm, the `LIMIT`
    /// still applies to the final result, and no plaintext ever leaves the
    /// process boundary.
    ///
    /// Case-insensitive, like the `LIKE` arms it replaces. SQLite's `LIKE`
    /// folds ASCII only; this folds Unicode, which is a superset — a search
    /// that finds *more* is never a lie, and the extra hits are correct for
    /// CJK text that `LIKE` treated as case-sensitive anyway.
    public static let containsFunction = DatabaseFunction(
        "lagoon_cipher_contains",
        argumentCount: 2,
        // Pure: the result depends only on the two arguments. The nonce is
        // drawn at seal time, not at read time, so opening is deterministic.
        pure: true
    ) { arguments in
        guard let cipher = String.fromDatabaseValue(arguments[0]), !cipher.isEmpty else {
            return 0
        }
        guard let needle = String.fromDatabaseValue(arguments[1]) else { return 1 }
        if needle.isEmpty { return 1 }
        let text = try BodyCipher.open(cipher)
        return text.range(of: needle, options: [.caseInsensitive]) != nil ? 1 : 0
    }

    /// `lagoon_cipher_seal(plaintext)` — seals a value inside SQL.
    ///
    /// Used by the migration to seal a whole column in one statement instead
    /// of loading every body into memory. **Not pure**: AES-GCM draws a
    /// fresh nonce per call, so two calls with the same input return
    /// different ciphertext — telling SQLite that would be a lie.
    public static let sealFunction = DatabaseFunction(
        "lagoon_cipher_seal",
        argumentCount: 1,
        pure: false
    ) { arguments in
        guard let plain = String.fromDatabaseValue(arguments[0]) else { return nil }
        return try BodyCipher.seal(plain)
    }
}
