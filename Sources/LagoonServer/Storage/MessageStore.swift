import Foundation
import GRDB
import LagoonKit

public enum MessageStore {
    // Every query uses `?` placeholders — no SQL is ever concatenated. The
    // SELECT column list is repeated literally per query (the CI guardrail
    // forbids interpolation inside SQL literals, even for constants).

    /// Upsert a polled header row. `listUnsubscribe` is the presence of the
    /// `List-Unsubscribe` header on the metadata response; it feeds the
    /// heuristic briefing classifier. Defaults to false so existing call sites
    /// (and tests) are unaffected.
    ///
    /// The `ON CONFLICT` clause is a *merge*, never a blind overwrite, and is
    /// deliberately asymmetric per column:
    /// - `is_read` / `list_unsubscribe` are monotonic OR: read state is locally
    ///   authoritative, so a remote flag clear never un-reads a message here.
    ///   The one deliberate exception is the undo route, which clears the
    ///   column with a direct UPDATE — that is what undoing a mark-read means.
    ///   A sync round that fetched headers before that UPDATE and upserts after
    ///   it writes the old TRUE back, but for that one round only: the next
    ///   fetch sees the cleared remote flag and OR-ing FALSE leaves it FALSE.
    /// - `subject` / `snippet` keep the stored value when the incoming row has
    ///   none. `readStateFlips` re-delivers headers without a snippet, and a
    ///   plain `EXCLUDED.snippet` would blank the preview of every message the
    ///   user opens.
    /// - `unsubscribe_links` is replaced by the value computed above, which
    ///   already contains the previously stored links.
    public static func upsert(
        _ m: MessageHeader,
        listUnsubscribe: Bool = false,
        unsubscribeLinks: [String] = [],
        db: LagoonDB
    ) async throws {
        try db.write { db in
            // SQLite has no array type, so the "existing || new, first
            // occurrence wins" merge the Postgres upsert used to do happens
            // here, inside the write transaction: read what is stored,
            // merge, write. Repeated syncs cannot grow or shrink the array.
            //
            // This matters because the two callers supply disjoint halves of
            // the candidate set: the sync round only ever sees the
            // `List-Unsubscribe` header, while the body-scraped links are
            // merged in later by `mergeUnsubscribeLinks`. Writing the raw
            // input here would wipe them on the very next sync round.
            let existing = try Row.fetchOne(
                db,
                sql: "SELECT unsubscribe_links FROM message_headers WHERE account_id = ? AND remote_id = ?",
                arguments: [m.accountId, m.remoteId]
            ).flatMap { $0.decodedLinks() } ?? []
            let links = existing.isEmpty
                ? try Self.linksJSON(unsubscribeLinks)
                : try Self.linksJSON(Self.mergeLinks(existing + unsubscribeLinks))
            let sql = """
                INSERT INTO message_headers (
                    id, account_id, remote_id, thread_id,
                    from_address, from_name, subject, snippet,
                    received_at, is_read, is_archived, list_unsubscribe,
                    message_id_header, in_reply_to, references_header,
                    unsubscribe_links, fetched_at
                ) VALUES (
                    ?, ?, ?, ?,
                    ?, ?, ?, ?,
                    ?, ?, ?, ?,
                    ?, ?, ?,
                    ?, strftime('%Y-%m-%d %H:%M:%f','now')
                )
                ON CONFLICT (account_id, remote_id) DO UPDATE SET
                    subject = CASE WHEN EXCLUDED.subject = '' THEN message_headers.subject ELSE EXCLUDED.subject END,
                    snippet = CASE WHEN EXCLUDED.snippet = '' THEN message_headers.snippet ELSE EXCLUDED.snippet END,
                    is_read = message_headers.is_read OR EXCLUDED.is_read,
                    list_unsubscribe = message_headers.list_unsubscribe OR EXCLUDED.list_unsubscribe,
                    message_id_header = COALESCE(EXCLUDED.message_id_header, message_headers.message_id_header),
                    in_reply_to = COALESCE(EXCLUDED.in_reply_to, message_headers.in_reply_to),
                    references_header = COALESCE(EXCLUDED.references_header, message_headers.references_header),
                    unsubscribe_links = EXCLUDED.unsubscribe_links,
                    fetched_at = strftime('%Y-%m-%d %H:%M:%f','now')
            """
            try db.execute(sql: sql, arguments: [
                m.id, m.accountId, m.remoteId, m.threadId,
                m.fromAddress, m.fromName ?? "", m.subject ?? "", m.snippet ?? "",
                m.receivedAt, m.isRead, m.isArchived, listUnsubscribe,
                m.messageIdHeader, m.inReplyTo, m.references,
                links
            ])
        }
    }

    /// 把一条 header 标记为「已发送」。
    ///
    /// ## Why this is not part of `upsert`
    ///
    /// `upsert` deliberately does **not** write `is_deleted`, and for the same
    /// reason it must not write `is_sent`: both facts come from *which folder
    /// the row was synced from*, not from anything in the message itself. A
    /// header arriving from the INBOX is by definition not sent, whatever its
    /// `From:` says — the reply Lagoon sends gets `From:` set to the user's own
    /// address and would otherwise flip itself to "sent" on the next sync of
    /// the inbox, which is how a mail you sent ends up filed as received.
    ///
    /// The flag is therefore set once, by the Sent-folder sync, and only ever
    /// cleared by a hard delete.
    public static func markSent(
        remoteId: String,
        accountId: UUID,
        db: Database
    ) throws {
        try db.execute(
            sql: "UPDATE message_headers SET is_sent = TRUE WHERE remote_id = ? AND account_id = ?",
            arguments: [remoteId, accountId]
        )
    }

