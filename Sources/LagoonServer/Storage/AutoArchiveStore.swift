import Foundation
import PostgresNIO
import LagoonKit

/// Postgres-backed whitelist autopilot rules (spec 2026-09-19 §3).
public enum AutoArchiveStore {
    public enum StoreError: Error { case insertFailed }

    /// Lowercased sender addresses for the sync loop's auto-archive matching.
    public static func senderAddresses(
        accountId: UUID,
        db: PostgresConnection
    ) async throws -> Set<String> {
        let rows = try await db.query(
            "SELECT sender_address FROM auto_archive_rules WHERE account_id = $1",
            [PostgresData(uuid: accountId)]
        ).get()
        let addresses = try rows.map { row -> String in
            try row.makeRandomAccess()["sender_address"].decode(String.self)
        }
        return Set(addresses)
    }

    public static func list(
        accountId: UUID,
        db: PostgresConnection
    ) async throws -> [AutoArchiveRule] {
        let rows = try await db.query(
            """
            SELECT id, account_id, sender_address, created_at
            FROM auto_archive_rules
            WHERE account_id = $1
            ORDER BY created_at DESC, id DESC
            """,
            [PostgresData(uuid: accountId)]
        ).get()
        return try rows.map(decode)
    }

    /// Insert-or-return-existing: creating a duplicate rule is a no-op that
    /// hands back the row already on file, so the client can treat "add" as
    /// idempotent.
    public static func create(
        accountId: UUID,
        senderAddress: String,
        db: PostgresConnection
    ) async throws -> AutoArchiveRule {
        let address = senderAddress.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let rows = try await db.query(
            """
            INSERT INTO auto_archive_rules (account_id, sender_address)
            VALUES ($1, $2)
            ON CONFLICT (account_id, sender_address) DO UPDATE SET sender_address = EXCLUDED.sender_address
            RETURNING id, account_id, sender_address, created_at
            """,
            [PostgresData(uuid: accountId), PostgresData(string: address)]
        ).get()
        guard let row = rows.first else {
            throw StoreError.insertFailed
        }
        return try decode(row)
    }

    public static func find(
        id: Int64,
        accountId: UUID,
        db: PostgresConnection
    ) async throws -> AutoArchiveRule? {
        let rows = try await db.query(
            "SELECT id, account_id, sender_address, created_at FROM auto_archive_rules WHERE id = $1 AND account_id = $2",
            [PostgresData(int64: id), PostgresData(uuid: accountId)]
        ).get()
        return try rows.first.map(decode)
    }

    public static func delete(
        id: Int64,
        accountId: UUID,
        db: PostgresConnection
    ) async throws {
        try await db.query(
            "DELETE FROM auto_archive_rules WHERE id = $1 AND account_id = $2",
            [PostgresData(int64: id), PostgresData(uuid: accountId)]
        ).get()
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

    // MARK: - Decoding

    private static func decode(_ row: PostgresNIO.PostgresRow) throws -> AutoArchiveRule {
        let r = row.makeRandomAccess()
        let id: Int64 = try r["id"].decode(Int64.self)
        let accountId: UUID = try r["account_id"].decode(UUID.self)
        let address: String = try r["sender_address"].decode(String.self)
        let createdAt: Date = try r["created_at"].decode(Date.self)
        return AutoArchiveRule(id: id, accountId: accountId, senderAddress: address, createdAt: createdAt)
    }
}
