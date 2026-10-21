import Foundation
import GRDB

/// Repairs an `accounts.id` (and the `account_id` of its children) whose
/// *encoding* does not match the encoding the application actually queries
/// with.
///
/// ## The defect
///
/// `accounts.id` is declared `BLOB PRIMARY KEY`, and GRDB stores a `UUID` as
/// its 16 raw bytes. Every child table (`message_headers`, `advice`,
/// `ai_actions`, `draft_replies`, …) therefore holds a 16-byte BLOB in
/// `account_id`.
///
/// One install had the **same UUID in two encodings**: the parent row stored
/// the 36-character UTF-8 text (`f5661697-…`) while every child row stored
/// the 16-byte binary form. The values are the same UUID; only the *encoding*
/// differs — and SQLite compares BLOB and TEXT as different values, so the
/// parent row was unreachable by every `WHERE id = ?` the app issues.
///
/// The consequences reached all the way to the screen:
///
/// - `AccountStore.find(byId:)` never matched, so the account could not be
///   found, so the sync failed, so the row's `sync_status` became
///   `needsReconnect` — and the user was told their **authorization code had
///   expired**, which was a lie. The code was fine; the row was unfindable.
/// - `ON DELETE CASCADE` never matched either, so deleting the account left
///   356 message headers, 246 `ai_actions` and 124 `advice` rows behind as
///   orphans.
/// - `PRAGMA foreign_key_check` reported 727 violations, so the store was not
///   in the state its own schema claims.
///
/// ## Why the binary form is the target
///
/// The tempting alternative — "rewrite the parent to match whatever the
/// children hold" — is wrong, and wrong in a way that leaves the store just
/// as broken.
///
/// **Every SQL query in the server binds a `UUID`**, and GRDB encodes a
/// `UUID` as 16 bytes. `AccountStore.find(byId:)`,
/// `CredentialVault.read(accountId:)`, `MessageStore`'s account filters and
/// the foreign key constraints themselves all bind the binary form. A row
/// whose id is the *text* form is therefore unreachable **no matter what the
/// other rows do** — including a child row that also holds the text form.
///
/// So the binary form is not "the form the children happen to use"; it is the
/// form the *application* uses, and it is the only form under which the
/// account is findable and the cascade fires. The repair therefore
/// normalises **both sides** onto the binary form:
///
/// - the parent row is rewritten from text to binary, and
/// - any child row still holding the text form is rewritten along with it.
///
/// This handles both directions of the mismatch. When the children already
/// hold the binary form (the case that was observed), only the parent moves.
/// When the children hold the text form instead, the children move too —
/// which is what makes the tree consistent rather than merely consistent
/// with a parent that is still unreachable.
///
/// Normalising the children is lossless: a UUID has exactly one value, and
/// the text form is a spelling of that same value. Nothing is invented and
/// nothing is discarded.
///
/// ## Why this is a migration and not a lookup fallback
///
/// A "find the account by trying both encodings" query would make the
/// account findable while leaving the store corrupt: the cascade would still
/// not fire, and `foreign_key_check` would still report 727 violations. The
/// encoding has to be *fixed*, not worked around.
public enum AccountIDRepair {
    /// A child table that carries an `account_id`.
    ///
    /// Each case carries the two SQL statements the repair needs for that
    /// table. The statements are written out one by one rather than built
    /// from a table name, because a table name cannot be a bound parameter
    /// in SQLite and the project's guardrail forbids splicing one into a
    /// SQL literal. The list is a compile-time constant, so the statements
    /// are as safe as a bound value.
    public enum ChildTable: String, CaseIterable, Sendable {
        case messageHeaders = "message_headers"
        case messageBodies = "message_bodies"
        case advice = "advice"
        case aiActions = "ai_actions"
        case draftReplies = "draft_replies"
        case messagePins = "message_pins"
        case stackRules = "stack_rules"
        case aiOverrides = "ai_overrides"
        case reminders = "reminders"

