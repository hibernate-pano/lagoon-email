import Foundation
import PostgresNIO
import LagoonKit

/// 用户自定义聚合（归集规则）的存取。规则求值交给 `MessageStore.recent` 的
/// `stackMatch` 臂；这里只管规则行本身和面板用的计数。
public enum StackStore {
    // All values bound ($N); the keyword pattern is escaped + bound by the
    // caller. No SQL is ever assembled from user input.


    private static func decodeKind(_ column: PostgresNIO.PostgresCell) throws -> StackRule.Kind {
        let raw = try column.decode(String.self)
        guard let kind = StackRule.Kind(rawValue: raw) else {
            throw StoreError.insertFailed
        }
        return kind
    }

    // MARK: - Decoding

    public static func list(
        accountId: UUID,
        db: PostgresConnection
    ) async throws -> [StackRule] {
        let sql = """
            SELECT id, account_id, name, kind, value, created_at
            FROM stack_rules
            WHERE account_id = $1
            ORDER BY created_at ASC
        """
        let rows = try await db.query(sql, [PostgresData(uuid: accountId)]).get()
        return try rows.map { row in
            let r = row.makeRandomAccess()
            return StackRule(
                id: try r["id"].decode(UUID.self),
                accountId: try r["account_id"].decode(UUID.self),
                name: try r["name"].decode(String.self),
                kind: try Self.decodeKind(r["kind"]),
                value: try r["value"].decode(String.self),
                createdAt: try r["created_at"].decode(Date.self)
            )
        }
    }

    /// Single rule by id, scoped to the account; nil when absent.
    public static func listStackRule(
        id: UUID,
        accountId: UUID,
        db: PostgresConnection
    ) async throws -> StackRule? {
        let sql = """
            SELECT id, account_id, name, kind, value, created_at
            FROM stack_rules
            WHERE id = $1 AND account_id = $2
            LIMIT 1
        """
        let rows = try await db.query(sql, [
            PostgresData(uuid: id),
            PostgresData(uuid: accountId),
        ]).get()
        guard let row = rows.rows.first else { return nil }
        let r = row.makeRandomAccess()
        return StackRule(
            id: try r["id"].decode(UUID.self),
            accountId: try r["account_id"].decode(UUID.self),
            name: try r["name"].decode(String.self),
            kind: try Self.decodeKind(r["kind"]),
            value: try r["value"].decode(String.self),
            createdAt: try r["created_at"].decode(Date.self)
        )
    }

    public static func create(
        accountId: UUID,
        name: String,
        kind: StackRule.Kind,
        value: String,
        db: PostgresConnection
    ) async throws -> StackRule {
        let sql = """
            INSERT INTO stack_rules (account_id, name, kind, value)
            VALUES ($1, $2, $3, $4)
            RETURNING id, account_id, name, kind, value, created_at
        """
        let rows = try await db.query(sql, [
            PostgresData(uuid: accountId),
            PostgresData(string: name),
            PostgresData(string: kind.rawValue),
            PostgresData(string: value),
        ]).get()
        guard let row = rows.rows.first else {
            throw StoreError.insertFailed
        }
        let r = row.makeRandomAccess()
        return StackRule(
            id: try r["id"].decode(UUID.self),
            accountId: try r["account_id"].decode(UUID.self),
            name: try r["name"].decode(String.self),
            kind: try Self.decodeKind(r["kind"]),
            value: try r["value"].decode(String.self),
            createdAt: try r["created_at"].decode(Date.self)
        )
    }

    /// Returns false when the rule does not exist (or belongs to another
    /// account — account_id in the WHERE keeps tenants honest).
    public static func delete(
        id: UUID,
        accountId: UUID,
        db: PostgresConnection
    ) async throws -> Bool {
        let sql = "DELETE FROM stack_rules WHERE id = $1 AND account_id = $2 RETURNING id"
        let result = try await db.query(sql, [
            PostgresData(uuid: id),
            PostgresData(uuid: accountId),
        ]).get()
        return result.rows.first != nil
    }

    /// How many live (non-deleted) messages the rule currently matches.
    /// Archived mail counts: a stack is a lens over everything related,
    /// including what already sits in the cabinet.
    public static func messageCount(
        rule: StackRule,
        db: PostgresConnection
    ) async throws -> Int {
        let sql: String
        let params: [PostgresData]
        switch rule.kind {
        case .sender:
            sql = """
                SELECT COUNT(*) FROM message_headers
                WHERE account_id = $1 AND is_deleted = FALSE AND from_address = $2
            """
            params = [PostgresData(uuid: rule.accountId), PostgresData(string: rule.value)]
        case .keyword:
            sql = """
                SELECT COUNT(*) FROM message_headers
                WHERE account_id = $1 AND is_deleted = FALSE AND subject ILIKE $2 ESCAPE '\\'
            """
            params = [
                PostgresData(uuid: rule.accountId),
                PostgresData(string: MessageStore.likePattern(containing: rule.value)),
            ]
        }
        let result = try await db.query(sql, params).get()
        guard let row = result.rows.first else { return 0 }
        return try row.makeRandomAccess()["count"].decode(Int.self)
    }
}

enum StoreError: Error {
    case insertFailed
}
