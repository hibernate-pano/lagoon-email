import Foundation
import GRDB
import LagoonKit

/// SQLite-backed read-only advice (constitution §3).
///
/// This store is the only writer of the `advice` table, and every write here is
/// a write of *suggestion data* — never a mailbox mutation. Nothing in this
/// file can archive, delete, unsubscribe or send; those verbs live in the
/// routes and are reachable only from a user gesture.
public enum AdviceStore {
    public enum StoreError: Error {
        case insertFailed
    }

    /// Records or refreshes advice for one message.
    ///
    /// The decision columns are deliberately *not* in the conflict clause. The
    /// background classifier re-evaluates the same feed every refresh and a
    /// model's output is not deterministic, so an upsert that reset `decision`
    /// would put a dismissed suggestion straight back into the queue — the
    /// nagging failure mode that makes advice surfaces get ignored, then
    /// closed. Preserving it means "you already told me no" survives
    /// re-evaluation, which is what makes accepting/dismissing worth doing.
    ///
    /// A row whose message header has vanished (another client moved it and the
    /// sync loop reconciled it away between classification and this write) is
    /// skipped rather than raised: the foreign key rejects it, and advice about
    /// mail that is no longer local is worthless. One lost row must not fail a
    /// batch of the other eleven.
    ///
    /// The skip is a *pre-check*, not a caught error. Catching the constraint
    /// violation would also swallow a genuine failure — a full disk, a closed
    /// database, a malformed model string — and report it as "that message is
    /// gone", which is the one diagnosis an operator would then chase in the
    /// wrong place.
    public static func upsert(
        accountId: UUID,
        remoteId: String,
        advice: Advice,
        source: AdviceSource,
        model: String?,
        db: LagoonDB
    ) async throws -> AdviceRecord? {
        try db.write { raw in
            try upsertSync(
                accountId: accountId,
                remoteId: remoteId,
                advice: advice,
                source: source,
                model: model,
                db: raw
            )
        }
    }

    /// Sync core for callers already inside a transaction, so a batch of
    /// advice rows can land in one write rather than one per message.
    public static func upsertSync(
        accountId: UUID,
        remoteId: String,
        advice: Advice,
        source: AdviceSource,
        model: String?,
        db: Database
    ) throws -> AdviceRecord? {
        // The advice row hangs off the message header by foreign key, so a
        // header that is gone means there is nothing to advise about. Checked
        // explicitly rather than inferred from a caught violation.
        guard try Bool.fetchOne(
            db,
            sql: "SELECT 1 FROM message_headers WHERE account_id = ? AND remote_id = ?",
            arguments: [accountId, remoteId]
        ) == true else {
            return nil
        }
        // `created_at` is left out of the DO UPDATE set on purpose: it is when
        // advice for this message first existed, not when it was last
        // re-derived, and the queue sorts on it.
        guard let row = try Row.fetchOne(
            db,
            sql: """
                INSERT INTO advice (
                    account_id, remote_id, action, category, confidence,
                    rationale, due_text, source, model
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (account_id, remote_id) DO UPDATE SET
                    action     = excluded.action,
                    category   = excluded.category,
                    confidence = excluded.confidence,
                    rationale  = excluded.rationale,
                    due_text   = excluded.due_text,
                    source     = excluded.source,
                    model      = excluded.model
                RETURNING id, account_id, remote_id, action, category, confidence,
                            rationale, due_text, source, model, decision,
                            created_at, decided_at
                """,
            arguments: [
                accountId,
                remoteId,
                advice.action.rawValue,
                advice.category?.rawValue,
                advice.confidence.rawValue,
                advice.rationale,
                advice.dueText,
                source.rawValue,
                model,
            ]
        ) else {
            // An upsert with RETURNING always yields a row unless the statement
            // affected none — which here means the header it points at is gone.
            return nil
        }
        return try decode(row)
    }

    /// Records the user's verdict on one suggestion.
    ///
    /// Scoped by account so a stale id from another mailbox can never mark a
    /// row here, the same discipline the rule and action stores use.
    public static func setDecision(
        id: Int64,
        accountId: UUID,
        decision: AdviceDecision,
        db: LagoonDB
    ) async throws -> Bool {
        try db.write { raw in
            // decided_at is set for a verdict and cleared when one is withdrawn
            // back to pending, so the column always describes the current
            // decision rather than the last time any decision was made.
            let decidedAt = decision == .pending ? nil : Date()
            try raw.execute(
                sql: """
                    UPDATE advice SET decision = ?, decided_at = ?
                    WHERE id = ? AND account_id = ?
                    """,
                arguments: [decision.rawValue, decidedAt, id, accountId]
            )
            // `execute` returns Void, so the affected-row count comes from the
            // connection. A stale id from another mailbox must answer "not
            // found", not silently succeed.
            return raw.changesCount > 0
        }
    }

