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
    ///
    /// A send that is still claimed, or that failed, is not listed either.
    /// The claim row exists from the moment the send starts (see
    /// `claimSend`), but the history says what Lagoon *did*: the client's
    /// title for a send row is "Sent message", and a failed send must not
    /// appear there as though the mail went out.
    /// Where the next page of history starts.
    ///
    /// `created_at` alone is not a cursor. A bulk operation writes one row
    /// per message inside the same millisecond, so several rows can share a
    /// timestamp — and a timestamp-only cursor drops or duplicates exactly
    /// the rows that straddle a page boundary. The id is the tiebreaker that
    /// makes the order total.
    public struct ActionListCursor: Sendable, Equatable {
        public let createdAt: Date
        public let id: Int64

        public init(createdAt: Date, id: Int64) {
            self.createdAt = createdAt
            self.id = id
        }
    }

    /// One page of history plus the size of the **whole** history.
    ///
    /// `totalCount` deliberately ignores both the page limit and the cursor:
    /// it is what lets the panel say "还有 N 条" instead of stopping silently
    /// at the hundredth row. A count of the page would always equal the
    /// page.
    public struct ActionListPage: Sendable, Equatable {
        public let actions: [AIAction]
        public let totalCount: Int
        /// Whether at least one older row exists past this page.
        ///
        /// Measured, not inferred. `actions.count == limit` is also true on
        /// the last page when the history happens to end on a page
        /// boundary — and a "load more" button that loads nothing is the
        /// silent dead end this whole change exists to remove. The query
        /// therefore asks for one row more than it returns.
        public let hasMore: Bool

        public init(actions: [AIAction], totalCount: Int, hasMore: Bool) {
            self.actions = actions
            self.totalCount = totalCount
            self.hasMore = hasMore
        }
    }

    public static func recent(
        accountId: UUID,
        since: Date? = nil,
        before: ActionListCursor? = nil,
        limit: Int = 50,
        db: LagoonDB
    ) async throws -> [AIAction] {
        try db.read { raw in
            try fetchPage(
                accountId: accountId, since: since, before: before, limit: limit, db: raw
            )
        }
    }

    /// A page of history **and** how long the history is, from one snapshot.
    ///
    /// Both reads share a single `db.read` closure on purpose: two separate
    /// reads could straddle a write, and the panel would then say "已显示
    /// 100/101 条" about a history that has 100 rows.
    public static func page(
        accountId: UUID,
        since: Date? = nil,
        before: ActionListCursor? = nil,
        limit: Int = 50,
        db: LagoonDB
    ) async throws -> ActionListPage {
        try db.read { raw in
            // One row past the page proves there is more. It is dropped
            // before the response is built — the caller asked for `limit`.
            let rows = try fetchPage(
                accountId: accountId, since: since, before: before,
                limit: limit + 1, db: raw
            )
            return ActionListPage(
                actions: Array(rows.prefix(limit)),
                totalCount: try countSync(accountId: accountId, since: since, db: raw),
                hasMore: rows.count > limit
            )
        }
    }

    /// The one history query. `recent` and `page` both run it, so the two
    /// entry points cannot develop different notions of "the history".
    private static func fetchPage(
        accountId: UUID,
        since: Date?,
        before: ActionListCursor?,
        limit: Int,
        db: Database
    ) throws -> [AIAction] {
        // Absent bounds are bound as sentinels rather than compiled into the
        // SQL. Three reasons: the guardrail forbids interpolating into SQL
        // anyway; one statement shape means one query plan; and
        // `0001-01-01` / `4001-01-01` sit outside any timestamp this table
        // can hold, so "no lower bound" and "no upper bound" are exact.
        //
        // `ai_actions_undo_of_idx` covers the correlated subquery. The
        // `(created_at, id)` row-value comparison is the keyset cursor: it
        // pages from a *position*, not from an offset, so a row inserted at
        // the top while the user is reading cannot shift the next page.
        let lower = since ?? Date.distantPast
        let upper = before ?? ActionListCursor(createdAt: .distantFuture, id: .max)
        let args: [DatabaseValueConvertible?] = [
            accountId, lower, upper.createdAt, upper.id, limit
        ]
        return try Row.fetchAll(db, sql: Self.pageSQL, arguments: StatementArguments(args))
            .map { try Self.decode($0) }
    }

    /// How many rows the history holds, ignoring the page. Same predicate as
    /// `pageSQL` minus the cursor and the limit — a count that filtered
    /// differently would make "还有 N 条" a number about a different list.
    private static func countSync(
        accountId: UUID,
        since: Date?,
        db: Database
    ) throws -> Int {
        try Int.fetchOne(
            db,
            sql: Self.countSQL,
            arguments: [accountId, since ?? Date.distantPast]
        ) ?? 0
    }

    /// `ORDER BY created_at DESC, id DESC`, not `created_at DESC` alone:
    /// rows written in the same millisecond (every bulk operation) would
    /// otherwise come back in an order SQLite is free to change between
    /// pages, which is how a keyset cursor skips rows.
    private static let pageSQL = """
        SELECT id, account_id, kind, payload, created_at, expires_at FROM ai_actions
        WHERE account_id = ? AND created_at >= ?
          AND (created_at, id) < (?, ?)
          AND NOT EXISTS (
              SELECT 1 FROM ai_actions u
              WHERE u.account_id = ai_actions.account_id
                AND u.kind = 'undo'
                AND json_extract(u.payload, '$.undoOf') = ai_actions.id
          )
          AND (
              kind <> 'send'
              OR json_extract(payload, '$.status') IS NULL
              OR json_extract(payload, '$.status') = 'sent'
          )
        ORDER BY created_at DESC, id DESC
        LIMIT ?
        """

    private static let countSQL = """
        SELECT COUNT(*) FROM ai_actions
        WHERE account_id = ? AND created_at >= ?
          AND NOT EXISTS (
              SELECT 1 FROM ai_actions u
              WHERE u.account_id = ai_actions.account_id
                AND u.kind = 'undo'
                AND json_extract(u.payload, '$.undoOf') = ai_actions.id
          )
          AND (
              kind <> 'send'
              OR json_extract(payload, '$.status') IS NULL
              OR json_extract(payload, '$.status') = 'sent'
          )
        """

    /// Resolves the `before=<id>` paging parameter into a cursor.
    ///
    /// The client pages by naming the last row it already has, not by
    /// sending back a timestamp: a timestamp assembled by the client would
    /// have to survive a date formatter on the way out and a parser on the
    /// way back, and a rounding difference of one millisecond would silently
    /// drop or repeat a row at every page boundary. The id is exact.
    ///
    /// Scoped by account, like every other read that takes an id from a
    /// request: an id from another account must not reveal that account's
    /// timestamps, and must not work as a cursor into it at all. Returns nil
    /// for an unknown id, which the route answers as a 400 rather than
    /// silently starting from the newest row — a page the user did not ask
    /// for is worse than an error they can see.
    public static func cursor(
        id: Int64,
        accountId: UUID,
        db: LagoonDB
    ) async throws -> ActionListCursor? {
        try db.read { raw in
            try Row.fetchOne(
                raw,
                sql: "SELECT created_at FROM ai_actions WHERE id = ? AND account_id = ?",
                arguments: [id, accountId]
            ).map { row in
                ActionListCursor(createdAt: row["created_at"], id: id)
            }
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


    // MARK: - Send claims

    /// The lifecycle of a send row.
    ///
    /// A send is not one moment but three: the request claims the right to
    /// send, the mail goes out, and the outcome is recorded. The claim
    /// exists so that the "go out" step can be made exactly-once — the
    /// whole point of the client's idempotency key.
    public enum SendStatus: String, Sendable {
        /// Claimed, mail not (yet) on the wire.
        case pending
        /// The mail is on the wire.
        case sent
        /// The send failed; the claim may be taken over by a later request.
        case failed

        /// Reads a status out of a payload.
        ///
        /// A row written *before* claims existed has no status at all, and
        /// the old code recorded a send only after the message was on the
        /// wire — so "no status" means "delivered", not "unknown".
        public static func resolved(_ raw: String?) -> SendStatus {
            guard let raw, let parsed = SendStatus(rawValue: raw) else { return .sent }
            return parsed
        }
    }

    /// What a send request is allowed to do next.
    public enum SendClaim: Sendable {
        /// The caller owns the send: nobody else may send this requestId.
        /// The row id is the claim row to complete (or release) afterwards.
        case claimed(rowId: Int64)
        /// A previous send with this requestId already went out. Its result
        /// is to be replayed, not re-sent.
        case alreadySent(AIAction)
        /// Another request holds this requestId and has not finished yet.
        case inFlight
    }

    /// Payload key carrying the claim state.
    static let sendStatusKey = "status"
    /// Payload key carrying the client's idempotency key.
    static let sendRequestIdKey = "requestId"
    /// Payload key carrying the reason a send failed.
    static let sendErrorKey = "error"

    /// How long a claim may be held before another request may take it
    /// over.
    ///
    /// A claim whose holder died mid-send (the process was killed, or a
    /// socket write hung forever) would otherwise block that requestId
    /// until the row expires 30 days later — the user could not send that
    /// mail again at all. The window has to be longer than any legitimate
    /// send: the SMTP client alone can spend 30 s per read, and the Sent
    /// copy is uploaded after that.
    public static let sendClaimLease: Duration = .seconds(600)

    /// The lease in seconds, for the date arithmetic that decides whether
    /// a claim is stale.
    static let sendClaimLeaseSeconds = TimeInterval(sendClaimLease.components.seconds)

    /// How long a request waits for the holder of a claim to finish before
    /// it reports the conflict.
    ///
    /// The alternative is to answer "busy" the moment the claim is taken,
    /// which is how a double-clicked send ends up telling the user "not
    /// sent" for a mail that is on its way. Waiting is bounded by the
    /// client's own interactive timeout, so the answer still arrives in
    /// time to be useful.
    public static let sendInFlightWait: Duration = .seconds(20)

    /// How often the wait re-reads the claim row.
    static let sendClaimPollInterval: Duration = .milliseconds(100)

    /// The state of a send row, read from its payload.
    public static func sendStatus(of action: AIAction) -> SendStatus {
        SendStatus.resolved(action.payload[Self.sendStatusKey])
    }

    /// Takes the right to send one message, atomically.
    ///
    /// The claim is what makes the client's idempotency key work under
    /// concurrency. The old shape — look the requestId up, and send if
    /// nothing is there — is a check-then-act race: two requests that
    /// arrive together both find nothing and both put the mail on the
    /// wire. The recipient then gets two copies, and the second audit
    /// INSERT only fails *after* the mail is gone, so the failure was
    /// logged and the request still answered 200.
    ///
    /// Here the winner is decided by the unique index
    /// `ai_actions_send_request_idx` itself: the claim row is INSERTed
    /// first, and only the request whose INSERT actually wrote a row may
    /// send. The loser is told what happened instead of sending.
    public static func claimSend(
        accountId: UUID,
        requestId: String,
        payload: [String: String],
        db: LagoonDB,
        waitForInFlight: Duration = Self.sendInFlightWait
    ) async throws -> SendClaim {
        let deadline = ContinuousClock.now.advanced(by: waitForInFlight)
        while true {
            switch try Self.attemptClaim(
                accountId: accountId, requestId: requestId, payload: payload, db: db
            ) {
            case .claimed(let rowId):
                return .claimed(rowId: rowId)
            case .alreadySent(let action):
                return .alreadySent(action)
            case .inFlight:
                // Somebody else is sending this requestId. Their send may
                // be a moment away from landing, so wait for the outcome
                // rather than report a conflict for a mail that is on its
                // way.
                guard ContinuousClock.now < deadline else { return .inFlight }
                try await Task.sleep(for: Self.sendClaimPollInterval)
            }
        }
    }

    /// One atomic attempt at the claim. Returns `.inFlight` when another
    /// request holds the claim and has not finished yet.
    private static func attemptClaim(
        accountId: UUID,
        requestId: String,
        payload: [String: String],
        db: LagoonDB
    ) throws -> SendClaim {
        // Read first. While another request holds the claim, the wait loop
        // polls here — and a poll must not take the database's write lock
        // every 100 ms just to be told "not yours".
        if let existing = try db.read({ raw in
            try Self.sendRow(accountId: accountId, requestId: requestId, db: raw)
        }) {
            let action = try Self.decode(existing)
            switch Self.sendStatus(of: action) {
            case .sent:
                return .alreadySent(action)
            case .failed:
                // The previous attempt failed: the claim may be taken over.
                break
            case .pending:
                let cutoff = Date().addingTimeInterval(-Self.sendClaimLeaseSeconds)
                // A claim whose holder is still inside the lease belongs to
                // a live request. One older than the lease belongs to a
                // request that died mid-send; leaving it pending would
                // block that requestId until the row expires 30 days later.
                guard action.createdAt < cutoff else { return .inFlight }
            }
        }

        // The write below is the authoritative decision: the read above is
        // only an optimisation, and the row may have moved on since.
        return try db.write { raw -> SendClaim in
            // The payload the claim row carries while the send is in
            // flight. It holds everything the finished row will hold, minus
            // the outcome — the requestId and the state are the store's
            // business, not the caller's.
            var pending = payload
            pending[Self.sendRequestIdKey] = requestId
            pending[Self.sendStatusKey] = SendStatus.pending.rawValue
            let pendingJSON = try Self.encode(pending)

            // `INSERT OR IGNORE` makes the claim atomic: the unique index
            // picks exactly one winner, and the losers see
            // `changesCount == 0` instead of a constraint error that would
            // have to be sniffed back into "somebody else won".
            try raw.execute(
                sql: "INSERT OR IGNORE INTO ai_actions (account_id, kind, payload) VALUES (?, 'send', ?)",
                arguments: [accountId, pendingJSON]
            )
            if raw.changesCount == 1 {
                guard let row = try Self.sendRow(
                    accountId: accountId, requestId: requestId, db: raw
                ) else {
                    throw StoreError.insertFailed
                }
                return .claimed(rowId: try Self.decode(row).id)
            }

            // Somebody else holds the claim. Read it and decide.
            guard let row = try Self.sendRow(
                accountId: accountId, requestId: requestId, db: raw
            ) else {
                // The INSERT was ignored for another reason — the account
                // foreign key, say. There is no claim row to speak of, and
                // reporting "in flight" would hide a real error behind a
                // busy answer.
                throw StoreError.insertFailed
            }
            let existing = try Self.decode(row)
            switch Self.sendStatus(of: existing) {
            case .sent:
                return .alreadySent(existing)
            case .failed:
                // The previous attempt failed and the user is retrying the
                // same requestId. Take the claim over — the compare-and-swap
                // below is what keeps two retries from both taking it.
                return try Self.takeOver(
                    row: existing, expected: .failed, payload: pending, db: raw
                )
            case .pending:
                // In flight — unless the holder is gone. A claim older than
                // the lease belongs to a request that died mid-send; leaving
                // it pending would block that requestId until it expires.
                let cutoff = Date().addingTimeInterval(-Self.sendClaimLeaseSeconds)
                guard existing.createdAt < cutoff else { return .inFlight }
                return try Self.takeOver(
                    row: existing, expected: .pending, payload: pending,
                    staleBefore: cutoff, db: raw
                )
            }
        }
    }

    /// Takes a claim row over from a previous attempt.
    ///
    /// The compare-and-swap is the whole point: two requests that both see
    /// a stale row must not both take it over, or the mail goes out twice.
    /// The loser of the swap gets `.inFlight` and waits.
    private static func takeOver(
        row: AIAction,
        expected: SendStatus,
        payload: [String: String],
        staleBefore: Date? = nil,
        db: Database
    ) throws -> SendClaim {
        // `created_at` moves with the claim: it is the moment this attempt
        // started, and the lease is measured from it.
        let now = Date()
        let sql: String
        let args: [DatabaseValueConvertible?]
        if let staleBefore {
            // A pending claim may only be taken over while it is *still*
            // stale. Without this condition the swap would also match a
            // claim another request has just refreshed, and the two would
            // both believe they own the send.
            sql = """
                UPDATE ai_actions
                SET payload = ?, created_at = ?
                WHERE id = ? AND json_extract(payload, '$.status') = ? AND created_at < ?
                """
            args = [try Self.encode(payload), now, row.id, expected.rawValue, staleBefore]
        } else {
            sql = """
                UPDATE ai_actions
                SET payload = ?, created_at = ?
                WHERE id = ? AND json_extract(payload, '$.status') = ?
                """
            args = [try Self.encode(payload), now, row.id, expected.rawValue]
        }
        try db.execute(sql: sql, arguments: StatementArguments(args))
        guard db.changesCount == 1 else {
            // Somebody else took the row over between our read and this
            // write. They are the ones sending now.
            return .inFlight
        }
        return .claimed(rowId: row.id)
    }

    /// Folds the outcome of a delivered mail into its claim row.
    ///
    /// The payload is merged, not replaced: the claim row already carries
    /// the requestId, and that key is what the unique index is built on.
    /// Losing it would drop the row out of the index, and the next request
    /// with the same requestId would start a second copy of the same mail.
    public static func completeSend(
        id: Int64,
        payload: [String: String],
        db: LagoonDB
    ) async throws {
        try db.write { raw in
            guard let row = try Row.fetchOne(
                raw,
                sql: "SELECT id, account_id, kind, payload, created_at, expires_at FROM ai_actions WHERE id = ?",
                arguments: [id]
            ) else {
                throw StoreError.insertFailed
            }
            var merged = try Self.decode(row).payload
            for (key, value) in payload { merged[key] = value }
            merged[Self.sendStatusKey] = SendStatus.sent.rawValue
            try raw.execute(
                sql: "UPDATE ai_actions SET payload = ? WHERE id = ?",
                arguments: [try Self.encode(merged), id]
            )
        }
    }

    /// Marks a claimed send as failed, so that the next request with the
    /// same idempotency key may take the claim over and try again.
    ///
    /// `reason` must be a stable label, never provider text: the payload
    /// is readable by the client.
    public static func failSend(
        id: Int64,
        reason: String,
        db: LagoonDB
    ) async throws {
        try db.write { raw in
            guard let row = try Row.fetchOne(
                raw,
                sql: "SELECT id, account_id, kind, payload, created_at, expires_at FROM ai_actions WHERE id = ?",
                arguments: [id]
            ) else {
                throw StoreError.insertFailed
            }
            var merged = try Self.decode(row).payload
            merged[Self.sendStatusKey] = SendStatus.failed.rawValue
            merged[Self.sendErrorKey] = reason
            try raw.execute(
                sql: "UPDATE ai_actions SET payload = ? WHERE id = ?",
                arguments: [try Self.encode(merged), id]
            )
        }
    }

    /// The send row for one idempotency key, whatever state it is in.
    private static func sendRow(
        accountId: UUID,
        requestId: String,
        db: Database
    ) throws -> Row? {
        try Row.fetchOne(
            db,
            sql: """
                SELECT id, account_id, kind, payload, created_at, expires_at
                FROM ai_actions
                WHERE account_id = ? AND kind = 'send'
                  AND json_extract(payload, '$.requestId') = ?
                LIMIT 1
                """,
            arguments: [accountId, requestId]
        )
    }

    /// Looks up a **completed** send by the client's idempotency key.
    ///
    /// "Completed" is the whole point of the query: a claim that is still in
    /// flight, or one whose send failed, is not a mail that went out, and
    /// replaying it would tell the client "sent" for a message that is not
    /// on the wire. Rows written before claims existed carry no status and
    /// count as completed — the old code recorded them only after the
    /// message was on the wire.
    ///
    /// The routes use this as the fast path; `claimSend` is the authority
    /// that makes the send exactly-once.
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
                      AND (json_extract(payload, '$.status') IS NULL
                           OR json_extract(payload, '$.status') = 'sent')
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
    ///
    /// A send that is still claimed or that failed is not a reply: the
    /// classifier would stop asking about a message the user never answered.
    /// Rows written before claims existed carry no status and count as
    /// replies, which is what they are.
    public static func repliedRemoteIds(
        accountId: UUID,
        db: LagoonDB
    ) async throws -> Set<String> {
        let sql = """
            SELECT DISTINCT json_extract(payload, '$.remoteId') AS rid
            FROM ai_actions
            WHERE account_id = ? AND kind = 'send' AND json_extract(payload, '$.remoteId') IS NOT NULL
              AND (json_extract(payload, '$.status') IS NULL
                   OR json_extract(payload, '$.status') = 'sent')
        """
        return try db.read { db in
            let rows = try Row.fetchAll(db, sql: sql, arguments: [accountId])
            return Set(rows.compactMap { $0.optionalText("rid") })
        }
    }

    /// Audited (kind, createdAt) events for the time-saved report, with
    /// actions that were later undone excluded — an undone archive is not a
    /// handled message. Cross-client reply signals (`send` with a `sentFolder`
    /// marker, V2 A2) are excluded too: no Lagoon work happened. A send that
    /// is still claimed, or that failed, saved no time either. `since`
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
              AND (a.kind <> 'send'
                   OR json_extract(a.payload, '$.status') IS NULL
                   OR json_extract(a.payload, '$.status') = 'sent')
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
    ///
    /// ## Only sender-scoped rows count here
    ///
    /// A message-scoped override ("only this mail") must NOT reach this
    /// lookup: this map is consulted for *every* mail from a sender, and a
    /// message-scoped row that leaked in here would re-file the sender's
    /// whole mailbox — the exact surprise audit P2-13 is about. The
    /// `scope = 'sender'` predicate is therefore load-bearing, not a filter.
    ///
    /// Rows written before the scope column existed default to `sender`, so
    /// every existing install behaves exactly as it did.
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
                WHERE o.account_id = ? AND o.scope = 'sender'
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

    /// Per-**message** override lookup, keyed by remote id.
    ///
    /// This is the narrow scope's read path: 「只改这一封」 writes a row here
    /// and only this mail moves. The briefing consults it **before** the
    /// sender-level map, so a message-scoped override wins over a
    /// sender-level one for that one mail — which is the only ordering that
    /// makes both scopes mean what they say.
    ///
    /// A message-scoped override is deliberately **not** undone by writing a
    /// counter-override row: the counter would have to be message-scoped too,
    /// and the ranking (newest row per remote id) already expresses "the
    /// latest override for this mail wins". See `insertOverrideSync`.
    public static func overridesByMessage(
        accountId: UUID,
        db: LagoonDB
    ) async throws -> [String: BriefingGroup] {
        let sql = """
            WITH ranked AS (
                SELECT o.remote_id, o.to_group,
                    row_number() OVER (PARTITION BY o.remote_id ORDER BY o.created_at DESC, o.rowid DESC) AS rn
                FROM ai_overrides o
                WHERE o.account_id = ? AND o.scope = 'message'
            )
            SELECT remote_id, to_group FROM ranked WHERE rn = 1
        """
        return try db.read { db in
            var result: [String: BriefingGroup] = [:]
            for row in try Row.fetchAll(db, sql: sql, arguments: [accountId]) {
                let remoteId: String = row["remote_id"]
                let groupStr: String = row["to_group"]
                if let group = BriefingGroup(rawValue: groupStr) {
                    result[remoteId] = group
                }
            }
            return result
        }
    }

    /// Writes an override row and returns its id.
    ///
    /// The id is what lets the undo remove **this** rule rather than
    /// "the newest rule for this mail" — see `deleteMessageOverride`.
    public static func insertOverride(
        accountId: UUID,
        remoteId: String,
        fromGroup: BriefingGroup,
        toGroup: BriefingGroup,
        scope: OverrideScope = .sender,
        db: LagoonDB
    ) async throws -> Int64 {
        try db.write {
            try insertOverrideSync(
                accountId: accountId, remoteId: remoteId,
                fromGroup: fromGroup, toGroup: toGroup, scope: scope, db: $0
            )
        }
    }

    /// Sync core for callers inside a transaction.
    ///
    /// ## Why the scope is written, not derived
    ///
    /// The row's `remote_id` is the mail the user acted on. For a
    /// sender-scoped override that mail is a *sample* of the sender — the
    /// override reaches every mail from that address. For a message-scoped
    /// override the same id is the *subject* of the rule. Nothing in the row
    /// distinguishes the two on its own, so the scope is stored with it.
    ///
    /// ## Why the sender scope's undo is "write a counter-row"
    ///
    /// The audit log is append-only, and the undo path for the sender scope
    /// works by writing a counter-override (from = to, to = from) that wins
    /// the ranking by being newer. The counter-row carries the **same**
    /// scope as the row it reverses — if it were written as `sender` for a
    /// narrow rule, undoing a 「只改这一封」 would silently re-file the whole
    /// sender's mailbox, which is the surprise this work exists to remove.
    ///
    /// ## Why the message scope's undo *deletes* instead
    ///
    /// A counter-row would pin the mail to the group it was in when the
    /// user made the change — a **stale** value. If the sender's rule has
    /// moved on since, the mail would stay in the old group instead of
    /// falling back to the sender's current rule (or the heuristic), which
    /// is what "undo my one-off change" means.
    ///
    /// So the narrow rule is removed, and the mail falls back — which is
    /// exactly what the briefing's precedence does when the narrow map has
    /// no entry for it.
    public static func insertOverrideSync(
        accountId: UUID,
        remoteId: String,
        fromGroup: BriefingGroup,
        toGroup: BriefingGroup,
        scope: OverrideScope = .sender,
        db: Database
    ) throws -> Int64 {
        guard let id = try Int64.fetchOne(
            db,
            sql: """
                INSERT INTO ai_overrides (account_id, remote_id, from_group, to_group, scope)
                VALUES (?, ?, ?, ?, ?)
                RETURNING id
                """,
            arguments: [accountId, remoteId, fromGroup.rawValue, toGroup.rawValue, scope.rawValue]
        ) else {
            throw StoreError.insertFailed
        }
        return id
    }

    /// Removes one **message-scoped** override row.
    ///
    /// ## Why removal, and not a counter-row
    ///
    /// A counter-row would leave the mail pinned to the group it was in
    /// when the user made the change. Undo must instead let the mail fall
    /// back to the sender's rule (or the heuristic) — the state the user
    /// would be in if they had never made the one-off change.
    ///
    /// ## Why the id, and what happens without it
    ///
    /// The exact row is named by `overrideId`, which the classify route
    /// records in the audit payload. That matters because "the newest rule
    /// for this mail" is not always the rule the undone action wrote: two
    /// 「改分组」 on the same mail in a row leave two rules, and undoing the
    /// older one must not remove the newer one's rule.
    ///
    /// Rows written before the payload carried the id have no id to match,
    /// so they fall back to matching the rule by what the action recorded
    /// (from → to), newest first. That is the same row in every case where
    /// the action was the last one to write a rule for this mail.
    public static func deleteMessageOverride(
        accountId: UUID,
        remoteId: String,
        overrideId: Int64?,
        fromGroup: BriefingGroup,
        toGroup: BriefingGroup,
        db: LagoonDB
    ) async throws {
        try db.write { raw in
            if let overrideId {
                try raw.execute(
                    sql: """
                        DELETE FROM ai_overrides
                        WHERE id = ? AND account_id = ? AND scope = 'message'
                        """,
                    arguments: [overrideId, accountId]
                )
            } else {
                try raw.execute(
                    sql: """
                        DELETE FROM ai_overrides
                        WHERE id = (
                            SELECT id FROM ai_overrides
                            WHERE account_id = ? AND remote_id = ?
                              AND scope = 'message'
                              AND from_group = ? AND to_group = ?
                            ORDER BY created_at DESC, rowid DESC
                            LIMIT 1
                        )
                        """,
                    arguments: [accountId, remoteId, fromGroup.rawValue, toGroup.rawValue]
                )
            }
        }
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
///
/// ## Why the variants are sealed
///
/// A draft is generated *from* the mail, so it carries the substance of
/// somebody else's email — and it used to be stored in the clear, in a
/// column the product's own manual did not list as plaintext. The body is
/// sealed with `BodyCipher`; the drafts are sealed with the same key and
/// the same envelope format, so the store's guarantee is one guarantee
/// rather than two. See `DraftCipher` for the shape and why the whole array
/// is one envelope.
public enum DraftReplyStore {
    public static func create(
        accountId: UUID,
        remoteId: String,
        variants: [String],
        db: LagoonDB
    ) async throws -> DraftReply {
        // Sealed **before** the write, not after: a draft that cannot be
        // sealed must never reach the table in the clear. The write fails
        // loudly and nothing is stored.
        let sealed = try DraftCipher.seal(variants)
        return try db.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    INSERT INTO draft_replies (account_id, remote_id, variants)
                    VALUES (?, ?, ?)
                    RETURNING id, account_id, remote_id, variants, chosen_variant, created_at
                    """,
                arguments: [accountId, remoteId, sealed]
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

    /// Decodes one row.
    ///
    /// ## Why this throws instead of returning an empty array
    ///
    /// The variants column holds an envelope. If it cannot be opened, the
    /// honest answer is "this draft cannot be read", not "this draft has no
    /// variants" — an empty list and a broken one look identical on screen,
    /// and the difference between them is the difference between "the AI
    /// wrote nothing" and "the store is broken". A reader that swallowed
    /// the failure would turn a storage fault into a silent downgrade.
    ///
    /// `chosen_variant` is an index into the array, and it survives the
    /// round trip because sealing preserves the order of the elements.
    public static func decode(_ row: Row) throws -> DraftReply {
        let stored: String = row["variants"]
        let chosen: Int? = row["chosen_variant"]
        return DraftReply(
            id: row["id"],
            accountId: row["account_id"],
            remoteId: row["remote_id"],
            variants: try DraftCipher.open(stored),
            chosenVariant: chosen,
            createdAt: row["created_at"]
        )
    }
}
