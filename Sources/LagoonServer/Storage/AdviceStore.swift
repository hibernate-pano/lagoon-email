import Foundation
import Logging
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
        guard case .readable(let record) = decode(row) else {
            // The row was written from typed enums a moment ago, so it cannot
            // be unreadable. If it is, the database is not what we think it
            // is, and handing back a half-understood row would hide that.
            throw StoreError.insertFailed
        }
        return record
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
    ///
    /// A row this build cannot read is skipped, not raised: see `decode`.
    public static func list(
        accountId: UUID,
        filter: AdviceDecisionQuery,
        limit: Int = 200,
        db: LagoonDB,
        logger: Logger = Logger(label: "lagoon.advice.store")
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
            let rows = try Row.fetchAll(
                raw,
                sql: sql,
                arguments: StatementArguments(arguments)
            )
            return decodeAll(rows, logger: logger)
        }
    }

    /// Advice for one message, whatever its decision state. The detail view
    /// reads this so a mail the user already decided on still shows what was
    /// suggested and what they chose.
    ///
    /// A row this build cannot read reads as "no advice", the same answer the
    /// caller gets for a message that never had any.
    public static func find(
        remoteId: String,
        accountId: UUID,
        db: LagoonDB,
        logger: Logger = Logger(label: "lagoon.advice.store")
    ) async throws -> AdviceRecord? {
        let sql = """
            SELECT id, account_id, remote_id, action, category, confidence,
                   rationale, due_text, source, model, decision, created_at, decided_at
            FROM advice
            WHERE account_id = ? AND remote_id = ?
        """
        return try db.read { raw in
            guard let row = try Row.fetchOne(
                raw, sql: sql, arguments: [accountId, remoteId]
            ) else { return nil }
            switch decode(row) {
            case .readable(let record):
                return record
            case .unreadable(let reason):
                report(row, reason: reason, logger: logger)
                return nil
            }
        }
    }

    /// Advice for many messages in one query, so a feed of 100 rows costs one
    /// round trip instead of a hundred.
    ///
    /// A row this build cannot read is skipped, not raised: see `decode`.
    public static func byRemoteIds(
        _ remoteIds: Set<String>,
        accountId: UUID,
        db: LagoonDB,
        logger: Logger = Logger(label: "lagoon.advice.store")
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
                switch decode(row) {
                case .readable(let record):
                    result[record.remoteId] = record
                case .unreadable(let reason):
                    report(row, reason: reason, logger: logger)
                }
            }
            return result
        }
    }

    /// The suggestions this account has **acted on**, as a `(category, action)`
    /// distribution.
    ///
    /// This is the learning signal constitution Phase 4 asks for: the accepted
    /// verdicts accumulate into a read-only preference, which the classifier
    /// prompt uses as few-shot context. Without it the `accepted` column is
    /// written and then never read, and the loop is not a loop — it is a log.
    ///
    /// Only `accepted` rows count. `dismissed` is the opposite signal ("do not
    /// suggest this again"), and `pending` is no signal at all; mixing them in
    /// would make the distribution say something the user never said.
    ///
    /// Bounded by `limit` for the same reason the prompt is: the caller feeds
    /// this into a model request, and a list that grows with the user's history
    /// is a cost problem. The rows come back most-frequent first, so the
    /// handful that survive the cut are the ones that actually describe the
    /// user.
    ///
    /// Rows this build cannot read are skipped rather than counted: the
    /// distribution says what the user did, and a row the store cannot even
    /// explain is not a thing the user did. The same goes for a category the
    /// current build does not know — counting it as "other" would teach the
    /// model a preference nobody has.
    public static func acceptedStats(
        accountId: UUID,
        limit: Int = 5,
        db: LagoonDB,
        logger: Logger = Logger(label: "lagoon.advice.store")
    ) async throws -> [AcceptedAdviceStat] {
        // The rows are counted here rather than grouped in SQL, because a
        // group can mix a readable row with an unreadable one: the count
        // would then include a row this build cannot explain, and a group
        // that is entirely unreadable would still take a slot of the limit.
        // The read is bounded by the number of accepted rows, which grows
        // with the actions the user actually took — an acceptance is written
        // by a gesture, not by a classifier run.
        let sql = """
            SELECT id, account_id, remote_id, action, category, confidence,
                   rationale, due_text, source, model, decision, created_at, decided_at
            FROM advice
            WHERE account_id = ? AND decision = ?
            """
        return try db.read { raw in
            let rows = try Row.fetchAll(
                raw,
                sql: sql,
                arguments: [accountId, AdviceDecision.accepted.rawValue]
            )
            var counts: [Shape: Int] = [:]
            for row in rows {
                switch decode(row) {
                case .unreadable(let reason):
                    report(row, reason: reason, logger: logger)
                case .readable(let record):
                    // A category this build does not know is not "no
                    // category": the row is about a category that no longer
                    // exists here, and counting it as uncategorised would
                    // invent a shape the user never expressed.
                    let rawCategory: String? = row["category"]
                    if let rawCategory, ContentCategory(rawValue: rawCategory) == nil {
                        report(
                            row,
                            reason: "category '\(rawCategory)' is not a category this build knows",
                            logger: logger
                        )
                        continue
                    }
                    let shape = Shape(
                        category: record.advice.category,
                        action: record.advice.action
                    )
                    counts[shape, default: 0] += 1
                }
            }
            let stats = counts
                .map {
                    AcceptedAdviceStat(
                        category: $0.key.category,
                        action: $0.key.action,
                        count: $0.value
                    )
                }
                .sorted(by: orderedByFrequency)
            return Array(stats.prefix(max(1, limit)))
        }
    }

    /// One `(category, action)` shape — the unit the distribution counts.
    private struct Shape: Hashable {
        let category: ContentCategory?
        let action: AdvisedAction
    }

    /// Most frequent first, then the tie-break the SQL used to apply: category
    /// and action ascending, with a suggestion that has no category before one
    /// that has.
    private static func orderedByFrequency(
        _ lhs: AcceptedAdviceStat,
        _ rhs: AcceptedAdviceStat
    ) -> Bool {
        if lhs.count != rhs.count { return lhs.count > rhs.count }
        switch (lhs.category, rhs.category) {
        case (nil, nil): break
        case (nil, _): return true
        case (_, nil): return false
        case let (left?, right?):
            if left.rawValue != right.rawValue { return left.rawValue < right.rawValue }
        }
        return lhs.action.rawValue < rhs.action.rawValue
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

    /// One `advice` row, decoded — or the reason it could not be.
    ///
    /// A row whose enum columns hold a value this build does not know — an
    /// action a later build added, a renamed case, a value mangled on disk —
    /// is not a failure of the query. It is a row this build cannot show:
    /// `AdviceRecord` has no way to carry an unknown action, so the client
    /// could not display it either. Raising here would turn one unreadable
    /// suggestion into a 500 for the whole queue, which is the opposite of
    /// what the row deserves.
    ///
    /// The reason travels with the row so that a skip can be reported
    /// instead of swallowed — see `report`.
    enum Decoded {
        case readable(AdviceRecord)
        case unreadable(reason: String)
    }

    /// Decodes one `advice` row.
    ///
    /// The category is the one column read leniently: a row whose category
    /// this build does not know is still a suggestion about a message, and
    /// the queue shows it without a category. The distribution is stricter
    /// about it, because a distribution that invents a shape teaches the
    /// model a preference nobody expressed — see `acceptedStats`.
    static func decode(_ row: Row) -> Decoded {
        let actionRaw: String? = row["action"]
        let confidenceRaw: String? = row["confidence"]
        let sourceRaw: String? = row["source"]
        let decisionRaw: String? = row["decision"]
        guard let action = actionRaw.flatMap(AdvisedAction.init(rawValue:)) else {
            return .unreadable(
                reason: "action '\(actionRaw ?? "null")' is not an action this build knows"
            )
        }
        guard let confidence = confidenceRaw.flatMap(AdviceConfidence.init(rawValue:)) else {
            return .unreadable(
                reason: "confidence '\(confidenceRaw ?? "null")' is not a confidence this build knows"
            )
        }
        guard let source = sourceRaw.flatMap(AdviceSource.init(rawValue:)) else {
            return .unreadable(
                reason: "source '\(sourceRaw ?? "null")' is not a source this build knows"
            )
        }
        guard let decision = decisionRaw.flatMap(AdviceDecision.init(rawValue:)) else {
            return .unreadable(
                reason: "decision '\(decisionRaw ?? "null")' is not a decision this build knows"
            )
        }
        let category = (row["category"] as String?)
            .flatMap(ContentCategory.init(rawValue:))
        return .readable(
            AdviceRecord(
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
        )
    }

    /// Decodes rows, skipping the ones this build cannot read.
    private static func decodeAll(_ rows: [Row], logger: Logger) -> [AdviceRecord] {
        var records: [AdviceRecord] = []
        records.reserveCapacity(rows.count)
        for row in rows {
            switch decode(row) {
            case .readable(let record):
                records.append(record)
            case .unreadable(let reason):
                report(row, reason: reason, logger: logger)
            }
        }
        return records
    }

    /// Reports a row this build could not read.
    ///
    /// The skip is never silent: a suggestion that vanishes from the queue
    /// without a word is indistinguishable from one that was never written,
    /// and that difference is exactly what is needed when a suggestion goes
    /// missing.
    private static func report(_ row: Row, reason: String, logger: Logger) {
        let id: Int64? = row["id"]
        logger.warning(
            "advice.rowUnreadable",
            metadata: [
                "id": .string(id.map { "\($0)" } ?? "unknown"),
                "reason": .string(reason),
            ]
        )
    }
}