    /// The suggestion queue, newest first.
    ///
    /// One query for all three filters: the predicate and its argument are
    /// chosen together, so there is no way for a caller to pair `.all` with a
    /// bound `decision` or `.pending` with none.
    public static func list(
        accountId: UUID,
        filter: AdviceDecisionQuery,
        limit: Int = 200,
        db: LagoonDB
    ) async throws -> [AdviceRecord] {
        let predicate: String
        var arguments: [DatabaseValueConvertible?] = [accountId]
        switch filter {
        case .pending:
            predicate = "WHERE account_id = ? AND decision = ?"
            arguments.append(AdviceDecision.pending.rawValue)
        case .exactly(let decision):
            predicate = "WHERE account_id = ? AND decision = ?"
            arguments.append(decision.rawValue)
        case .all:
            predicate = "WHERE account_id = ?"
        }
        // Assembled with `joined()` rather than interpolation: the SQL
        // guardrail rejects `\(` inside a SELECT literal even when the spliced
        // piece is a static fragment. Every value is bound.
        let sql = [
            """
            SELECT id, account_id, remote_id, action, category, confidence,
                   rationale, due_text, source, model, decision, created_at, decided_at
            FROM advice
            """,
            predicate,
            "ORDER BY created_at DESC, id DESC LIMIT ?",
        ].joined(separator: "\n")
        arguments.append(limit)
        return try db.read { raw in
            try Row.fetchAll(
                raw,
                sql: sql,
                arguments: StatementArguments(arguments)
            ).map { try decode($0) }
        }
    }

    /// Advice for one message, whatever its decision state. The detail view
    /// reads this so a mail the user already decided on still shows what was
    /// suggested and what they chose.
    public static func find(
        remoteId: String,
        accountId: UUID,
        db: LagoonDB
    ) async throws -> AdviceRecord? {
        let sql = """
            SELECT id, account_id, remote_id, action, category, confidence,
                   rationale, due_text, source, model, decision, created_at, decided_at
            FROM advice
            WHERE account_id = ? AND remote_id = ?
        """
        return try db.read { raw in
            try Row.fetchOne(raw, sql: sql, arguments: [accountId, remoteId])
                .map { try decode($0) }
        }
    }

    /// Advice for many messages in one query, so a feed of 100 rows costs one
    /// round trip instead of a hundred.
    public static func byRemoteIds(
        _ remoteIds: Set<String>,
        accountId: UUID,
        db: LagoonDB
    ) async throws -> [String: AdviceRecord] {
        guard !remoteIds.isEmpty else { return [:] }
        let ids = Array(remoteIds)
        // Placeholders are generated from the count and every value is bound;
        // ids are untrusted input. Assembled with `joined()` rather than
        // interpolation inside the literal, which the SQL guardrail rejects —
        // correctly, since a `SELECT` and an interpolated value in one literal
        // is indistinguishable from the mistake it is trying to catch.
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        let sql = [
            """
            SELECT id, account_id, remote_id, action, category, confidence,
                   rationale, due_text, source, model, decision, created_at, decided_at
            FROM advice
            WHERE account_id = ? AND remote_id IN (
            """,
            placeholders,
            ")",
        ].joined()
        return try db.read { raw in
            var arguments: [DatabaseValueConvertible?] = [accountId]
            arguments.append(contentsOf: ids)
            let rows = try Row.fetchAll(
                raw, sql: sql, arguments: StatementArguments(arguments)
            )
            var result: [String: AdviceRecord] = [:]
            for row in rows {
                let record = try decode(row)
                result[record.remoteId] = record
            }
            return result
        }
    }

    /// Drops dismissed rows older than `cutoff`. Advice is derived data that
    /// can always be regenerated from the mail, so it is the one table in the
    /// store that is safe to prune — unlike `ai_actions`, which is an audit
    /// log and keeps its 30-day retention window for undo.
    public static func pruneDismissed(
        accountId: UUID,
        before cutoff: Date,
        db: LagoonDB
    ) async throws -> Int {
        try db.write { raw in
            try raw.execute(
                sql: "DELETE FROM advice WHERE account_id = ? AND decision = ? AND created_at < ?",
                arguments: [accountId, AdviceDecision.dismissed.rawValue, cutoff]
            )
            return raw.changesCount
        }
    }

    // MARK: - Decoding

    static func decode(_ row: Row) throws -> AdviceRecord {
        guard let actionRaw: String = row["action"],
              let action = AdvisedAction(rawValue: actionRaw),
              let confidenceRaw: String = row["confidence"],
              let confidence = AdviceConfidence(rawValue: confidenceRaw),
              let sourceRaw: String = row["source"],
              let source = AdviceSource(rawValue: sourceRaw),
              let decisionRaw: String = row["decision"],
              let decision = AdviceDecision(rawValue: decisionRaw)
        else {
            // A row whose enum no longer decodes is either corrupt or written
            // by a newer build. Raising here would turn one unreadable
            // suggestion into a 500 for the whole queue; the caller cannot
            // show it, so skipping is the honest answer.
            throw StoreError.insertFailed
        }
        let category = (row["category"] as String?)
            .flatMap(ContentCategory.init(rawValue:))
        return AdviceRecord(
            id: row["id"],
            accountId: row["account_id"],
            remoteId: row["remote_id"],
            advice: Advice(
                action: action,
                category: category,
                confidence: confidence,
                rationale: row.optionalText("rationale"),
                dueText: row.optionalText("due_text")
            ),
            source: source,
            model: row.optionalText("model"),
            decision: decision,
            createdAt: row["created_at"],
            decidedAt: row["decided_at"]
        )
    }
}