        /// The distinct `account_id` values in this table, with their row
        /// counts. Only the *values* are fetched — never the rows.
        public var distinctAccountIDsSQL: String {
            switch self {
            case .messageHeaders:
                return "SELECT account_id, COUNT(*) FROM message_headers GROUP BY account_id"
            case .messageBodies:
                return "SELECT account_id, COUNT(*) FROM message_bodies GROUP BY account_id"
            case .advice:
                return "SELECT account_id, COUNT(*) FROM advice GROUP BY account_id"
            case .aiActions:
                return "SELECT account_id, COUNT(*) FROM ai_actions GROUP BY account_id"
            case .draftReplies:
                return "SELECT account_id, COUNT(*) FROM draft_replies GROUP BY account_id"
            case .messagePins:
                return "SELECT account_id, COUNT(*) FROM message_pins GROUP BY account_id"
            case .stackRules:
                return "SELECT account_id, COUNT(*) FROM stack_rules GROUP BY account_id"
            case .aiOverrides:
                return "SELECT account_id, COUNT(*) FROM ai_overrides GROUP BY account_id"
            case .reminders:
                return "SELECT account_id, COUNT(*) FROM reminders GROUP BY account_id"
            }
        }

        /// Rewrites this table's rows from the text form to the binary form.
        public var rewriteTextToBinarySQL: String {
            switch self {
            case .messageHeaders:
                return "UPDATE message_headers SET account_id = ? WHERE account_id = ?"
            case .messageBodies:
                return "UPDATE message_bodies SET account_id = ? WHERE account_id = ?"
            case .advice:
                return "UPDATE advice SET account_id = ? WHERE account_id = ?"
            case .aiActions:
                return "UPDATE ai_actions SET account_id = ? WHERE account_id = ?"
            case .draftReplies:
                return "UPDATE draft_replies SET account_id = ? WHERE account_id = ?"
            case .messagePins:
                return "UPDATE message_pins SET account_id = ? WHERE account_id = ?"
            case .stackRules:
                return "UPDATE stack_rules SET account_id = ? WHERE account_id = ?"
            case .aiOverrides:
                return "UPDATE ai_overrides SET account_id = ? WHERE account_id = ?"
            case .reminders:
                return "UPDATE reminders SET account_id = ? WHERE account_id = ?"
            }
        }

        /// How many rows in this table hold a given `account_id`.
        public var countSQL: String {
            switch self {
            case .messageHeaders:
                return "SELECT COUNT(*) FROM message_headers WHERE account_id = ?"
            case .messageBodies:
                return "SELECT COUNT(*) FROM message_bodies WHERE account_id = ?"
            case .advice:
                return "SELECT COUNT(*) FROM advice WHERE account_id = ?"
            case .aiActions:
                return "SELECT COUNT(*) FROM ai_actions WHERE account_id = ?"
            case .draftReplies:
                return "SELECT COUNT(*) FROM draft_replies WHERE account_id = ?"
            case .messagePins:
                return "SELECT COUNT(*) FROM message_pins WHERE account_id = ?"
            case .stackRules:
                return "SELECT COUNT(*) FROM stack_rules WHERE account_id = ?"
            case .aiOverrides:
                return "SELECT COUNT(*) FROM ai_overrides WHERE account_id = ?"
            case .reminders:
                return "SELECT COUNT(*) FROM reminders WHERE account_id = ?"
            }
        }

        /// Whether this table's `(account_id, remote_id)` pair must be unique
        /// — the constraint a text→binary rewrite could collide with.
        public var hasUniqueRemoteID: Bool {
            switch self {
            case .messageHeaders, .advice, .reminders:
                return true
            case .messageBodies, .aiActions, .draftReplies, .messagePins,
                 .stackRules, .aiOverrides:
                return false
            }
        }

        /// Whether rewriting the text form to the binary form would create a
        /// duplicate `(account_id, remote_id)` in this table.
        public var collisionSQL: String? {
            switch self {
            case .messageHeaders:
                return """
                    SELECT COUNT(*) FROM message_headers
                    WHERE remote_id IN (SELECT remote_id FROM message_headers WHERE account_id = ?)
                      AND account_id = ?
                    """
            case .advice:
                return """
                    SELECT COUNT(*) FROM advice
                    WHERE remote_id IN (SELECT remote_id FROM advice WHERE account_id = ?)
                      AND account_id = ?
                    """
            case .reminders:
                return """
                    SELECT COUNT(*) FROM reminders
                    WHERE remote_id IN (SELECT remote_id FROM reminders WHERE account_id = ?)
                      AND account_id = ?
                    """
            case .messageBodies, .aiActions, .draftReplies, .messagePins,
                 .stackRules, .aiOverrides:
                return nil
            }
        }
    }

