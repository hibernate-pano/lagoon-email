import Foundation
import PostgresNIO
import LagoonKit

/// Postgres-backed audit log for `ai_actions`. Append-only.
public enum AIActionStore {
    public static func record(
        accountId: UUID,
        kind: AIActionKind,
        payload: [String: String],
        db: PostgresConnection
    ) async throws -> AIAction {
        let payloadJSON = try Self.encode(payload)
        let sql = """
            INSERT INTO ai_actions (account_id, kind, payload)
            VALUES ($1, $2, $3::jsonb)
            RETURNING id, account_id, kind, payload, created_at, expires_at
        """
        let rows = try await db.query(sql, [
            PostgresData(uuid: accountId),
            PostgresData(string: kind.rawValue),
            PostgresData(jsonb: payloadJSON),
        ]).get()
        return try Self.decode(rows.rows.first!)
    }

    public static func recent(
        accountId: UUID,
        since: Date? = nil,
        limit: Int = 50,
        db: PostgresConnection
    ) async throws -> [AIAction] {
        let sql: String
        let params: [PostgresData]
        if let since {
            sql = "SELECT id, account_id, kind, payload, created_at, expires_at FROM ai_actions WHERE account_id = $1 AND created_at >= $2 ORDER BY created_at DESC LIMIT $3"
            params = [PostgresData(uuid: accountId), PostgresData(date: since), PostgresData(int: limit)]
        } else {
            sql = "SELECT id, account_id, kind, payload, created_at, expires_at FROM ai_actions WHERE account_id = $1 ORDER BY created_at DESC LIMIT $2"
            params = [PostgresData(uuid: accountId), PostgresData(int: limit)]
        }
        let rows = try await db.query(sql, params).get()
        return try rows.map { try Self.decode($0) }
    }

    public static func find(id: Int64, db: PostgresConnection) async throws -> AIAction? {
        let rows = try await db.query(
            "SELECT id, account_id, kind, payload, created_at, expires_at FROM ai_actions WHERE id = $1",
            [PostgresData(int64: id)]
        ).get()
        return try rows.rows.first.map { try Self.decode($0) }
    }

    /// Looks up a previously completed send by the client's idempotency key.
    public static func findSend(
        accountId: UUID,
        requestId: String,
        db: PostgresConnection
    ) async throws -> AIAction? {
        let rows = try await db.query(
            """
            SELECT id, account_id, kind, payload, created_at, expires_at
            FROM ai_actions
            WHERE account_id = $1 AND kind = 'send' AND payload->>'requestId' = $2
            LIMIT 1
            """,
            [
                PostgresData(uuid: accountId),
                PostgresData(string: requestId),
            ]
        ).get()
        return try rows.rows.first.map { try Self.decode($0) }
    }

    /// remoteIds Lagoon actually sent a reply to. The reply route records the
    /// *original* message's remoteId in the send action's payload, so this is
    /// the authoritative "already replied" signal for the briefing classifier.
    /// Replies sent from other mail clients are invisible here — the Sent
    /// folder is never synced (known limitation, spec 2026-09-19 §2).
    public static func repliedRemoteIds(
        accountId: UUID,
        db: PostgresConnection
    ) async throws -> Set<String> {
        let sql = """
            SELECT DISTINCT payload->>'remoteId' AS rid
            FROM ai_actions
            WHERE account_id = $1 AND kind = 'send' AND payload ? 'remoteId'
        """
        let rows = try await db.query(sql, [PostgresData(uuid: accountId)]).get()
        let ids = try rows.map { row -> String in
            try row.makeRandomAccess()["rid"].decode(String.self)
        }
        return Set(ids)
    }

    /// Audited (kind, createdAt) events for the time-saved report, with
    /// actions that were later undone excluded — an undone archive is not a
    /// handled message. `since` bounds the query; the caller aggregates.
    public static func timeSavedEvents(
        accountId: UUID,
        since: Date,
        db: PostgresConnection
    ) async throws -> [(kind: AIActionKind, createdAt: Date)] {
        let sql = """
            SELECT a.kind, a.created_at
            FROM ai_actions a
            WHERE a.account_id = $1 AND a.created_at >= $2
              AND NOT EXISTS (
                  SELECT 1 FROM ai_actions u
                  WHERE u.account_id = a.account_id AND u.kind = 'undo'
                    AND u.payload->>'undoOf' = a.id::text
              )
        """
        let rows = try await db.query(sql, [
            PostgresData(uuid: accountId),
            PostgresData(date: since),
        ]).get()
        return try rows.map { row in
            let r = row.makeRandomAccess()
            let kindStr: String = try r["kind"].decode(String.self)
            let createdAt: Date = try r["created_at"].decode(Date.self)
            return (kind: AIActionKind(rawValue: kindStr) ?? .archive, createdAt: createdAt)
        }
    }

