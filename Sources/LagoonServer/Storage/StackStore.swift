import Foundation
import GRDB
import LagoonKit

/// 用户自定义聚合（归集规则）的存取。规则求值交给 `MessageStore.recent` 的
/// `stackMatch` 臂；这里只管规则行本身和面板用的计数。
public enum StackStore {
    // All values bound (`?`); the keyword pattern is escaped + bound by the
    // caller. No SQL is ever assembled from user input.

    private static func decodeKind(_ raw: String) throws -> StackRule.Kind {
        guard let kind = StackRule.Kind(rawValue: raw) else {
            throw StoreError.insertFailed
        }
        return kind
    }

    private static let columns = "id, account_id, name, kind, value, created_at"

    // MARK: - Decoding

    public static func list(
        accountId: UUID,
        db: LagoonDB
    ) async throws -> [StackRule] {
        let sql = """
            SELECT id, account_id, name, kind, value, created_at
            FROM stack_rules
            WHERE account_id = ?
            ORDER BY created_at ASC
        """
        return try db.read { db in
            try Row.fetchAll(db, sql: sql, arguments: [accountId]).map(decode)
        }
    }

    /// Single rule by id, scoped to the account; nil when absent.
    public static func listStackRule(
        id: UUID,
        accountId: UUID,
        db: LagoonDB
    ) async throws -> StackRule? {
        let sql = """
            SELECT id, account_id, name, kind, value, created_at
            FROM stack_rules
            WHERE id = ? AND account_id = ?
            LIMIT 1
        """
        return try db.read { db in
            try Row.fetchOne(db, sql: sql, arguments: [id, accountId]).map(decode)
        }
    }

    public static func create(
        accountId: UUID,
        name: String,
        kind: StackRule.Kind,
        value: String,
        db: LagoonDB
    ) async throws -> StackRule {
        let rule = StackRule(
            id: UUID(),
            accountId: accountId,
            name: name,
            kind: kind,
            value: value,
            createdAt: Date()
        )
        try db.write {
            try $0.execute(
                sql: "INSERT INTO stack_rules (id, account_id, name, kind, value, created_at) VALUES (?, ?, ?, ?, ?, ?)",
                arguments: [rule.id, rule.accountId, rule.name, rule.kind.rawValue, rule.value, rule.createdAt]
            )
        }
        return rule
    }

    /// Returns false when the rule does not exist (or belongs to another
    /// account — account_id in the WHERE keeps tenants honest).
    public static func delete(
        id: UUID,
        accountId: UUID,
        db: LagoonDB
    ) async throws -> Bool {
        try db.write { db in
            try db.execute(
                sql: "DELETE FROM stack_rules WHERE id = ? AND account_id = ?",
                arguments: [id, accountId]
            )
            return db.changesCount > 0
        }
    }

    /// How many live (non-deleted) messages the rule currently matches.
    /// Archived mail counts: a stack is a lens over everything related,
    /// including what already sits in the cabinet.
    public static func messageCount(
        rule: StackRule,
        db: LagoonDB
    ) async throws -> Int {
        let sql: String
        let args: [DatabaseValueConvertible?]
        switch rule.kind {
        case .sender:
            sql = """
                SELECT COUNT(*) AS count FROM message_headers
                WHERE account_id = ? AND is_deleted = FALSE AND from_address = ?
                """
            args = [rule.accountId, rule.value]
        case .keyword:
            sql = """
                SELECT COUNT(*) AS count FROM message_headers
                WHERE account_id = ? AND is_deleted = FALSE AND subject LIKE ? ESCAPE '\\'
                """
            args = [
                rule.accountId,
                MessageStore.likePattern(containing: rule.value),
            ]
        }
        return try db.read { db in
            try Row.fetchOne(db, sql: sql, arguments: StatementArguments(args))?["count"] ?? 0
        }
    }

    private static func decode(_ row: Row) -> StackRule {
        StackRule(
            id: row["id"],
            accountId: row["account_id"],
            name: row["name"],
            kind: (try? decodeKind(row["kind"])) ?? .sender,
            value: row["value"],
            createdAt: row["created_at"]
        )
    }
}
