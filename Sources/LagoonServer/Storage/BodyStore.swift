import Foundation
import GRDB
import LagoonKit

/// Durable write-through store for parsed message bodies (V2 A3).
///
/// Bodies are immutable, so a stored row is never stale — the foreign key
/// into `message_headers` deletes it when reconciliation expunges the header.
/// The route reads here first and only hits the provider on a miss, which
/// makes re-opens free and offline-adjacent (whatever was opened once is
/// served without network).
public enum BodyStore {
    public static func get(
        accountId: UUID,
        remoteId: String,
        db: LagoonDB
    ) async throws -> FetchedBody? {
        let sql = """
            SELECT body_text, body_html, has_more, attachments, to_addresses, cc_addresses
            FROM message_bodies
            WHERE account_id = ? AND remote_id = ?
        """
        return try db.read { db in
            guard let row = try Row.fetchOne(db, sql: sql, arguments: [accountId, remoteId]) else {
                return nil
            }
            let text: String = row["body_text"]
            let html: String? = row["body_html"]
            let hasMore: Bool = row["has_more"]
            let attachments = row.decodedJSON("attachments", as: [Attachment].self, decoder: JSONDecoder()) ?? []
            return FetchedBody(
                text: text,
                html: html,
                attachments: attachments.map {
                    FetchedAttachment(
                        id: $0.id,
                        filename: $0.filename,
                        mimeType: $0.mimeType,
                        size: $0.size,
                        contentId: $0.contentId,
                        disposition: $0.disposition,
                        data: Data()
                    )
                },
                hasMore: hasMore,
                // Recipients live in the row too (migration 017): without them a
                // store hit answered `to: [], cc: []`, which silently degraded
                // reply-all to reply-to-sender on every re-open.
                to: row.decodedStringArray("to_addresses"),
                cc: row.decodedStringArray("cc_addresses")
            )
        }
    }

    /// Insert or replace. The header row must exist (foreign key); callers
    /// fetch the header first, so a missing header means the message is gone.
    public static func put(
        accountId: UUID,
        remoteId: String,
        body: FetchedBody,
        db: LagoonDB
    ) async throws {
        let sql = """
            INSERT INTO message_bodies
                (account_id, remote_id, body_text, body_html, has_more, attachments,
                 to_addresses, cc_addresses, fetched_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, strftime('%Y-%m-%d %H:%M:%f','now'))
            ON CONFLICT (account_id, remote_id) DO UPDATE SET
                body_text = EXCLUDED.body_text,
                body_html = EXCLUDED.body_html,
                has_more = EXCLUDED.has_more,
                attachments = EXCLUDED.attachments,
                to_addresses = EXCLUDED.to_addresses,
                cc_addresses = EXCLUDED.cc_addresses,
                fetched_at = strftime('%Y-%m-%d %H:%M:%f','now')
        """
        try db.write {
            try $0.execute(sql: sql, arguments: [
                accountId,
                remoteId,
                body.text,
                body.html,
                body.hasMore,
                Self.json(body.attachments.map { $0.toWire() }),
                Self.json(body.to),
                Self.json(body.cc),
            ])
        }
    }

    /// Drop a stale row (provider reports the message gone).
    public static func delete(
        accountId: UUID,
        remoteId: String,
        db: LagoonDB
    ) async throws {
        try db.write {
            try $0.execute(
                sql: "DELETE FROM message_bodies WHERE account_id = ? AND remote_id = ?",
                arguments: [accountId, remoteId]
            )
        }
    }

    private static func json<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }
}

extension Row {
    /// A TEXT column holding a JSON string array; [] when unparseable.
    func decodedStringArray(_ column: String) -> [String] {
        guard let text: String = self[column], let data = text.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }
}