    /// Merge discovered unsubscribe candidates into a header row, first
    /// occurrence wins so harvest order (header links first, then body) is
    /// preserved and repeated syncs cannot grow the array. Best-effort at
    /// every call site: discovery failure must never fail the read or the
    /// action that found the links.
    public static func mergeUnsubscribeLinks(
        remoteId: String,
        accountId: UUID,
        links: [String],
        db: LagoonDB
    ) async throws {
        guard !links.isEmpty else { return }
        try db.write { db in
            let existing = try Row.fetchOne(
                db,
                sql: "SELECT unsubscribe_links FROM message_headers WHERE account_id = ? AND remote_id = ?",
                arguments: [accountId, remoteId]
            ).flatMap { $0.decodedLinks() } ?? []
            let merged = try Self.linksJSON(Self.mergeLinks(existing + links))
            try db.execute(
                sql: "UPDATE message_headers SET unsubscribe_links = ? WHERE remote_id = ? AND account_id = ?",
                arguments: [merged, remoteId, accountId]
            )
        }
    }

    /// The unsubscribe candidates harvested so far: the `List-Unsubscribe`
    /// header links seen by the sync round, plus anything later scraped out
    /// of the message body. Empty when the row is unknown.
    public static func unsubscribeLinks(
        remoteId: String,
        accountId: UUID,
        db: LagoonDB
    ) async throws -> [String] {
        try db.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT unsubscribe_links FROM message_headers WHERE account_id = ? AND remote_id = ?",
                arguments: [accountId, remoteId]
            )?.decodedLinks() ?? []
        }
    }

    /// First occurrence wins across the concatenation.
    static func mergeLinks(_ links: [String]) -> [String] {
        var seen = Set<String>()
        return links.filter { seen.insert($0).inserted }
    }

    static func linksJSON(_ links: [String]) throws -> String {
        String(decoding: try JSONEncoder().encode(links), as: UTF8.self)
    }

    /// 聚合匹配臂：`sender` 精确匹配发件人地址；`keyword` 对主题做大小写
    /// 不敏感的包含匹配（值经 LIKE 特殊字符转义后绑定，SQL 分支均为静态字面量）。
    public enum StackMatch: Sendable {
        case sender(String)
        case keyword(String)
    }

    /// Escape LIKE metacharacters so a user keyword like `100%` or `a_b`
    /// matches literally. The `%…%` wrapping happens after escaping.
    static func likePattern(containing value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return "%\(escaped)%"
    }

    /// Newest headers for the All-Messages surface and its lenses.
    /// - `archived = true` serves the 档案柜 (已归档 built-in stack); the
    ///   default lists the live inbox (is_archived FALSE).
    /// - `deleted = true` serves the 废纸篓. This is the *only* way to list
    ///   trashed mail: every other view filters them out, which is correct
    ///   (they should not pollute the inbox or the unread counts) but left the
    ///   Trash with no list at all — so a user who deleted a mail by mistake
    ///   had no way to find it except an 8-second undo toast.
    /// - `stackMatch` narrows to one 聚合规则.
    ///
    /// `deleted` and `archived` are separate axes, and the trash listing passes
    /// `deleted: true` with `archived: false` on purpose: a message that was
    /// archived and then deleted belongs to the trash, and showing it under
    /// 已归档 at the same time would put one row in two places.
    ///
    /// The pin join is what lets the client render pin state: pins live in
    /// their own table, so a plain `message_headers` read leaves the client
    /// with no way to tell a pinned mail from an unpinned one.
    /// Shared WHERE clause for `recent()` and `count()` so the badge
    /// total can never drift from the list it labels. Returns the clause
    /// (starting at WHERE) plus its bound arguments in order.
    ///
    /// Columns carry the `h` alias and the clause never interpolates a value
    /// into the SQL text, because `ci-guardrails.sh` rule 1 forbids that — and
    /// rightly: it is the shape that lets a caller-supplied string reach a
    /// query. `reconcileInbox` states the same three axes against the bare
    /// table; see its doc comment for why that duplication is deliberate and
    /// what keeps the two in step.
    static func filterSQL(
        accountId: UUID,
        sender: String?,
        archived: Bool,
        deleted: Bool = false,
        sent: Bool = false,
        stackMatch: StackMatch?,
        receivedAfter: Date? = nil,
    ) -> (String, [DatabaseValueConvertible?]) {
        // 「已发送」是第三个**独立轴**，与 archived / deleted 互斥。
        //
        // 互斥而不是叠加，是 R1 最重要的一个决定。Sent 是服务器上的一个真
        // 实文件夹：我发出的邮件如果同时被归档（is_archived=TRUE），它会同时
        // 出现在「已发送」和「已归档」两个列表里——而这两个列表的交集为空是
        // 用户的心智模型（QQ 邮箱、Gmail、Outlook 都是如此）。
        //
        // 这也延续了 R1 之前确立的形状：`deleted` 忽略 archived 维度，理由
        // 完全一样——一封邮件只能在一个地方，否则「它在哪个列表里」这个问题
        // 就没有答案了。
        var clause = "WHERE h.account_id = ? AND h.is_deleted = "
        clause += deleted ? "TRUE" : "FALSE"
        if sent {
            // Sent ignores the archived axis for the same reason Trash does:
            // an archived reply I sent belongs to 已发送, and putting it in both
            // makes "which list is it in" unanswerable.
            clause += " AND h.is_sent = TRUE"
        } else if deleted {
            // The Trash likewise ignores the archived axis.
            //
            // Without this, a message that was archived and *then* deleted
            // matched neither listing: the trash query asked for
            // `is_archived = FALSE` and the row is TRUE, while the archive
            // query asked for `is_deleted = FALSE` and the row is TRUE too. The
            // mail existed on the server in the Trash folder and was reachable
            // from no list in the app — permanently invisible, which is the one
            // outcome worse than "no trash view at all".
        } else {
            clause += " AND h.is_archived = "
            clause += archived ? "TRUE" : "FALSE"
            // The inbox, the archive and every rule listing **exclude** sent
            // mail. Without this, opening 已发送 once would make every reply
            // the user had ever sent appear in their inbox as if it had just
            // arrived — the single most confusing thing this axis could do, and
            // the direction the data flows on its own (a reply is written by
            // `refresh`, not by a user filing it).
            clause += " AND h.is_sent = FALSE"
        }
        var arguments: [DatabaseValueConvertible?] = [accountId]
        switch stackMatch {
        case .sender(let address):
            clause += "\n            AND h.from_address = ?"
            arguments.append(address)
        case .keyword(let value):
            clause += "\n            AND h.subject LIKE ? ESCAPE '\\'"
            arguments.append(likePattern(containing: value))
        case nil:
            break
        }
        if sender != nil {
            clause += "\n            AND h.from_address = ?"
            arguments.append(sender)
        }
        // A lower time bound, not a row cap. The briefing's window is "the
        // last N days", which is what the user actually means by "recent" —
        // a fixed row count silently drops mail on a busy week and pads the
        // feed with stale mail on a quiet one.
        if let receivedAfter {
            clause += "\n            AND h.received_at >= ?"
            arguments.append(receivedAfter)
        }
        return (clause, arguments)
    }

    public static func recent(
        forAccount accountId: UUID,
        limit: Int,
        sender: String? = nil,
        archived: Bool = false,
        deleted: Bool = false,
        sent: Bool = false,
        stackMatch: StackMatch? = nil,
        receivedAfter: Date? = nil,
        db: LagoonDB
    ) async throws -> [MessageHeader] {
        let (whereClause, filterArgs) = filterSQL(
            accountId: accountId, sender: sender, archived: archived, deleted: deleted,
            sent: sent, stackMatch: stackMatch, receivedAfter: receivedAfter
        )
        // Assembled with joined() rather than interpolation: the SQL
        // guardrail rejects `\()` inside a SELECT literal, and `+`
        // concatenation with a SQL literal, even when the spliced piece
        // is a static fragment with bound parameters.
        let sql = [
            """
            SELECT h.id, h.account_id, h.remote_id, h.thread_id, h.from_address,
                   NULLIF(h.from_name, '') AS from_name,
                   NULLIF(h.subject, '') AS subject,
                   NULLIF(h.snippet, '') AS snippet,
                   h.received_at, h.is_read, h.is_archived, h.is_deleted, h.is_sent,
                   h.message_id_header, h.in_reply_to, h.references_header,
                   (message_pins.account_id IS NOT NULL) AS is_pinned
            FROM message_headers h
            LEFT JOIN message_pins
                   ON message_pins.account_id = h.account_id
                  AND message_pins.remote_id = h.remote_id
            """,
            whereClause,
            """
            ORDER BY h.received_at DESC
            LIMIT ?
            """,
        ].joined(separator: "\n")
        var arguments = filterArgs
        arguments.append(limit)
        return try db.read { db in
            try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
                .map { try Self.decode($0) }
        }
    }

    /// Single header by provider-native id (UIDVALIDITY-reset-safe: UIDs are
    /// only unique within an account, never globally).
    ///
    /// Selects `is_sent` explicitly. `decode` tolerates its absence (defaulting
    /// to false) because queries that predate the R1 column legitimately lack
    /// it — but that tolerance is exactly why its omission here was invisible:
    /// a single-message read would report a sent reply as received mail, with
    /// no error anywhere. `recent()` has always selected it.
    public static func find(
        remoteId: String,
        accountId: UUID,
        db: LagoonDB
    ) async throws -> MessageHeader? {
        let sql = """
            SELECT id, account_id, remote_id, thread_id, from_address,
                   NULLIF(from_name, '') AS from_name,
                   NULLIF(subject, '') AS subject,
                   NULLIF(snippet, '') AS snippet,
                   received_at, is_read, is_archived, is_deleted, is_sent,
                   message_id_header, in_reply_to, references_header
            FROM message_headers
            WHERE account_id = ? AND remote_id = ?
            LIMIT 1
        """
        return try db.read { db in
            try Row.fetchOne(db, sql: sql, arguments: [accountId, remoteId])
                .map { try Self.decode($0) }
        }
    }

    /// Wipes every header for an account (UIDVALIDITY change → full resync).
    /// Pins/drafts live in their own tables and are intentionally preserved.
    public static func deleteAll(accountId: UUID, db: LagoonDB) async throws {
        let sql = "DELETE FROM message_headers WHERE account_id = ?"
        try db.write { try $0.execute(sql: sql, arguments: [accountId]) }
    }

    /// Remove non-archived rows that no longer exist in the provider's inbox.
    /// Archived rows are retained because they represent messages Lagoon moved
    /// out of the inbox intentionally and may still need local history/undo.
    /// **Deleted rows are retained for the same reason** — they sit in the
    /// server's Trash and `is_deleted` must survive reconcile or the undo
    /// would restore a row that no longer exists.
    ///
    /// **Sent rows are retained for the same reason, and by the same rule.**
    /// Sent rows used to fall through this predicate: it listed
    /// `is_archived`/`is_deleted` but not `is_sent`, which R1 added later. That
    /// divergence was not cosmetic: `SentRoutes`
    /// writes sent rows with `is_archived = FALSE` and `is_deleted = FALSE`
    /// (the sync loop hardcodes `isArchived: false`), so every reply the user
    /// had ever sent fell straight through this predicate and was deleted
    /// from `message_headers` — taking its cached body with it via
    /// `ON DELETE CASCADE`, and orphaning `draft_replies`/`ai_overrides`,
    /// which carry no FK. The list came back on the next GET, so it read as
    /// a flicker; the classifications the user had taught it did not.
    ///
    /// The three axes are therefore spelled out here as a literal, and this
    /// predicate is now a **second** copy of the inbox definition rather than a
    /// derived one.
    ///
    /// That was tried and reverted. `filterSQL` gained an alias parameter so
    /// this could call it — and the alias has to be interpolated into the SQL
    /// text, which `ci-guardrails.sh` rule 1 exists to forbid (correctly: it is
    /// the shape that lets a caller-supplied string reach a query). Parameterising
    /// the columns to dodge that just traded one interpolation for eight.
    /// The project already has the sanctioned shape for this — assemble with
    /// `[literal, whereClause].joined(separator:)`, as `recent()` and `count()`
    /// do — but joining is no help when the shared piece *is* the SQL.
    ///
    /// So the duplication stays, deliberately, and the guard against drift is
    /// a test rather than an abstraction: `SentListingTests` asserts this exact
    /// predicate against a sent row. A third axis added to `filterSQL` without
    /// being added here turns that test red, which is the moment to fix it.
    /// Adding it here without adding it to `filterSQL` turns it red too.
    public static func reconcileInbox(
        accountId: UUID,
        keeping remoteIds: Set<String>,
        db: LagoonDB
    ) async throws {
        try db.write { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT remote_id
                    FROM message_headers
                    WHERE account_id = ?
                      AND is_archived = FALSE
                      AND is_deleted = FALSE
                      AND is_sent = FALSE
                    """,
                arguments: [accountId]
            )
            let localIds = rows.compactMap { $0.optionalText("remote_id") }
            for remoteId in localIds where !remoteIds.contains(remoteId) {
                try db.execute(
                    sql: "DELETE FROM message_headers WHERE account_id = ? AND remote_id = ?",
                    arguments: [accountId, remoteId]
                )
            }
        }
    }

    public static func markRead(
        remoteId: String,
        accountId: UUID,
        db: LagoonDB
    ) async throws {
        try await setRead(remoteId: remoteId, accountId: accountId, isRead: true, db: db)
    }

    public static func setRead(
        remoteId: String,
        accountId: UUID,
        isRead: Bool,
        db: LagoonDB
    ) async throws {
        try db.write {
            _ = try setReadSync(
                remoteId: remoteId, accountId: accountId, isRead: isRead, db: $0
            )
        }
    }

    /// Sync core for callers inside a transaction (the read route composes the
    /// flag flip with the audit insert in one `pool.write` closure). Returns
    /// the value it replaced — nil when the row does not exist, in which case
    /// the UPDATE matched nothing.
    ///
    /// The previous value matters because undoing a read-state change has to
    /// restore *that*, not always flip to unread: marking a read mail as
    /// unread is a first-class action here, and its inverse is "read again".
    /// The read route reads it inside the same transaction as the audit row so
    /// the row's `previousIsRead` payload can never disagree with what was
    /// actually overwritten.
    public static func setReadSync(
        remoteId: String,
        accountId: UUID,
        isRead: Bool,
        db: Database
    ) throws -> Bool? {
        let previous: Bool? = try Row.fetchOne(
            db,
            sql: "SELECT is_read FROM message_headers WHERE remote_id = ? AND account_id = ?",
            arguments: [remoteId, accountId]
        )?["is_read"]
        try db.execute(
            sql: "UPDATE message_headers SET is_read = ? WHERE remote_id = ? AND account_id = ?",
            arguments: [isRead, remoteId, accountId]
        )
        return previous
    }

    /// Remote ids the user pinned for this account. Pins are local-only and
    /// survive re-sync because they live in a separate table.
    public static func pinnedIds(
        forAccount accountId: UUID,
        db: LagoonDB
    ) async throws -> Set<String> {
        let sql = "SELECT remote_id FROM message_pins WHERE account_id = ?"
        return try db.read { db in
            let rows = try Row.fetchAll(db, sql: sql, arguments: [accountId])
            return Set(rows.compactMap { $0.optionalText("remote_id") })
        }
    }

    /// Every stored remote id for one account, regardless of read/archived
    /// state.
    ///
    /// Diagnostics only: a dry-run pull needs to know which of the rows a real
    /// round would return are *new* to the store, and that set difference is
    /// the whole measurement — it is what turns "the client shows 52" into
    /// "the mailbox has 265 and 213 were never fetched".
    public static func remoteIds(
        forAccount accountId: UUID,
        db: LagoonDB
    ) async throws -> Set<String> {
        let sql = "SELECT remote_id FROM message_headers WHERE account_id = ?"
        return try db.read { db in
            let rows = try Row.fetchAll(db, sql: sql, arguments: [accountId])
            return Set(rows.compactMap { $0.optionalText("remote_id") })
        }
    }

    /// Remote ids whose metadata carried a non-empty List-Unsubscribe
    /// header. Used to seed the heuristic classifier's subscription signal.
    public static func listUnsubscribeIds(
        forAccount accountId: UUID,
        db: LagoonDB
    ) async throws -> Set<String> {
        let sql = """
            SELECT remote_id FROM message_headers
            WHERE account_id = ? AND list_unsubscribe = TRUE
        """
        return try db.read { db in
            let rows = try Row.fetchAll(db, sql: sql, arguments: [accountId])
            return Set(rows.compactMap { $0.optionalText("remote_id") })
        }
    }

    /// Idempotent pin/unpin. `pinned == true` inserts (ignoring a duplicate);
    /// `false` deletes. Both are parameterized and safe to retry.
    public static func setPinned(
        _ pinned: Bool,
        remoteId: String,
        accountId: UUID,
        db: LagoonDB
    ) async throws {
        try db.write {
            try setPinnedSync(
                pinned, remoteId: remoteId, accountId: accountId, db: $0
            )
        }
    }

    /// Sync core for callers inside a transaction (the pin route composes the
    /// flip with the audit insert in one `pool.write` closure).
    public static func setPinnedSync(
        _ pinned: Bool,
        remoteId: String,
        accountId: UUID,
        db: Database
    ) throws {
        if pinned {
            try db.execute(
                sql: """
                    INSERT INTO message_pins (account_id, remote_id)
                    VALUES (?, ?)
                    ON CONFLICT (account_id, remote_id) DO NOTHING
                    """,
                arguments: [accountId, remoteId]
            )
        } else {
            try db.execute(
                sql: "DELETE FROM message_pins WHERE account_id = ? AND remote_id = ?",
                arguments: [accountId, remoteId]
            )
        }
    }

    /// Local half of an archive/unarchive. The remote move happens through the
    /// provider first; this only flips the row. Every caller is a
    /// user-triggered route: the sync loop has no path to this helper and no
    /// ability to archive at all (`MailSyncReading` has no such method).
    public static func setArchived(
        _ archived: Bool,
        remoteId: String,
        accountId: UUID,
        db: LagoonDB
    ) async throws {
        try db.write {
            try setArchivedSync(archived, remoteId: remoteId, accountId: accountId, db: $0)
        }
    }

    /// Sync core for callers inside a transaction (action routes compose the
    /// flag flip with the audit insert in one `pool.write` closure).
    public static func setArchivedSync(
        _ archived: Bool,
        remoteId: String,
        accountId: UUID,
        db: Database
    ) throws {
        try db.execute(
            sql: "UPDATE message_headers SET is_archived = ? WHERE remote_id = ? AND account_id = ?",
            arguments: [archived, remoteId, accountId]
        )
    }

    /// Total rows matching `recent()`'s filter (minus LIMIT): the archive
    /// cabinet badge and any future "N results" UI. Same WHERE clause as
    /// `recent()` by construction — both funnel through `filterSQL`.
    public static func count(
        forAccount accountId: UUID,
        sender: String? = nil,
        archived: Bool = false,
        deleted: Bool = false,
        sent: Bool = false,
        stackMatch: StackMatch? = nil,
        receivedAfter: Date? = nil,
        db: LagoonDB
    ) async throws -> Int {
        let (whereClause, arguments) = filterSQL(
            accountId: accountId, sender: sender, archived: archived, deleted: deleted,
            sent: sent, stackMatch: stackMatch, receivedAfter: receivedAfter
        )
        // Joined, not interpolated — see recent() above.
        let sql = [
            "SELECT COUNT(*) AS count FROM message_headers h",
            whereClause,
        ].joined(separator: " ")
        return try db.read { db in
            let row = try Row.fetchOne(db, sql: sql, arguments: StatementArguments(arguments))
            return row.map { $0["count"] } ?? 0
        }
    }

    public static func unreadCount(
        forAccount accountId: UUID,
        db: LagoonDB
    ) async throws -> Int {
        // `is_sent = FALSE` is the R1 addition, and it was found in the
        // round-end review rather than by a test: this query predates
        // `filterSQL` and hand-rolls its own predicate, so adding a third axis
        // to the shared clause did not reach it. Without it, a reply the user
        // sent but has not "read" would sit in the unread badge while being
        // invisible in every list the badge labels — the exact
        // number-does-not-match-its-list failure the whole axis system exists
        // to prevent.
        let sql = """
            SELECT COUNT(*) AS count FROM message_headers
            WHERE account_id = ? AND is_archived = FALSE
              AND is_deleted = FALSE AND is_sent = FALSE AND is_read = FALSE
        """
        return try db.read { db in
            let row = try Row.fetchOne(db, sql: sql, arguments: [accountId])
            return row.map { $0["count"] } ?? 0
        }
    }

    /// How many messages carry a pin, for the sidebar's 置顶 row.
    ///
    /// Counts the `message_pins` join rather than a flag on the header: pins
    /// live in their own table (see `LagoonDatabase`), and a pin on a message
    /// that has since been deleted still counts here while the sidebar's other
    /// rows do not. That inconsistency is deliberate — the pin list is the one
    /// place a user looks for "what did I deliberately keep", and a pin that
    /// vanished because a message was trashed would be a worse answer than a
    /// count that is not obviously comparable to its neighbours.
    public static func pinnedCount(
        forAccount accountId: UUID,
        db: LagoonDB
    ) async throws -> Int {
        // Joined rather than counted from `message_pins` alone, for the same
        // reason as `unreadCount`: a pin on a message that is now filed as sent
        // describes nothing the user can see in the 置顶 list.
        let sql = """
            SELECT COUNT(*) AS count FROM message_pins p
            JOIN message_headers h
              ON h.account_id = p.account_id AND h.remote_id = p.remote_id
            WHERE p.account_id = ? AND h.is_sent = FALSE
        """
        return try db.read { db in
            let row = try Row.fetchOne(db, sql: sql, arguments: [accountId])
            return row.map { $0["count"] } ?? 0
        }
    }

    /// How many messages sit in the server's Trash.
    ///
    /// The one count the sidebar shows for rows no list will display: deleted
    /// mail is reachable only through undo or the trash folder, so without this
    /// number a user who archived too eagerly has no way to learn that anything
    /// is recoverable.
    /// 已发送 的本地计数 (R1).
    ///
    /// Deliberately `is_deleted = FALSE` as well: a message the user trashed
    /// after sending it should leave the 已发送 badge, exactly as it leaves
    /// every other surface. A badge that counts trashed mail is a number the
    /// user cannot reconcile with the list it labels.
    ///
    /// A **lower bound**, by construction — the local table only learns about
    /// sent mail when 已发送 is opened (or a reply is sent from this machine).
    /// That is the honest answer; the alternative, a second cursor on the Sent
    /// folder, would be a reconciling sync over a folder the user can also
    /// write to from another client, which is the bug class this project has
    /// already paid for once.
    public static func sentCount(
        forAccount accountId: UUID,
        db: LagoonDB
    ) async throws -> Int {
        let sql = """
            SELECT COUNT(*) AS count FROM message_headers
            WHERE account_id = ? AND is_sent = TRUE AND is_deleted = FALSE
        """
        return try db.read { db in
            let row = try Row.fetchOne(db, sql: sql, arguments: [accountId])
            return row.map { $0["count"] } ?? 0
        }
    }

    public static func deletedCount(
        forAccount accountId: UUID,
        db: LagoonDB
    ) async throws -> Int {
        let sql = """
            SELECT COUNT(*) AS count FROM message_headers
            WHERE account_id = ? AND is_deleted = TRUE
        """
        return try db.read { db in
            let row = try Row.fetchOne(db, sql: sql, arguments: [accountId])
            return row.map { $0["count"] } ?? 0
        }
    }

    /// Senders ranked by how much mail they have written, for the 发件人排行
    /// panel.
    ///
    /// Groups in SQL rather than fetching headers and counting in Swift: a
    /// mailbox with 5000 messages would otherwise be pulled whole to produce 60
    /// rows, and this endpoint refreshes every time the panel opens.
    ///
    /// Two details the ranking depends on:
    ///
    /// * **Deleted rows are excluded.** A sender whose mail the user has already
    ///   thrown away is not still writing to this mailbox, and counting the
    ///   trashed mail would keep a newsletter at the top of the list forever.
    /// * **Archived rows are included.** Archived is where triage puts mail that
    ///   is finished with, not mail that does not exist — a newsletter archived
    ///   every week is exactly the row this panel exists to surface.
    /// * **Sent rows are excluded.** `is_sent` is the third axis (R1): once the
    ///   user opens 已发送 once, their own replies land in `message_headers`
    ///   with `from_address` = their own address. This panel answers "who is
    ///   writing to me", and a volume-first ordering would otherwise rank the
    ///   user as their own top sender. Same predicate as `unreadCount` and
    ///   `pinnedCount` — hand-rolled counts drift from the shared clause when a
    ///   new axis arrives, and this one had already drifted once.
    ///
    /// The display name is picked with `MAX(NULLIF(from_name,''))` rather than
    /// "the newest one": a sender whose display name changed should not make the
    /// row's label flicker between refreshes, and any non-empty name is more
    /// useful than none.
    public static func senderRanking(
        forAccount accountId: UUID,
        limit: Int,
        query: String? = nil,
        db: LagoonDB
    ) async throws -> [SenderSummary] {
        var sql = """
            SELECT from_address AS address,
                   MAX(NULLIF(from_name, '')) AS display_name,
                   COUNT(*) AS total,
                   SUM(CASE WHEN is_read = FALSE THEN 1 ELSE 0 END) AS unread,
                   MAX(received_at) AS latest_at
            FROM message_headers
            WHERE account_id = ? AND is_deleted = FALSE AND is_sent = FALSE
        """
        var arguments: [DatabaseValueConvertible?] = [accountId]
        if let query, !query.isEmpty {
            // LIKE specials are data, not wildcards — same escaping as `search`.
            sql += " AND (from_address LIKE ? ESCAPE '\\' OR IFNULL(from_name, '') LIKE ? ESCAPE '\\')"
            let pattern = likePattern(containing: query)
            arguments.append(pattern)
            arguments.append(pattern)
        }
        // Volume first, then recency: two senders with 50 messages each are
        // ordered by who wrote most recently, which is the one that matters when
        // the user is deciding what to file.
        sql += """
            GROUP BY from_address
            ORDER BY total DESC, latest_at DESC
            LIMIT ?
        """
        arguments.append(limit)

        return try db.read { db in
            try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments)).map { row in
                SenderSummary(
                    address: row["address"],
                    displayName: row["display_name"],
                    totalCount: row["total"],
                    unreadCount: row["unread"] ?? 0,
                    latestAt: Self.parseStoredDate(row["latest_at"])
                        ?? Date(timeIntervalSince1970: 0)
                )
            }
        }
    }

    /// Parses a `received_at`-shaped column back into a `Date`.
    ///
    /// Needed because the column is TEXT: GRDB decodes a Date only when it knows
    /// the declared column type, and an aggregate like `MAX(received_at)` is an
    /// expression with no declared type, so it arrives as a string.
    ///
    /// The fallback is epoch rather than a crash: a row with an unparseable date
    /// should rank last, not take the panel down with it.
    static func parseStoredDate(_ raw: String?) -> Date? {
        StoredDate.date(from: raw)
    }

    /// The oldest stored row's receive time, nil for an account with no rows.
    ///
    /// Diagnostics only: this is the lower edge of what the local cache
    /// covers, and the number that tells a "the list window is too small"
    /// report apart from a "the sync never reached back that far" one.
    public static func oldestReceivedAt(
        forAccount accountId: UUID,
        db: LagoonDB
    ) async throws -> Date? {
        let sql = """
            SELECT MIN(received_at) AS oldest FROM message_headers
            WHERE account_id = ? AND is_deleted = FALSE
        """
        return try db.read { db in
            // `received_at` is TEXT in GRDB's own Date encoding, so MIN()
            // returns a decodable string rather than a number.
            let oldest: Date? = try Row.fetchOne(db, sql: sql, arguments: [accountId])?["oldest"]
            return oldest
        }
    }

    /// 删除/恢复的本地旗标。远端先动（route 负责 trash/restore），这里只
    /// 记账；`is_archived` 不动——从废纸篓恢复的邮件回到它原来所在的面。
    public static func setDeleted(
        remoteId: String,
        accountId: UUID,
        deleted: Bool,
        db: LagoonDB
    ) async throws {
        try db.write {
            try setDeletedSync(remoteId: remoteId, accountId: accountId, deleted: deleted, db: $0)
        }
    }

    /// Sync core for callers inside a transaction (delete route composes the
    /// flag flip with the audit insert in one `pool.write` closure).
    public static func setDeletedSync(
        remoteId: String,
        accountId: UUID,
        deleted: Bool,
        db: Database
    ) throws {
        try db.execute(
            sql: "UPDATE message_headers SET is_deleted = ? WHERE remote_id = ? AND account_id = ?",
            arguments: [deleted, remoteId, accountId]
        )
    }

    /// 彻底删除：把一封邮件的本地痕迹全部抹掉。**不可撤销。**
    ///
    /// ## Why this is not just `DELETE FROM message_headers`
    ///
    /// Two different reasons, and conflating them is how a previous version of
    /// this comment got the facts backwards:
    ///
    /// 1. **FKs are ON.** `LagoonDatabase.open` sets
    ///    `configuration.foreignKeysEnabled = true`, so `ON DELETE CASCADE`
    ///    *does* fire — for the two tables whose FK points at
    ///    `message_headers` (`message_bodies`, `advice`). An earlier comment
    ///    here claimed this connection runs with `PRAGMA foreign_keys = OFF`,
    ///    verified "against the live database". That was a **`sqlite3` CLI
    ///    reading**: the CLI opens a *new* connection, and the pragma is
    ///    per-connection and defaults to OFF there, so it reports 0 no matter
    ///    what the app does. Measured on a GRDB pool built exactly like the
    ///    app's, `PRAGMA foreign_keys` is 1 and a parent delete does cascade.
    /// 2. **But three tables have no FK to `message_headers` at all.**
    ///    `message_pins`, `draft_replies` and `ai_overrides` reference
    ///    `accounts(id)`, so SQLite will never cascade them for a header
    ///    delete. Those genuinely do need explicit deletion.
    ///
    /// The explicit deletes below are therefore *redundant* for the two
    /// cascading tables and *load-bearing* for the three non-cascading ones.
    /// They are kept unconditionally: correctness does not depend on which
    /// pragma is set, and the orphan rows they prevent are not harmless — a
    /// body row with no header is a body the app can still read through a
    /// stale remoteId, and it is invisible to every count and every list.
    ///
    /// ## What is deliberately *not* deleted
    ///
    /// `ai_actions` is the audit log, and it is keyed by `actionId`, not by
    /// `remoteId` — the actions that archived and deleted this message stay, so
    /// the history still reads "Lagoon did these things, here is when". A user
    /// who permanently deletes a message should not thereby erase the record
    /// that Lagoon touched it, and the audit trail is the one place the product
    /// is required to be honest (constitution §3).
    ///
    /// This is the one irreversible operation in the product. It is reachable
    /// only from an explicit user gesture on a message already in the Trash,
    /// never from a rule, a sweep, or anything automatic.
    public static func hardDeleteSync(
        remoteId: String,
        accountId: UUID,
        db: Database
    ) throws {
        // Children first, and every table that references the header *by
        // remote_id* — whether or not SQLite would cascade it. `draft_replies`
        // and `ai_overrides` were missing here: both are actively written
        // (`AIActionStore` records a draft row and an override row per message),
        // both key on `(account_id, remote_id)`, and neither has an FK to
        // `message_headers`, so a purge used to leave them behind as orphans.
        // `PurgeRoutesTests` asserts on the non-cascading tables precisely so
        // that `ON DELETE CASCADE` cannot quietly pass the test for us.
        try db.execute(
            sql: "DELETE FROM message_pins WHERE account_id = ? AND remote_id = ?",
            arguments: [accountId, remoteId]
        )
        try db.execute(
            sql: "DELETE FROM draft_replies WHERE account_id = ? AND remote_id = ?",
            arguments: [accountId, remoteId]
        )
        try db.execute(
            sql: "DELETE FROM ai_overrides WHERE account_id = ? AND remote_id = ?",
            arguments: [accountId, remoteId]
        )
        try db.execute(
            sql: "DELETE FROM advice WHERE account_id = ? AND remote_id = ?",
            arguments: [accountId, remoteId]
        )
        try db.execute(
            sql: "DELETE FROM message_bodies WHERE account_id = ? AND remote_id = ?",
            arguments: [accountId, remoteId]
        )
        try db.execute(
            sql: "DELETE FROM message_headers WHERE account_id = ? AND remote_id = ?",
            arguments: [accountId, remoteId]
        )
    }

    /// Every remote id in the Trash, for 清空废纸篓.
    ///
    /// Read through the same filter the trash *list* uses, so "empty the trash"
    /// and "what the trash is showing" can never disagree — the same invariant
    /// `TrashListingTests` pins for the count and the rows.
    public static func trashedRemoteIds(
        forAccount accountId: UUID,
        db: LagoonDB
    ) async throws -> [String] {
        try db.read { raw in
            try String.fetchAll(
                raw,
                sql: """
                    SELECT remote_id FROM message_headers
                    WHERE account_id = ? AND is_deleted = TRUE
                    """,
                arguments: [accountId]
            )
        }
    }

    /// Just the remote ids matching a filter, newest first.
    ///
    /// ## Why this exists
    ///
    /// Gmail's two-stage select-all needs "everything matching", and the list the
    /// client holds is a **window** — the ids for the rows past the limit were
    /// never sent. Resolving the query server-side, through the *same*
    /// `filterSQL` the list uses, is what keeps "select all" and "what the list
    /// shows" from being two different definitions of the same set.
    ///
    /// The caller passes a `limit` and is expected to ask for `cap + 1` so it can
    /// tell "exactly cap" from "more than cap" and report the overflow instead
    /// of silently truncating.
    public static func remoteIds(
        forAccount accountId: UUID,
        sender: String?,
        archived: Bool,
        deleted: Bool,
        sent: Bool = false,
        stackMatch: StackMatch?,
        limit: Int,
        db: LagoonDB
    ) async throws -> [String] {
        let (whereClause, filterArgs) = filterSQL(
            accountId: accountId, sender: sender, archived: archived, deleted: deleted,
            sent: sent, stackMatch: stackMatch
        )
        let sql = [
            "SELECT h.remote_id FROM message_headers h",
            whereClause,
            "ORDER BY h.received_at DESC",
            "LIMIT \(max(1, limit))",
        ].joined(separator: " ")
        return try db.read { raw in
            try String.fetchAll(raw, sql: sql, arguments: StatementArguments(filterArgs))
        }
    }

    public static func decode(_ row: Row) throws -> MessageHeader {
        // `is_pinned` only exists on queries that join `message_pins`
        // (`recent`); `find` does not, and GRDB answers nil for a missing
        // column, so a default is correct rather than a cast that throws.
        let isPinned: Bool? = row["is_pinned"]
        // `is_sent` is read with the same nil-tolerant dance: queries that
        // predate the R1 column, and the `is_sent` partial index means a query
        // filtered on it may not select it. Defaulting to false keeps the
        // client from ever seeing a sent mail as received.
        let isSent: Bool? = row["is_sent"]
        return MessageHeader(
            id: row["id"],
            accountId: row["account_id"],
            remoteId: row["remote_id"],
            threadId: row["thread_id"],
            fromAddress: row["from_address"],
            fromName: row.optionalText("from_name"),
            subject: row.optionalText("subject"),
            snippet: row.optionalText("snippet"),
            receivedAt: row["received_at"],
            isRead: row["is_read"],
            isArchived: row["is_archived"],
            isDeleted: row["is_deleted"],
            isPinned: isPinned ?? false,
            isSent: isSent ?? false,
            messageIdHeader: row.optionalText("message_id_header"),
            inReplyTo: row.optionalText("in_reply_to"),
            references: row.optionalText("references_header")
        )
    }
}

extension Row {
    /// The stored JSON array of unsubscribe links, or nil when unparseable.
    fileprivate func decodedLinks() -> [String]? {
        guard let text: String = self["unsubscribe_links"],
              let data = text.data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode([String].self, from: data)
    }
}
