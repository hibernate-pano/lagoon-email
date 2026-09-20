import Foundation
import PostgresNIO
import LagoonKit

public enum MessageStore {
    // Every query uses $N placeholders — no SQL is ever concatenated. The
    // SELECT column list is repeated literally per query (the CI guardrail
    // forbids interpolation inside SQL literals, even for constants).

    /// Upsert a polled header row. `listUnsubscribe` is the presence of the
    /// `List-Unsubscribe` header on the metadata response; it feeds the
    /// heuristic briefing classifier. Defaults to false so existing call sites
    /// (and tests) are unaffected.
    public static func upsert(
        _ m: MessageHeader,
        listUnsubscribe: Bool = false,
        db: PostgresConnection
    ) async throws {
        let sql = """
            INSERT INTO message_headers (
                id, account_id, remote_id, thread_id,
                from_address, from_name, subject, snippet,
                received_at, is_read, is_archived, list_unsubscribe,
                message_id_header, in_reply_to, references_header, fetched_at
            ) VALUES (
                $1, $2, $3, $4,
                $5, $6, $7, $8,
                $9, $10, $11, $12,
                $13, $14, $15, now()
            )
            ON CONFLICT (account_id, remote_id) DO UPDATE SET
                subject = EXCLUDED.subject,
                snippet = EXCLUDED.snippet,
                is_read = message_headers.is_read OR EXCLUDED.is_read,
                list_unsubscribe = message_headers.list_unsubscribe OR EXCLUDED.list_unsubscribe,
                message_id_header = COALESCE(EXCLUDED.message_id_header, message_headers.message_id_header),
                in_reply_to = COALESCE(EXCLUDED.in_reply_to, message_headers.in_reply_to),
                references_header = COALESCE(EXCLUDED.references_header, message_headers.references_header),
                fetched_at = now()
        """
        try await db.query(sql, [
            PostgresData(uuid: m.id),
            PostgresData(uuid: m.accountId),
            PostgresData(string: m.remoteId),
            PostgresData(string: m.threadId),
            PostgresData(string: m.fromAddress),
            m.fromName.map { PostgresData(string: $0) } ?? PostgresData(string: ""),
            m.subject.map { PostgresData(string: $0) } ?? PostgresData(string: ""),
            m.snippet.map { PostgresData(string: $0) } ?? PostgresData(string: ""),
            PostgresData(date: m.receivedAt),
            PostgresData(bool: m.isRead),
            PostgresData(bool: m.isArchived),
            PostgresData(bool: listUnsubscribe),
            m.messageIdHeader.map { PostgresData(string: $0) } ?? .null,
            m.inReplyTo.map { PostgresData(string: $0) } ?? .null,
            m.references.map { PostgresData(string: $0) } ?? .null
        ]).get()
    }

    public static func recent(
        forAccount accountId: UUID,
        limit: Int,
        db: PostgresConnection
    ) async throws -> [MessageHeader] {
        let sql = """
            SELECT id, account_id, remote_id, thread_id, from_address,
                   NULLIF(from_name, '') AS from_name,
                   NULLIF(subject, '') AS subject,
                   NULLIF(snippet, '') AS snippet,
                   received_at, is_read, is_archived,
                   message_id_header, in_reply_to, references_header
            FROM message_headers
            WHERE account_id = $1 AND is_archived = FALSE
            ORDER BY received_at DESC
            LIMIT $2
        """
        let rows = try await db.query(sql, [
            PostgresData(uuid: accountId),
            PostgresData(int: limit)
        ]).get()
        return try rows.map { try Self.decode($0) }
    }

    /// Single header by provider-native id (UIDVALIDITY-reset-safe: UIDs are
    /// only unique within an account, never globally).
    public static func find(
        remoteId: String,
        accountId: UUID,
        db: PostgresConnection
    ) async throws -> MessageHeader? {
        let sql = """
            SELECT id, account_id, remote_id, thread_id, from_address,
                   NULLIF(from_name, '') AS from_name,
                   NULLIF(subject, '') AS subject,
                   NULLIF(snippet, '') AS snippet,
                   received_at, is_read, is_archived,
                   message_id_header, in_reply_to, references_header
            FROM message_headers
            WHERE account_id = $1 AND remote_id = $2
            LIMIT 1
        """
        let rows = try await db.query(sql, [
            PostgresData(uuid: accountId),
            PostgresData(string: remoteId)
        ]).get()
        return try rows.first.map { try Self.decode($0) }
    }

    /// Wipes every header for an account (UIDVALIDITY change → full resync).
    /// Pins/drafts live in their own tables and are intentionally preserved.
    public static func deleteAll(accountId: UUID, db: PostgresConnection) async throws {
        let sql = "DELETE FROM message_headers WHERE account_id = $1"
        try await db.query(sql, [PostgresData(uuid: accountId)]).get()
    }

    /// Remove non-archived rows that no longer exist in the provider's inbox.
    /// Archived rows are retained because they represent messages Lagoon moved
    /// out of the inbox intentionally and may still need local history/undo.
    public static func reconcileInbox(
        accountId: UUID,
        keeping remoteIds: Set<String>,
        db: PostgresConnection
    ) async throws {
        let rows = try await db.query(
            """
            SELECT remote_id
            FROM message_headers
            WHERE account_id = $1 AND is_archived = FALSE
            """,
            [PostgresData(uuid: accountId)]
        ).get()
        let localIds = try rows.map {
            try $0.makeRandomAccess()["remote_id"].decode(String.self)
        }
        for remoteId in localIds where !remoteIds.contains(remoteId) {
            try await db.query(
                "DELETE FROM message_headers WHERE account_id = $1 AND remote_id = $2",
                [
                    PostgresData(uuid: accountId),
                    PostgresData(string: remoteId),
                ]
            ).get()
        }
    }

