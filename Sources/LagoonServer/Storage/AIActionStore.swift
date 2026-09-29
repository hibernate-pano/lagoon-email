import Foundation
import GRDB
import LagoonKit

/// SQLite-backed audit log for `ai_actions`. Append-only.
public enum AIActionStore {
    public static func record(
        accountId: UUID,
        kind: AIActionKind,
        payload: [String: String],
        db: LagoonDB
    ) async throws -> AIAction {
        try db.write { db in
            try recordSync(accountId: accountId, kind: kind, payload: payload, db: db)
        }
    }

    /// Sync core for callers inside a transaction: action routes compose
    /// "flip the local flag + record the action" atomically in one
    /// `pool.write` closure and hand the raw `Database` handle here.
    public static func recordSync(
        accountId: UUID,
        kind: AIActionKind,
        payload: [String: String],
        db: Database
    ) throws -> AIAction {
        let payloadJSON = try Self.encode(payload)
        // INSERT ... RETURNING (SQLite 3.35+): the row comes back with its
        // server-generated id, created_at and expires_at defaults applied.
        guard let row = try Row.fetchOne(
            db,
            sql: """
                INSERT INTO ai_actions (account_id, kind, payload)
                VALUES (?, ?, ?)
                RETURNING id, account_id, kind, payload, created_at, expires_at
                """,
            arguments: [accountId, kind.rawValue, payloadJSON]
        ) else {
            throw StoreError.insertFailed
        }
        return try Self.decode(row)
    }

    /// Undo is single-use: the undo route answers 409 `already-undone` for a
    /// second attempt. Both client entry points pick from this list — ⌘Z takes
    /// the newest `isUndoable` row, the action-history sheet shows a button
    /// per row — so an already-undone action must not appear here at all.
    /// Leaving it in made both entry points dead ends: ⌘Z kept re-picking the
    /// same undone archive and never reached an older one.
    public static func recent(
        accountId: UUID,
        since: Date? = nil,
        limit: Int = 50,
        db: LagoonDB
    ) async throws -> [AIAction] {
        // `ai_actions_undo_of_idx` covers this subquery's predicate. Written
        // out per branch rather than interpolated: the SQL guardrail rejects
        // interpolation outside SQLBuilder.
        let sql: String
        let args: [DatabaseValueConvertible?]
        if let since {
            sql = """
                SELECT id, account_id, kind, payload, created_at, expires_at FROM ai_actions
                WHERE account_id = ? AND created_at >= ?
                  AND NOT EXISTS (
                      SELECT 1 FROM ai_actions u
                      WHERE u.account_id = ai_actions.account_id
                        AND u.kind = 'undo'
                        AND json_extract(u.payload, '$.undoOf') = ai_actions.id
                  )
                ORDER BY created_at DESC LIMIT ?
                """
            args = [accountId, since, limit]
        } else {
            sql = """
                SELECT id, account_id, kind, payload, created_at, expires_at FROM ai_actions
                WHERE account_id = ?
                  AND NOT EXISTS (
                      SELECT 1 FROM ai_actions u
                      WHERE u.account_id = ai_actions.account_id
                        AND u.kind = 'undo'
                        AND json_extract(u.payload, '$.undoOf') = ai_actions.id
                  )
                ORDER BY created_at DESC LIMIT ?
                """
            args = [accountId, limit]
        }
        return try db.read { db in
            try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
                .map { try Self.decode($0) }
        }
    }

    /// Looked up inside the undo route's claim transaction: "found / expired /
    /// already undone" and the insert of the undo row must be one unit, so
    /// none of those reads may escape to their own transaction.
    public static func findSync(id: Int64, db: Database) throws -> AIAction? {
        try Row.fetchOne(
            db,
            sql: "SELECT id, account_id, kind, payload, created_at, expires_at FROM ai_actions WHERE id = ?",
            arguments: [id]
        ).map { try Self.decode($0) }
    }

    /// Whether an action has already been reversed.
    ///
    /// Undo is not idempotent: replaying an archive-undo moves a message out
    /// of a folder it is no longer in, and replaying a mark-read-undo clears
    /// a `\Seen` flag the user has since set again. The client shows an Undo
    /// button for six seconds and ⌘Z re-fetches recent history, so a
    /// double-fire is reachable without any malice — and ⌘Z has no in-flight
    /// guard at all, so two of them can be in flight together. Read inside
    /// the undo route's claim transaction, so the answer and the undo row
    /// cannot disagree.
    public static func isUndoneSync(id: Int64, accountId: UUID, db: Database) throws -> Bool {
        let undone = try Row.fetchOne(
            db,
            sql: """
                SELECT 1 FROM ai_actions
                WHERE account_id = ? AND kind = 'undo'
                  AND json_extract(payload, '$.undoOf') = ?
                LIMIT 1
                """,
            arguments: [accountId, "\(id)"]
        )
        return undone != nil
    }

