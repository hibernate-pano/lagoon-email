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
    public static func upsert(
        _ m: MessageHeader,
        listUnsubscribe: Bool = false,
        unsubscribeLinks: [String] = [],
        db: LagoonDB
    ) async throws {
        let linksJSON = try Self.linksJSON(unsubscribeLinks)
        try db.write { db in
            // The Postgres upsert merged `existing || new` with first
            // occurrence wins in SQL. SQLite has no array type, so the merge
            // happens here inside the write transaction: read what's stored,
            // merge, write. Repeated syncs cannot grow the array.
            let existing = try Row.fetchOne(
                db,
                sql: "SELECT unsubscribe_links FROM message_headers WHERE account_id = ? AND remote_id = ?",
                arguments: [m.accountId, m.remoteId]
            ).flatMap { $0.decodedLinks() } ?? []
            let merged = try Self.linksJSON(Self.mergeLinks(existing + unsubscribeLinks))
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
                    subject = EXCLUDED.subject,
                    snippet = EXCLUDED.snippet,
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
                linksJSON
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
    public static func recent(
        forAccount accountId: UUID,
        limit: Int,
        sender: String? = nil,
        archived: Bool = false,
        stackMatch: StackMatch? = nil,
        db: LagoonDB
    ) async throws -> [MessageHeader] {
        var sql = """
            SELECT id, account_id, remote_id, thread_id, from_address,
                   NULLIF(from_name, '') AS from_name,
                   NULLIF(subject, '') AS subject,
                   NULLIF(snippet, '') AS snippet,
                   received_at, is_read, is_archived, is_deleted,
                   message_id_header, in_reply_to, references_header
            FROM message_headers
            WHERE account_id = ? AND is_deleted = FALSE AND is_archived =
        """
        sql += archived ? " TRUE" : " FALSE"
        var arguments: [DatabaseValueConvertible?] = [accountId]
        switch stackMatch {
        case .sender(let address):
            sql += "\n            AND from_address = ?"
            arguments.append(address)
        case .keyword(let value):
            sql += "\n            AND subject LIKE ? ESCAPE '\\'"
            arguments.append(likePattern(containing: value))
        case nil:
            break
        }
        if sender != nil {
            sql += "\n            AND from_address = ?"
            arguments.append(sender)
        }
        sql += "\n            ORDER BY received_at DESC\n            LIMIT ?"
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
        let sql = """
            UPDATE message_headers SET is_read = TRUE
            WHERE remote_id = ? AND account_id = ?
        """
        try db.write {
            try $0.execute(sql: sql, arguments: [remoteId, accountId])
        }
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
        if pinned {
            let sql = """
                INSERT INTO message_pins (account_id, remote_id)
                VALUES (?, ?)
                ON CONFLICT (account_id, remote_id) DO NOTHING
            """
            try db.write {
                try $0.execute(sql: sql, arguments: [accountId, remoteId])
            }
        } else {
            let sql = "DELETE FROM message_pins WHERE account_id = ? AND remote_id = ?"
            try db.write {
                try $0.execute(sql: sql, arguments: [accountId, remoteId])
            }
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
        MessageHeader(
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
