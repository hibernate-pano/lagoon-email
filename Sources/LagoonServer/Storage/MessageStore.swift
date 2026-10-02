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
    /// - `stackMatch` narrows to one 聚合规则.
    /// Deleted rows never appear in either view — they live in the server's
    /// Trash folder and are reachable only through undo/restore.
    ///
    /// The pin join is what lets the client render pin state: pins live in
    /// their own table, so a plain `message_headers` read leaves the client
    /// with no way to tell a pinned mail from an unpinned one.
    /// Shared WHERE clause for `recent()` and `count()` so the badge
    /// total can never drift from the list it labels. Returns the clause
    /// (starting at WHERE) plus its bound arguments in order.
    static func filterSQL(
        accountId: UUID,
        sender: String?,
        archived: Bool,
        stackMatch: StackMatch?
    ) -> (String, [DatabaseValueConvertible?]) {
        var clause = "WHERE h.account_id = ? AND h.is_deleted = FALSE AND h.is_archived = "
        clause += archived ? "TRUE" : "FALSE"
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
        return (clause, arguments)
    }

    public static func recent(
        forAccount accountId: UUID,
        limit: Int,
        sender: String? = nil,
        archived: Bool = false,
        stackMatch: StackMatch? = nil,
        db: LagoonDB
    ) async throws -> [MessageHeader] {
        let (whereClause, filterArgs) = filterSQL(
            accountId: accountId, sender: sender, archived: archived, stackMatch: stackMatch
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
                   h.received_at, h.is_read, h.is_archived, h.is_deleted,
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
                   received_at, is_read, is_archived, is_deleted,
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
                    WHERE account_id = ? AND is_archived = FALSE AND is_deleted = FALSE
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
        _ = try await setReadCapturing(
            remoteId: remoteId, accountId: accountId, isRead: isRead, db: db
        )
    }

    /// Same write, but returns the value it replaced (nil when the row does
    /// not exist, in which case the UPDATE matched nothing).
    ///
    /// Undoing a read-state change has to restore the *previous* value, not
    /// always flip to unread: marking a read mail as unread is a first-class
    /// action in this app, and its inverse is "read again". The read route
    /// needs the old value inside the same transaction as the audit row, so
    /// this is the sync core and `setRead` is the convenience wrapper.
    public static func setReadCapturing(
        remoteId: String,
        accountId: UUID,
        isRead: Bool,
        db: LagoonDB
    ) async throws -> Bool? {
        try db.write {
            try setReadSync(
                remoteId: remoteId, accountId: accountId, isRead: isRead, db: $0
            )
        }
    }

    /// Sync core for callers inside a transaction (the read route composes the
    /// flag flip with the audit insert in one `pool.write` closure).
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
    /// provider first; this only flips the row. The sync loop's whitelist
    /// autopilot (spec 2026-09-19 §3) uses the same helper as the routes.
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
        stackMatch: StackMatch? = nil,
        db: LagoonDB
    ) async throws -> Int {
        let (whereClause, arguments) = filterSQL(
            accountId: accountId, sender: sender, archived: archived, stackMatch: stackMatch
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
        let sql = """
            SELECT COUNT(*) AS count FROM message_headers
            WHERE account_id = ? AND is_archived = FALSE AND is_deleted = FALSE AND is_read = FALSE
        """
        return try db.read { db in
            let row = try Row.fetchOne(db, sql: sql, arguments: [accountId])
            return row.map { $0["count"] } ?? 0
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

    public static func decode(_ row: Row) throws -> MessageHeader {
        // `is_pinned` only exists on queries that join `message_pins`
        // (`recent`); `find` does not, and GRDB answers nil for a missing
        // column, so a default is correct rather than a cast that throws.
        let isPinned: Bool? = row["is_pinned"]
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