    /// Retracts the undo row the undo route claims *before* it runs the
    /// inverse. That row is a claim, not a record: when the inverse throws,
    /// nothing was reversed, and keeping the row would mark the action undone
    /// for good — the one outcome single-use undo must never produce.
    /// Scoped to `kind = 'undo'` so no ordinary audit row can be removed by it.
    public static func deleteUndo(id: Int64, db: LagoonDB) async throws {
        try db.write {
            try $0.execute(
                sql: "DELETE FROM ai_actions WHERE id = ? AND kind = 'undo'",
                arguments: [id]
            )
        }
    }


    /// Looks up a previously completed send by the client's idempotency key.
    public static func findSend(
        accountId: UUID,
        requestId: String,
        db: LagoonDB
    ) async throws -> AIAction? {
        return try db.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT id, account_id, kind, payload, created_at, expires_at
                    FROM ai_actions
                    WHERE account_id = ? AND kind = 'send' AND json_extract(payload, '$.requestId') = ?
                    LIMIT 1
                    """,
                arguments: [accountId, requestId]
            ).map { try Self.decode($0) }
        }
    }

    /// remoteIds Lagoon actually sent a reply to, plus Message-IDs harvested
    /// from Sent-folder mail (cross-client replies, V2 A2 — recorded as
    /// `send` actions with a `sentFolder` marker). The reply route records the
    /// *original* message's remoteId in the send action's payload, so this is
    /// the authoritative "already replied" signal for the briefing classifier.
    /// The classifier matches rows on both `remoteId` and the stored
    /// Message-ID header: rows are keyed by IMAP UID while Sent harvesting
    /// yields Message-IDs, so one key alone cannot decide.
    public static func repliedRemoteIds(
        accountId: UUID,
        db: LagoonDB
    ) async throws -> Set<String> {
        let sql = """
            SELECT DISTINCT json_extract(payload, '$.remoteId') AS rid
            FROM ai_actions
            WHERE account_id = ? AND kind = 'send' AND json_extract(payload, '$.remoteId') IS NOT NULL
        """
        return try db.read { db in
            let rows = try Row.fetchAll(db, sql: sql, arguments: [accountId])
            return Set(rows.compactMap { $0.optionalText("rid") })
        }
    }

    /// Audited (kind, createdAt) events for the time-saved report, with
    /// actions that were later undone excluded — an undone archive is not a
    /// handled message. Cross-client reply signals (`send` with a `sentFolder`
    /// marker, V2 A2) are excluded too: no Lagoon work happened. `since`
    /// bounds the query; the caller aggregates.
    public static func timeSavedEvents(
        accountId: UUID,
        since: Date,
        db: LagoonDB
    ) async throws -> [(kind: AIActionKind, createdAt: Date)] {
        let sql = """
            SELECT a.kind, a.created_at
            FROM ai_actions a
            WHERE a.account_id = ? AND a.created_at >= ?
              AND NOT (a.kind = 'send' AND json_extract(a.payload, '$.sentFolder') IS NOT NULL)
              AND NOT EXISTS (
                  SELECT 1 FROM ai_actions u
                  WHERE u.account_id = a.account_id AND u.kind = 'undo'
                    AND json_extract(u.payload, '$.undoOf') = CAST(a.id AS TEXT)
              )
        """
        return try db.read { db in
            let rows = try Row.fetchAll(db, sql: sql, arguments: [accountId, since])
            return rows.map { row in
                let kindStr: String = row["kind"]
                let createdAt: Date = row["created_at"]
                return (kind: AIActionKind(rawValue: kindStr) ?? .archive, createdAt: createdAt)
            }
        }
    }

    /// Per-(account, sender) override lookup used by the heuristic classifier.
    public static func overridesBySender(
        accountId: UUID,
        db: LagoonDB
    ) async throws -> [String: BriefingGroup] {
        let sql = """
            WITH ranked AS (
                SELECT o.to_group, m.from_address, o.created_at,
                    row_number() OVER (PARTITION BY m.from_address ORDER BY o.created_at DESC, o.rowid DESC) AS rn
                FROM ai_overrides o
                JOIN message_headers m ON m.remote_id = o.remote_id AND m.account_id = o.account_id
                WHERE o.account_id = ?
            )
            SELECT from_address, to_group FROM ranked WHERE rn = 1
        """
        // The rowid tie-break matters: created_at is millisecond TEXT, and an
        // override + its undo-counter can land in the same millisecond on a
        // fast machine. Without it the tie resolves in scan order (oldest
        // first) and the undo silently appears to not flip the sender back.
        return try db.read { db in
            var result: [String: BriefingGroup] = [:]
            for row in try Row.fetchAll(db, sql: sql, arguments: [accountId]) {
                let addr: String = row["from_address"]
                let groupStr: String = row["to_group"]
                if let group = BriefingGroup(rawValue: groupStr) {
                    result[addr] = group
                }
            }
            return result
        }
    }

    public static func insertOverride(
        accountId: UUID,
        remoteId: String,
        fromGroup: BriefingGroup,
        toGroup: BriefingGroup,
        db: LagoonDB
    ) async throws {
        try db.write {
            try insertOverrideSync(
                accountId: accountId, remoteId: remoteId,
                fromGroup: fromGroup, toGroup: toGroup, db: $0
            )
        }
    }

    /// Sync core for callers inside a transaction.
    public static func insertOverrideSync(
        accountId: UUID,
        remoteId: String,
        fromGroup: BriefingGroup,
        toGroup: BriefingGroup,
        db: Database
    ) throws {
        try db.execute(
            sql: "INSERT INTO ai_overrides (account_id, remote_id, from_group, to_group) VALUES (?, ?, ?, ?)",
            arguments: [accountId, remoteId, fromGroup.rawValue, toGroup.rawValue]
        )
    }

    public static func decode(_ row: Row) throws -> AIAction {
        let payloadText: String = row["payload"]
        return AIAction(
            id: row["id"],
            accountId: row["account_id"],
            kind: AIActionKind(rawValue: row["kind"]) ?? .archive,
            payload: Self.decodePayload(payloadText),
            createdAt: row["created_at"],
            expiresAt: row["expires_at"]
        )
    }

    /// JSON text for the `payload` column. Encoded with JSONSerialization so a
    /// String value stays a JSON string, never double-encoded.
    private static func encode(_ payload: [String: String]) throws -> String {
        String(
            decoding: try JSONSerialization.data(withJSONObject: payload),
            as: UTF8.self
        )
    }

    private static func decodePayload(_ json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any]
        else { return [:] }
        return dict.compactMapValues { ($0 as? String) ?? ($0 as? NSNumber).map { "\($0)" } }
    }
}

/// SQLite-backed draft replies.
public enum DraftReplyStore {
    public static func create(
        accountId: UUID,
        remoteId: String,
        variants: [String],
        db: LagoonDB
    ) async throws -> DraftReply {
        let json = String(
            decoding: try JSONSerialization.data(withJSONObject: variants),
            as: UTF8.self
        )
        return try db.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    INSERT INTO draft_replies (account_id, remote_id, variants)
                    VALUES (?, ?, ?)
                    RETURNING id, account_id, remote_id, variants, chosen_variant, created_at
                    """,
                arguments: [accountId, remoteId, json]
            ) else {
                throw StoreError.insertFailed
            }
            return try Self.decode(row)
        }
    }

    public static func list(
        accountId: UUID,
        remoteId: String? = nil,
        db: LagoonDB
    ) async throws -> [DraftReply] {
        let sql: String
        let args: [DatabaseValueConvertible?]
        if let remoteId {
            sql = "SELECT id, account_id, remote_id, variants, chosen_variant, created_at FROM draft_replies WHERE account_id = ? AND remote_id = ? ORDER BY created_at DESC"
            args = [accountId, remoteId]
        } else {
            sql = "SELECT id, account_id, remote_id, variants, chosen_variant, created_at FROM draft_replies WHERE account_id = ? ORDER BY created_at DESC LIMIT 50"
            args = [accountId]
        }
        return try db.read { db in
            try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
                .map { try Self.decode($0) }
        }
    }

    public static func decode(_ row: Row) throws -> DraftReply {
        let variantsJSON: String = row["variants"]
        let chosen: Int? = row["chosen_variant"]
        return DraftReply(
            id: row["id"],
            accountId: row["account_id"],
            remoteId: row["remote_id"],
            variants: Self.parseVariantsJSON(variantsJSON),
            chosenVariant: chosen,
            createdAt: row["created_at"]
        )
    }

    private static func parseVariantsJSON(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8) else { return [] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String]) ?? []
    }
}
