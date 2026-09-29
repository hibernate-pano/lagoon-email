import Foundation
import GRDB
import LagoonKit

/// SQLite-backed whitelist autopilot rules (spec 2026-09-19 §3).
public enum AutoArchiveStore {
    public enum StoreError: Error { case insertFailed }

    /// Lowercased sender addresses for the sync loop's auto-archive matching.
    public static func senderAddresses(
        accountId: UUID,
        db: LagoonDB
    ) async throws -> Set<String> {
        let sql = "SELECT sender_address FROM auto_archive_rules WHERE account_id = ?"
        return try db.read { db in
            let rows = try Row.fetchAll(db, sql: sql, arguments: [accountId])
            return Set(rows.compactMap { $0.optionalText("sender_address") })
        }
    }

    public static func list(
        accountId: UUID,
        db: LagoonDB
    ) async throws -> [AutoArchiveRule] {
        let sql = """
            SELECT id, account_id, sender_address, created_at
            FROM auto_archive_rules
            WHERE account_id = ?
            ORDER BY created_at DESC, id DESC
        """
        return try db.read { db in
            try Row.fetchAll(db, sql: sql, arguments: [accountId]).map(decode)
        }
    }

    /// Insert-or-return-existing: creating a duplicate rule is a no-op that
    /// hands back the row already on file, so the client can treat "add" as
    /// idempotent.
    public static func create(
        accountId: UUID,
        senderAddress: String,
        db: LagoonDB
    ) async throws -> AutoArchiveRule {
        let address = senderAddress.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return try db.write { db in
            try db.execute(
                sql: """
                    INSERT INTO auto_archive_rules (account_id, sender_address)
                    VALUES (?, ?)
                    ON CONFLICT (account_id, sender_address) DO UPDATE SET sender_address = EXCLUDED.sender_address
                    """,
                arguments: [accountId, address]
            )
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT id, account_id, sender_address, created_at FROM auto_archive_rules WHERE account_id = ? AND sender_address = ?",
                arguments: [accountId, address]
            ) else {
                throw StoreError.insertFailed
            }
            return try decode(row)
        }
    }

    public static func delete(
        id: Int64,
        accountId: UUID,
        db: LagoonDB
    ) async throws {
        try db.write {
            try $0.execute(
                sql: "DELETE FROM auto_archive_rules WHERE id = ? AND account_id = ?",
                arguments: [id, accountId]
            )
        }
    }

    /// Remove the rule for one sender (undoing an auto-archive, V2 C2).
    /// Same normalization as `create`, so records written before the
    /// `sender` payload existed still match.
    public static func deleteSender(
        _ senderAddress: String,
        accountId: UUID,
        db: LagoonDB
    ) async throws {
        let address = senderAddress.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        try db.write {
            try $0.execute(
                sql: "DELETE FROM auto_archive_rules WHERE account_id = ? AND sender_address = ?",
                arguments: [accountId, address]
            )
        }
    }

    /// An address crosses the trust boundary. One ordinary mailbox, no display
    /// names, no lists, no whitespace or header fragments — same spirit as the
    /// new-message recipient check.
    public static func isValidSenderAddress(_ raw: String) -> Bool {
        let address = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, address.count <= 254 else { return false }
        guard address.contains(where: { $0.isWhitespace || $0.isNewline || !$0.isASCII }) == false else { return false }
        guard address.filter({ $0 == "@" }).count == 1 else { return false }
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return false }
        return true
    }

    /// 规则推荐：近 30 天被归档次数达到阈值、且还没有规则覆盖的发件人。
    /// 数据来自本地行（is_archived），不依赖 ai_actions payload 的历史形状。
    public static func suggestions(
        accountId: UUID,
        minCount: Int = 5,
        limit: Int = 5,
        db: LagoonDB
    ) async throws -> [AutoArchiveSuggestion] {
        let sql = """
            SELECT m.from_address AS sender,
                   MAX(NULLIF(m.from_name, '')) AS from_name,
                   COUNT(*) AS archive_count
            FROM message_headers m
            WHERE m.account_id = ?
              AND m.is_archived = TRUE
              AND m.is_deleted = FALSE
              AND m.received_at >= strftime('%Y-%m-%d %H:%M:%f','now','-30 days')
              AND NOT EXISTS (
                  SELECT 1 FROM auto_archive_rules r
                  WHERE r.account_id = m.account_id AND r.sender_address = m.from_address
              )
            GROUP BY m.from_address
            HAVING COUNT(*) >= ?
            ORDER BY archive_count DESC, sender ASC
            LIMIT ?
        """
        return try db.read { db in
            let rows = try Row.fetchAll(db, sql: sql, arguments: [accountId, minCount, limit])
            return rows.map { row in
                AutoArchiveSuggestion(
                    sender: row["sender"],
                    fromName: row.optionalText("from_name"),
                    archiveCount: row["archive_count"]
                )
            }
        }
    }

    // MARK: - Decoding

    private static func decode(_ row: Row) throws -> AutoArchiveRule {
        AutoArchiveRule(
            id: row["id"],
            accountId: row["account_id"],
            senderAddress: row["sender_address"],
            createdAt: row["created_at"]
        )
    }
}