    /// The 16-byte form of a UUID — the form GRDB writes and the form every
    /// query in the server binds.
    public static func binaryBytes(for uuid: UUID) -> Data {
        withUnsafeBytes(of: uuid.uuid) { buffer in
            Data(buffer)
        }
    }

    /// A UUID read out of a database value, together with the encoding it was
    /// stored in.
    public enum StoredForm: Equatable, Sendable {
        case binary(Data)
        case text(String)

        /// The UUID this value denotes, or nil when it is not a UUID in
        /// either form.
        public var uuid: UUID? {
            switch self {
            case .binary(let data):
                guard data.count == 16 else { return nil }
                return data.withUnsafeBytes { buffer in
                    UUID(uuid: buffer.load(as: uuid_t.self))
                }
            case .text(let text):
                return UUID(uuidString: text)
            }
        }

        /// The same UUID spelled in the *other* encoding, or nil when this
        /// value is not a UUID at all.
        public func counterpart() -> StoredForm? {
            guard let uuid else { return nil }
            return .binary(AccountIDRepair.binaryBytes(for: uuid))
        }
    }

    /// Reads a database value as a UUID in whichever form it is stored.
    public static func storedForm(of value: DatabaseValue) -> StoredForm? {
        switch value.storage {
        case .blob(let data) where data.count == 16:
            return .binary(data)
        case .blob(let data) where data.count == 36:
            // The text form stored as a blob — the same defect in a
            // different wrapper. SQLite compares a BLOB and a TEXT as
            // different values, so this row is just as unreachable.
            guard let text = String(data: data, encoding: .utf8),
                  UUID(uuidString: text) != nil else { return nil }
            return .text(text)
        case .string(let text):
            guard UUID(uuidString: text) != nil else { return nil }
            return .text(text)
        default:
            return nil
        }
    }

    /// What the repair did, for logging and for the tests.
    public struct Outcome: Equatable, Sendable {
        /// The account id that was repaired.
        public let uuid: UUID
        /// The encoding the account row had before the repair.
        public let from: StoredForm
        /// The encoding the account row has after the repair.
        public let to: StoredForm
        /// How many child rows were rewritten.
        public let childRowsRewritten: Int
        /// How many child rows could not be rewritten because the rewrite
        /// would have collided with a `UNIQUE (account_id, remote_id)`.
        public let childRowsSkipped: Int

        public var didChangeAnything: Bool { from != to || childRowsRewritten > 0 }
    }

    /// Normalises every account id and every child `account_id` that is
    /// stored in the text form of a UUID onto the binary form.
    ///
    /// Runs inside the caller's transaction. Foreign key checks are
    /// **deferred** for the duration, which is what makes the convergence
    /// possible: SQLite enforces a foreign key *immediately* by default, and
    /// an immediate check on a parent key that is mid-move rejects the very
    /// update that would fix the tree.
    ///
    /// Deferred checks are not a blanket "ignore the constraints" switch: the
    /// constraint is still checked at COMMIT, so a repair that failed to
    /// converge aborts the transaction rather than committing a broken tree.
    ///
    /// The order of the rewrites matters and is not interchangeable. The
    /// children move **first**, the parent **last**:
    ///
    /// - Moving a child row from the text form to the binary form leaves it
    ///   briefly orphaned (its parent still holds the text form). An orphan
    ///   is exactly the state deferred checks exist to survive.
    /// - Moving the parent first would leave every child row pointing at a
    ///   value the parent no longer has — which an *immediate* check rejects
    ///   outright.
    ///
    /// - Parameterised SQL throughout: every value is a bound parameter.
    public static func repairAccountIDs(in db: Database) throws -> [Outcome] {
        let parents = try accountRowsWhoseIDIsAUUID(in: db)
        guard !parents.isEmpty else { return [] }

        var outcomes: [Outcome] = []
        for (uuid, form) in parents {
            let (rewritten, skipped) = try normalizeChildren(for: uuid, in: db)
            let parentChanged = try normalizeParent(for: uuid, form: form, in: db)
            guard parentChanged || rewritten > 0 else { continue }
            outcomes.append(Outcome(
                uuid: uuid,
                from: form,
                to: .binary(binaryBytes(for: uuid)),
                childRowsRewritten: rewritten,
                childRowsSkipped: skipped
            ))
        }
        return outcomes
    }

