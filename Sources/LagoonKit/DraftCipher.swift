import Foundation
import GRDB

/// The AI-generated reply drafts, sealed at rest.
///
/// ## Why this is a separate file and not a method on `BodyCipher`
///
/// `BodyCipher` is a primitive: it seals a string and opens a string, and it
/// says nothing about what the string *is*. The draft store has a shape of
/// its own — a JSON array of reply texts, stored in one column, read back
/// through a `chosen_variant` index — and the rules that come with that
/// shape (one envelope for the whole array, the loud failure when a value
/// cannot be opened, the migration that seals what an older build left in
/// the clear) are the draft store's rules, not the cipher's.
///
/// ## Why one envelope for the whole array
///
/// The alternative is one envelope per variant, with the column holding a
/// JSON array of envelopes. Three reasons this one is better:
///
/// * **The column stays self-describing.** `variants` holds a value that
///   either is an envelope or is not, and `BodyCipher.isSealed` says which.
///   An array-of-envelopes column is JSON at the top level and ciphertext
///   inside it, so "is this sealed?" is a question about every element, and
///   a legacy row (a JSON array of plain strings) is *shapeally
///   indistinguishable* from a new one until every element is inspected.
/// * **The migration is one statement.** Sealing per element means parsing
///   and rewriting JSON inside SQL, which SQLite cannot do without a JSON
///   extension, and which would mean a second, hand-written JSON codec in
///   the migration path. Sealing the array as a whole reuses
///   `lagoon_cipher_seal` exactly as `sealLegacyRows` does for bodies.
/// * **The column's own value is the payload.** Nothing about the array's
///   *length* or the *order* of its elements is readable from the stored
///   bytes. The number of drafts a user generated is itself a small piece of
///   information about their mail, and an array-of-envelopes column would
///   have published it in the clear.
///
/// `chosen_variant` is an **index into the array**, and it keeps working
/// because the array's order survives the round trip untouched: sealing
/// preserves the bytes, and so preserves the positions.
public enum DraftCipher {
    /// The prefix of a sealed variants payload.
    ///
    /// The same envelope `BodyCipher` writes, under the same key. One
    /// prefix for the whole store means a reader — or a person reading the
    /// raw column with `sqlite3` — sees one consistent format.
    public static let envelopePrefix = BodyCipher.envelopePrefix

    /// Seals the reply variants into the stored envelope.
    ///
    /// The whole array becomes one envelope, for the reasons above.
    public static func seal(_ variants: [String]) throws -> String {
        let json = String(
            decoding: try JSONSerialization.data(withJSONObject: variants),
            as: UTF8.self
        )
        return try BodyCipher.seal(json)
    }

    /// Opens a stored envelope back into the reply variants.
    ///
    /// ## Why a failure here is loud
    ///
    /// This refuses a value that is not an envelope, and refuses an envelope
    /// it cannot open. That refusal is the point: a reader that returned an
    /// empty array for a draft it could not read would show the user an
    /// empty draft — indistinguishable from "the AI wrote nothing" — and a
    /// reader that returned the raw `lgb1:…` text would show the user a
    /// line of base64. Both are the silent-downgrade this product refuses:
    /// a draft that cannot be decrypted must say so, not render as nothing.
    public static func open(_ envelope: String) throws -> [String] {
        let json: String
        do {
            json = try BodyCipher.open(envelope)
        } catch let error as BodyCipherError {
            throw DraftCipherError(error)
        } catch {
            // `AES.GCM.open` reports a wrong key or a corrupted ciphertext as
            // an authentication failure of its own type. Letting it escape
            // would make the one case this product must handle — a backup
            // restored under a different keychain — arrive at the routes as
            // an anonymous error they cannot name, and surface as a generic
            // 500 instead of "this draft cannot be read".
            throw DraftCipherError.notAuthentic
        }
        guard let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [String]
        else { throw DraftCipherError.malformedPayload }
        return array
    }

    /// Whether a stored value is already sealed.
    public static func isSealed(_ value: String) -> Bool {
        BodyCipher.isSealed(value)
    }
}

// MARK: - Migration

extension DraftCipher {
    /// Seals every draft that is still in the clear.
    ///
    /// Called from the `lagoon-v9` migration, inside its transaction, so the
    /// store is never left half-sealed: either every draft is an envelope or
    /// the migration rolls back.
    ///
    /// ## The no-key path
    ///
    /// With no key the store cannot hold a sealed draft, and a plaintext
    /// draft is precisely what this migration exists to remove. So the rows
    /// are **deleted** — the same fail-closed answer `BodyCipher.sealLegacyRows`
    /// gives for the body cache, and for the same reason: a draft is
    /// regenerable. The model can write the same three replies again at the
    /// cost of one API call, and the cost of *keeping* them in the clear is
    /// the whole guarantee.
    ///
    /// Deleting is not the same as doing it quietly, though. The deletion is
    /// written to `store_notices`, so the app can tell the user their drafts
    /// are gone instead of leaving them to notice an empty list and wonder
    /// what happened.
    public static func sealLegacyRows(in db: Database) throws {
        guard BodyCipher.hasKey else {
            let count = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM draft_replies"
            ) ?? 0
            try db.execute(sql: "DELETE FROM draft_replies")
            if count > 0 {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO store_notices (id, detail) VALUES (?, ?)",
                    arguments: [StoreNotice.draftsDroppedID, "\(count)"]
                )
            }
            return
        }
        // The `NOT LIKE` predicate is the idempotence: a value that is
        // already an envelope is left byte-for-byte alone, so running the
        // migration twice cannot double-seal a draft (which would make it
        // unopenable — the envelope of an envelope is not the draft).
        try db.execute(sql: """
            UPDATE draft_replies
               SET variants = lagoon_cipher_seal(variants)
             WHERE variants NOT LIKE 'lgb1:%'
            """)
    }
}

/// Why a draft could not be opened.
///
/// The descriptions name the *condition* and never the content: a draft is
/// the user's mail, and an error that carries the draft would put it into
/// a log line.
public enum DraftCipherError: Error, CustomStringConvertible, Sendable, Equatable {
    /// The stored value is not a sealed envelope.
    case notSealed
    /// The envelope opened, but what came out is not a list of strings.
    case malformedPayload
    /// The envelope is well-formed but cannot be opened with the available
    /// key — a restored backup under a different keychain, or a corrupted
    /// ciphertext.
    case notAuthentic
    /// No encryption key is available.
    case missingKey
    /// The key is present but malformed.
    case badKey

    init(_ error: BodyCipherError) {
        switch error {
        case .notSealed: self = .notSealed
        case .notUTF8: self = .malformedPayload
        case .missingKey: self = .missingKey
        case .badKey: self = .badKey
        }
    }

    public var description: String {
        switch self {
        case .notSealed: return "the stored draft is not a sealed envelope"
        case .malformedPayload: return "the sealed draft is not a list of reply variants"
        case .notAuthentic: return "the sealed draft cannot be opened with this key"
        case .missingKey: return "no draft encryption key is available"
        case .badKey: return "the draft encryption key is malformed"
        }
    }
}