    public static func markRead(
        remoteId: String,
        accountId: UUID,
        db: PostgresConnection
    ) async throws {
        let sql = """
            UPDATE message_headers SET is_read = TRUE
            WHERE remote_id = $1 AND account_id = $2
        """
        try await db.query(sql, [
            PostgresData(string: remoteId),
            PostgresData(uuid: accountId)
        ]).get()
    }

    /// Gmail ids the user pinned for this account. Pins are local-only and
    /// survive re-sync because they live in a separate table.
    public static func pinnedIds(
        forAccount accountId: UUID,
        db: PostgresConnection
    ) async throws -> Set<String> {
        let sql = "SELECT remote_id FROM message_pins WHERE account_id = $1"
        let rows = try await db.query(sql, [PostgresData(uuid: accountId)]).get()
        let ids = try rows.map { row -> String in
            try row.makeRandomAccess()["remote_id"].decode(String.self)
        }
        return Set(ids)
    }

    /// Gmail ids whose metadata response carried a non-empty List-Unsubscribe
    /// header. Used to seed the heuristic classifier's subscription signal.
    public static func listUnsubscribeIds(
        forAccount accountId: UUID,
        db: PostgresConnection
    ) async throws -> Set<String> {
        let sql = """
            SELECT remote_id FROM message_headers
            WHERE account_id = $1 AND list_unsubscribe = TRUE
        """
        let rows = try await db.query(sql, [PostgresData(uuid: accountId)]).get()
        let ids = try rows.map { row -> String in
            try row.makeRandomAccess()["remote_id"].decode(String.self)
        }
        return Set(ids)
    }

    /// Idempotent pin/unpin. `pinned == true` inserts (ignoring a duplicate);
    /// `false` deletes. Both are parameterized and safe to retry.
    public static func setPinned(
        _ pinned: Bool,
        remoteId: String,
        accountId: UUID,
        db: PostgresConnection
    ) async throws {
        if pinned {
            let sql = """
                INSERT INTO message_pins (account_id, remote_id)
                VALUES ($1, $2)
                ON CONFLICT (account_id, remote_id) DO NOTHING
            """
            try await db.query(sql, [
                PostgresData(uuid: accountId),
                PostgresData(string: remoteId)
            ]).get()
        } else {
            let sql = "DELETE FROM message_pins WHERE account_id = $1 AND remote_id = $2"
            try await db.query(sql, [
                PostgresData(uuid: accountId),
                PostgresData(string: remoteId)
            ]).get()
        }
    }

    /// Local half of an archive/unarchive. The remote move happens through the
    /// provider first; this only flips the row. The sync loop's whitelist
    /// autopilot (spec 2026-09-19 §3) uses the same helper as the routes.
    public static func setArchived(
        _ archived: Bool,
        remoteId: String,
        accountId: UUID,
        db: PostgresConnection
    ) async throws {
        try await db.query(
            "UPDATE message_headers SET is_archived = $3 WHERE remote_id = $1 AND account_id = $2",
            [
                PostgresData(string: remoteId),
                PostgresData(uuid: accountId),
                PostgresData(bool: archived),
            ]
        ).get()
    }

    public static func unreadCount(
        forAccount accountId: UUID,
        db: PostgresConnection
    ) async throws -> Int {
        let sql = """
            SELECT COUNT(*) FROM message_headers
            WHERE account_id = $1 AND is_archived = FALSE AND is_read = FALSE
        """
        let result = try await db.query(sql, [PostgresData(uuid: accountId)]).get()
        guard let row = result.rows.first else { return 0 }
        return try row.makeRandomAccess()["count"].decode(Int.self)
    }

    public static func decode(_ row: PostgresNIO.PostgresRow) throws -> MessageHeader {
        let r = row.makeRandomAccess()
        let id: UUID = try r["id"].decode(UUID.self)
        let accountId: UUID = try r["account_id"].decode(UUID.self)
        let remoteId: String = try r["remote_id"].decode(String.self)
        let threadId: String = try r["thread_id"].decode(String.self)
        let fromAddress: String = try r["from_address"].decode(String.self)
        let fromName: String? = (try? r["from_name"].decode(String.self)).flatMap { $0.isEmpty ? nil : $0 }
        let subject: String? = (try? r["subject"].decode(String.self)).flatMap { $0.isEmpty ? nil : $0 }
        let snippet: String? = (try? r["snippet"].decode(String.self)).flatMap { $0.isEmpty ? nil : $0 }
        let receivedAt: Date = try r["received_at"].decode(Date.self)
        let isRead: Bool = try r["is_read"].decode(Bool.self)
        let isArchived: Bool = try r["is_archived"].decode(Bool.self)
        let messageIdHeader: String? = (try? r["message_id_header"].decode(String.self)).flatMap { $0.isEmpty ? nil : $0 }
        let inReplyTo: String? = (try? r["in_reply_to"].decode(String.self)).flatMap { $0.isEmpty ? nil : $0 }
        let references: String? = (try? r["references_header"].decode(String.self)).flatMap { $0.isEmpty ? nil : $0 }
        return MessageHeader(
            id: id,
            accountId: accountId,
            remoteId: remoteId,
            threadId: threadId,
            fromAddress: fromAddress,
            fromName: fromName,
            subject: subject,
            snippet: snippet,
            receivedAt: receivedAt,
            isRead: isRead,
            isArchived: isArchived,
            messageIdHeader: messageIdHeader,
            inReplyTo: inReplyTo,
            references: references
        )
    }
}