    /// Every account whose id is a UUID, in whichever encoding it was stored.
    ///
    /// The *parent* is not the only place the mismatch can live. A store
    /// whose parent holds the binary form while its children hold the text
    /// form is just as broken — the children are orphans, the cascade does
    /// not reach them, and `foreign_key_check` reports them — and a candidate
    /// set built from "parent rows that need rewriting" would never visit it.
    /// That is why the candidates are *all* accounts and the yes/no decision
    /// is made per account, after looking at the children too.
    ///
    /// A row whose id is not a UUID in either form is not a candidate: the
    /// repair is not allowed to guess at a value it does not understand.
    private static func accountRowsWhoseIDIsAUUID(
        in db: Database
    ) throws -> [(UUID, StoredForm)] {
        guard try db.tableExists("accounts") else { return [] }
        let rows = try Row.fetchAll(db, sql: "SELECT id FROM accounts")
        var result: [(UUID, StoredForm)] = []
        for row in rows {
            let value: DatabaseValue = row["id"]
            guard let form = storedForm(of: value) else { continue }
            guard let uuid = form.uuid else { continue }
            result.append((uuid, form))
        }
        return result
    }

    /// Rewrites the child rows that hold the text form of `uuid`.
    private static func normalizeChildren(
        for uuid: UUID,
        in db: Database
    ) throws -> (rewritten: Int, skipped: Int) {
        let binary = binaryBytes(for: uuid)
        var rewritten = 0
        var skipped = 0
        for table in ChildTable.allCases {
            guard try db.tableExists(table.rawValue) else { continue }
            // Which spellings of the text form does this table hold? A row
            // can hold any of them, and every one of them has to move.
            let spellings = try textSpellings(in: table, for: uuid, in: db)
            guard !spellings.isEmpty else { continue }
            for spelling in spellings {
                if let collisionSQL = table.collisionSQL,
                   try Int.fetchOne(
                       db, sql: collisionSQL, arguments: [spelling, binary]
                   ) ?? 0 > 0 {
                    // Rewriting would produce a duplicate
                    // `(account_id, remote_id)`. The rows are left as they
                    // are and the collision is reported — silently deleting
                    // one of them would lose mail, and silently keeping the
                    // violation would hide a real problem.
                    skipped += try Int.fetchOne(
                        db, sql: table.countSQL, arguments: [spelling]
                    ) ?? 0
                    continue
                }
                try db.execute(
                    sql: table.rewriteTextToBinarySQL,
                    arguments: [binary, spelling]
                )
                rewritten += db.changesCount
            }
        }
        return (rewritten, skipped)
    }

    /// Rewrites the parent row to the binary form.
    private static func normalizeParent(
        for uuid: UUID,
        form: StoredForm,
        in db: Database
    ) throws -> Bool {
        switch form {
        case .text(let spelling):
            try db.execute(
                sql: "UPDATE accounts SET id = ? WHERE id = ?",
                arguments: [binaryBytes(for: uuid), spelling]
            )
            return db.changesCount > 0
        case .binary:
            return false
        }
    }

    /// The distinct spellings of the text form of `uuid` held by a table.
    private static func textSpellings(
        in table: ChildTable,
        for uuid: UUID,
        in db: Database
    ) throws -> [String] {
        let rows = try Row.fetchAll(db, sql: table.distinctAccountIDsSQL)
        var spellings: [String] = []
        for row in rows {
            let value: DatabaseValue = row["account_id"]
            guard let form = storedForm(of: value) else { continue }
            guard case .text(let spelling) = form else { continue }
            guard form.uuid == uuid else { continue }
            if !spellings.contains(spelling) { spellings.append(spelling) }
        }
        return spellings
    }
}
