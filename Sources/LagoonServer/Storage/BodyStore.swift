import Foundation
import PostgresNIO
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
        db: PostgresConnection
    ) async throws -> FetchedBody? {
        let sql = """
            SELECT body_text, body_html, has_more, attachments, to_addresses, cc_addresses
            FROM message_bodies
            WHERE account_id = $1 AND remote_id = $2
        """
        let rows = try await db.query(sql, [
            PostgresData(uuid: accountId),
            PostgresData(string: remoteId),
        ]).get()
        guard let row = rows.rows.first else { return nil }
        let r = row.makeRandomAccess()
        let text: String = try r["body_text"].decode(String.self)
        let html: String? = try r["body_html"].decode(String?.self)
        let hasMore: Bool = try r["has_more"].decode(Bool.self)
        let attachments = decodeAttachments(r[data: "attachments"].jsonb) ?? []
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
            to: decodeAddresses(r, "to_addresses"),
            cc: decodeAddresses(r, "cc_addresses")
        )
    }

    /// Insert or replace. The header row must exist (foreign key); callers
    /// fetch the header first, so a missing header means the message is gone.
    public static func put(
        accountId: UUID,
        remoteId: String,
        body: FetchedBody,
        db: PostgresConnection
    ) async throws {
        let sql = """
            INSERT INTO message_bodies
                (account_id, remote_id, body_text, body_html, has_more, attachments,
                 to_addresses, cc_addresses, fetched_at)
            VALUES ($1, $2, $3, $4, $5, $6::jsonb,
                    ARRAY(SELECT jsonb_array_elements_text($7::jsonb)),
                    ARRAY(SELECT jsonb_array_elements_text($8::jsonb)),
                    now())
            ON CONFLICT (account_id, remote_id) DO UPDATE SET
                body_text = EXCLUDED.body_text,
                body_html = EXCLUDED.body_html,
                has_more = EXCLUDED.has_more,
                attachments = EXCLUDED.attachments,
                to_addresses = EXCLUDED.to_addresses,
                cc_addresses = EXCLUDED.cc_addresses,
                fetched_at = now()
        """
        try await db.query(sql, [
            PostgresData(uuid: accountId),
            PostgresData(string: remoteId),
            PostgresData(string: body.text),
            body.html.map { PostgresData(string: $0) } ?? .null,
            PostgresData(bool: body.hasMore),
            PostgresData(jsonb: try encode(body.attachments.map { $0.toWire() })),
            PostgresData(jsonb: try encode(body.to)),
            PostgresData(jsonb: try encode(body.cc)),
        ]).get()
    }

    /// Drop a stale row (provider reports the message gone).
    public static func delete(
        accountId: UUID,
        remoteId: String,
        db: PostgresConnection
    ) async throws {
        try await db.query(
            "DELETE FROM message_bodies WHERE account_id = $1 AND remote_id = $2",
            [PostgresData(uuid: accountId), PostgresData(string: remoteId)]
        ).get()
    }

    private static func decodeAddresses(_ row: PostgresRandomAccessRow, _ column: String) -> [String] {
        (try? row[column].decode([String].self)) ?? []
    }

    private static func decodeAttachments(_ data: Data?) -> [Attachment]? {
        guard let data else { return nil }
        return try? JSONDecoder().decode([Attachment].self, from: data)
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }
}
