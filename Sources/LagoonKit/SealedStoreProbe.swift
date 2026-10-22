import Foundation
import GRDB

/// Whether a store on disk still holds sealed values.
///
/// ## Why this exists
///
/// The body key lives in the Keychain; the sealed values live in the store.
/// Neither half can tell the other what it is missing: a `lgb1:` envelope
/// says "sealed with *some* key", and an empty Keychain says "I have no
/// key". So when the Keychain comes back without the key, the only way to
/// know whether writing a new one is safe is to look at the store.
///
/// If the store holds sealed values, they were sealed with a key this
/// process does not have, and a freshly generated key would put them out of
/// reach for good — the user is told nothing, and the rows stay in the
/// database looking like data until someone notices they never open.
///
/// ## Why the three answers are kept apart
///
/// "I read the store and it holds nothing" and "I could not read the store"
/// are not the same answer, and collapsing them is how a fresh install ends
/// up refusing to make a key. So the probe reports three states, and only
/// the two it can prove are allowed to drive a decision.
public enum SealedStoreProbe {
    /// What the probe found.
    public enum State: Sendable, Equatable {
        /// The store was read, and holds no sealed value.
        case empty
        /// The store was read, and holds at least one sealed value.
        case sealed
        /// The store could not be read. Absence is **not** proven.
        case undetermined
    }

    /// Looks for sealed values in the store at `dbPath`.
    ///
    /// Read-only in the sense that matters: it opens the file and runs
    /// `SELECT`s, and it never migrates it. A store that does not exist
    /// yet holds nothing, and says so — that is the answer for a first
    /// launch, where a key has to be made.
    public static func state(dbPath: String) -> State {
        // The file is checked before the connection is opened: opening a
        // missing database would *create* it, and a probe must not leave
        // anything behind.
        guard FileManager.default.fileExists(atPath: dbPath) else { return .empty }
        let queue: DatabaseQueue
        do {
            queue = try DatabaseQueue(path: dbPath)
        } catch {
            return .undetermined
        }
        do {
            return try queue.read { db in
                if try tableExists(db, named: "message_bodies") {
                    if try hasSealedBody(db) { return .sealed }
                }
                if try tableExists(db, named: "message_headers") {
                    if try hasSealedSnippet(db) { return .sealed }
                }
                if try tableExists(db, named: "draft_replies") {
                    if try hasSealedDraft(db) { return .sealed }
                }
                return .empty
            }
        } catch {
            return .undetermined
        }
    }

    /// Whether the table exists in this store.
    ///
    /// The queries below name their table literally — the guardrail forbids
    /// splicing a name into SQL text, and a name that is not a constant has
    /// no business being in a query. A store that predates a table simply
    /// holds nothing in it.
    private static func tableExists(_ db: Database, named name: String) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?)",
            arguments: [name]
        ) ?? false
    }

    private static func hasSealedBody(_ db: Database) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM message_bodies WHERE body_cipher LIKE 'lgb1:%')"
        ) ?? false
    }

    private static func hasSealedSnippet(_ db: Database) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM message_headers WHERE snippet_cipher LIKE 'lgb1:%')"
        ) ?? false
    }

    private static func hasSealedDraft(_ db: Database) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM draft_replies WHERE variants LIKE 'lgb1:%')"
        ) ?? false
    }
}