    /// Per-(account, sender) override lookup used by the heuristic classifier.
    public static func overridesBySender(
        accountId: UUID,
        db: PostgresConnection
    ) async throws -> [String: BriefingGroup] {
        let sql = """
            WITH ranked AS (
                SELECT o.to_group, m.from_address, o.created_at,
                    row_number() OVER (PARTITION BY m.from_address ORDER BY o.created_at DESC) AS rn
                FROM ai_overrides o
                JOIN message_headers m ON m.remote_id = o.remote_id AND m.account_id = o.account_id
                WHERE o.account_id = $1
            )
            SELECT from_address, to_group FROM ranked WHERE rn = 1
        """
        let rows = try await db.query(sql, [PostgresData(uuid: accountId)]).get()
        var result: [String: BriefingGroup] = [:]
        for row in rows {
            let r = row.makeRandomAccess()
            let addr: String = try r["from_address"].decode(String.self)
            let groupStr: String = try r["to_group"].decode(String.self)
            if let group = BriefingGroup(rawValue: groupStr) {
                result[addr] = group
            }
        }
        return result
    }

    public static func insertOverride(
        accountId: UUID,
        remoteId: String,
        fromGroup: BriefingGroup,
        toGroup: BriefingGroup,
        db: PostgresConnection
    ) async throws {
        try await db.query(
            "INSERT INTO ai_overrides (account_id, remote_id, from_group, to_group) VALUES ($1, $2, $3, $4)",
            [
                PostgresData(uuid: accountId),
                PostgresData(string: remoteId),
                PostgresData(string: fromGroup.rawValue),
                PostgresData(string: toGroup.rawValue),
            ]
        ).get()
    }

    public static func decode(_ row: PostgresNIO.PostgresRow) throws -> AIAction {
        let r = row.makeRandomAccess()
        let id: Int64 = try r["id"].decode(Int64.self)
        let accId: UUID = try r["account_id"].decode(UUID.self)
        let kindStr: String = try r["kind"].decode(String.self)
        let payloadStr: String = try r["payload"].decode(String.self)
        let createdAt: Date = try r["created_at"].decode(Date.self)
        let expiresAt: Date? = try r["expires_at"].decode(Date?.self)
        return AIAction(
            id: id,
            accountId: accId,
            kind: AIActionKind(rawValue: kindStr) ?? .archive,
            payload: try Self.decodePayload(payloadStr),
            createdAt: createdAt,
            expiresAt: expiresAt
        )
    }

    /// Returns bytes, not a String: `PostgresData(jsonb:)` has an `Encodable`
    /// overload that would JSON-encode a String a second time, storing the
    /// payload as a JSON string instead of an object.
    private static func encode(_ payload: [String: String]) throws -> Data {
        try JSONSerialization.data(withJSONObject: payload)
    }

    private static func decodePayload(_ json: String) throws -> [String: String] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any]
        else { return [:] }
        return dict.compactMapValues { ($0 as? String) ?? ($0 as? NSNumber).map { "\($0)" } }
    }
}

/// Postgres-backed draft replies.
public enum DraftReplyStore {
    public static func create(
        accountId: UUID,
        remoteId: String,
        variants: [String],
        db: PostgresConnection
    ) async throws -> DraftReply {
        let json = try JSONSerialization.data(withJSONObject: variants)
        let rows = try await db.query(
            """
            INSERT INTO draft_replies (account_id, remote_id, variants)
            VALUES ($1, $2, $3::jsonb)
            RETURNING id, account_id, remote_id, variants, chosen_variant, created_at
            """,
            [
                PostgresData(uuid: accountId),
                PostgresData(string: remoteId),
                PostgresData(jsonb: json),
            ]
        ).get()
        return try Self.decode(rows.rows.first!)
    }

    public static func list(
        accountId: UUID,
        remoteId: String? = nil,
        db: PostgresConnection
    ) async throws -> [DraftReply] {
        let sql: String
        let params: [PostgresData]
        if let remoteId {
            sql = "SELECT id, account_id, remote_id, variants, chosen_variant, created_at FROM draft_replies WHERE account_id = $1 AND remote_id = $2 ORDER BY created_at DESC"
            params = [PostgresData(uuid: accountId), PostgresData(string: remoteId)]
        } else {
            sql = "SELECT id, account_id, remote_id, variants, chosen_variant, created_at FROM draft_replies WHERE account_id = $1 ORDER BY created_at DESC LIMIT 50"
            params = [PostgresData(uuid: accountId)]
        }
        let rows = try await db.query(sql, params).get()
        return try rows.map { try Self.decode($0) }
    }

    public static func decode(_ row: PostgresNIO.PostgresRow) throws -> DraftReply {
        let r = row.makeRandomAccess()
        let id: Int64 = try r["id"].decode(Int64.self)
        let accId: UUID = try r["account_id"].decode(UUID.self)
        let remoteId: String = try r["remote_id"].decode(String.self)
        let variantsJSON: String = try r["variants"].decode(String.self)
        let chosenVariant: Int? = try? r["chosen_variant"].decode(Int.self)
        let createdAt: Date = try r["created_at"].decode(Date.self)
        return DraftReply(
            id: id,
            accountId: accId,
            remoteId: remoteId,
            variants: parseVariantsJSON(variantsJSON),
            chosenVariant: chosenVariant,
            createdAt: createdAt
        )
    }

    private static func parseVariantsJSON(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8) else { return [] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String]) ?? []
    }
}
