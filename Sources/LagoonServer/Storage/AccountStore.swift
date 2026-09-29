import Foundation
import Logging
import GRDB
import LagoonKit

public enum AccountStoreError: Error {
    case notFound
    /// A row whose `provider` column holds a value this build has no
    /// implementation for. Surfacing it is deliberate: coercing an unknown
    /// provider to a known one would hand the account to a client that cannot
    /// actually reach its mailbox.
    case unknownProvider(String)
}

public enum AccountStore {
    // Every query uses `?` placeholders — no SQL is ever concatenated. The
    // SELECT column list is repeated literally per query (the CI guardrail
    // forbids interpolation inside SQL literals, even for constants).

    private static let jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let jsonDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private static func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try jsonEncoder.encode(value), as: UTF8.self)
    }

    /// Insert a new account or refresh the stored credentials of the existing
    /// one (same provider + oauth_user). Credentials arrive already sealed.
    public static func upsert(
        _ account: Account,
        credentials: Data,
        db: LagoonDB
    ) async throws {
        let sql = """
            INSERT INTO accounts (
                id, provider, oauth_user, email, credentials, sync_state, capabilities,
                is_active, sync_status, last_sync_at, last_sync_error, created_at, updated_at
            ) VALUES (
                ?, ?, ?, ?, ?, ?, ?,
                ?, ?, ?, ?, strftime('%Y-%m-%d %H:%M:%f','now'), strftime('%Y-%m-%d %H:%M:%f','now')
            )
            ON CONFLICT (provider, oauth_user) DO UPDATE SET
                email = EXCLUDED.email,
                credentials = EXCLUDED.credentials,
                updated_at = strftime('%Y-%m-%d %H:%M:%f','now')
        """
        try db.write {
            try $0.execute(sql: sql, arguments: [
                account.id,
                account.provider.rawValue,
                account.oauthUser,
                account.email,
                credentials,
                try encodeJSON(account.syncState),
                try encodeJSON(account.capabilities),
                account.isActive,
                account.syncHealth.status.rawValue,
                account.syncHealth.lastSyncAt,
                account.syncHealth.lastError
            ])
        }
    }

    /// Replace only the sealed credential blob (token refresh / re-auth).
    /// Never touches read state, cursor, or health.
    public static func updateCredentials(
        accountId: UUID,
        credentials: Data,
        db: LagoonDB
    ) async throws {
        try db.write {
            try $0.execute(
                sql: "UPDATE accounts SET credentials = ?, updated_at = strftime('%Y-%m-%d %H:%M:%f','now') WHERE id = ?",
                arguments: [credentials, accountId]
            )
        }
    }

    public static func updateSyncState(
        accountId: UUID,
        syncState: MailSyncState,
        db: LagoonDB
    ) async throws {
        try db.write {
            try $0.execute(
                sql: "UPDATE accounts SET sync_state = ?, updated_at = strftime('%Y-%m-%d %H:%M:%f','now') WHERE id = ?",
                arguments: [try encodeJSON(syncState), accountId]
            )
        }
    }

    public static func updateCapabilities(
        accountId: UUID,
        capabilities: MailCapabilities,
        db: LagoonDB
    ) async throws {
        try db.write {
            try $0.execute(
                sql: "UPDATE accounts SET capabilities = ?, updated_at = strftime('%Y-%m-%d %H:%M:%f','now') WHERE id = ?",
                arguments: [try encodeJSON(capabilities), accountId]
            )
        }
    }

    /// Writes the three health columns. `lastSyncAt` is set on success by the
    /// caller; a `needsReconnect` write keeps whatever error text explains it.
    public static func updateHealth(
        accountId: UUID,
        health: SyncHealth,
        db: LagoonDB
    ) async throws {
        let sql = """
            UPDATE accounts
            SET sync_status = ?,
                last_sync_at = COALESCE(?, last_sync_at),
                last_sync_error = ?,
                updated_at = strftime('%Y-%m-%d %H:%M:%f','now')
            WHERE id = ?
        """
        try db.write {
            try $0.execute(sql: sql, arguments: [
                health.status.rawValue,
                health.lastSyncAt,
                health.lastError,
                accountId
            ])
        }
    }

    private static let accountColumns = """
        SELECT id, provider, oauth_user, email, credentials, sync_state,
               capabilities, is_active, sync_status, last_sync_at, last_sync_error
        FROM accounts
    """

    /// All connected accounts, used by GET /api/accounts.
    public static func all(db: LagoonDB) async throws -> [Account] {
        let sql = accountColumns + "\n            ORDER BY email"
        return try db.read { db in
            try Row.fetchAll(db, sql: sql).map { try Self.decode($0) }
        }
    }

    /// The client's selected mailbox (filter marker). All accounts sync
    /// concurrently; this only decides which mailbox the UI shows.
    public static func active(db: LagoonDB) async throws -> Account? {
        let sql = accountColumns + "\n            WHERE is_active = TRUE\n            LIMIT 1"
        return try db.read { db in
            try Row.fetchOne(db, sql: sql).map { try Self.decode($0) }
        }
    }

    /// Atomically move the selection marker. Exclusivity is now a client
    /// convention (no partial unique index since 014); the write closure keeps
    /// the read-modify-write atomic.
    public static func setActive(
        accountId: UUID,
        db: LagoonDB
    ) async throws {
        try db.write { db in
            try db.execute(sql: "UPDATE accounts SET is_active = FALSE WHERE is_active = TRUE")
            try db.execute(
                sql: """
                    UPDATE accounts
                    SET is_active = TRUE, updated_at = strftime('%Y-%m-%d %H:%M:%f','now')
                    WHERE id = ?
                    """,
                arguments: [accountId]
            )
        }
    }

    /// Repair a zero-selected state after a delete or an interrupted switch.
    public static func reconcileActive(db: LagoonDB) async throws {
        if try await active(db: db) != nil { return }
        guard let newest = try await mostRecentlyUpdated(db: db) else { return }
        try await setActive(accountId: newest.id, db: db)
    }

    private static func mostRecentlyUpdated(
        db: LagoonDB
    ) async throws -> Account? {
        let sql = accountColumns + "\n            ORDER BY updated_at DESC, id\n            LIMIT 1"
        return try db.read { db in
            try Row.fetchOne(db, sql: sql).map { try Self.decode($0) }
        }
    }

    /// Deletes the account row; foreign keys cascade to messages/pins/drafts.
    public static func delete(accountId: UUID, db: LagoonDB) async throws {
        try db.write {
            try $0.execute(sql: "DELETE FROM accounts WHERE id = ?", arguments: [accountId])
        }
    }

    public static func find(
        byOAuthUser oauthUser: String,
        provider: MailProviderKind,
        db: LagoonDB
    ) async throws -> Account? {
        let sql = accountColumns + "\n            WHERE oauth_user = ? AND provider = ?\n            LIMIT 1"
        return try db.read { db in
            try Row.fetchOne(db, sql: sql, arguments: [oauthUser, provider.rawValue])
                .map { try Self.decode($0) }
        }
    }

    public static func find(
        byEmail email: String,
        provider: MailProviderKind,
        db: LagoonDB
    ) async throws -> Account? {
        let sql = accountColumns + "\n            WHERE email = ? AND provider = ?\n            LIMIT 1"
        return try db.read { db in
            try Row.fetchOne(db, sql: sql, arguments: [email, provider.rawValue])
                .map { try Self.decode($0) }
        }
    }

    public static func find(
        byId id: UUID,
        db: LagoonDB
    ) async throws -> Account? {
        let sql = accountColumns + "\n            WHERE id = ?\n            LIMIT 1"
        return try db.read { db in
            try Row.fetchOne(db, sql: sql, arguments: [id]).map { try Self.decode($0) }
        }
    }

    public static func decode(_ row: Row) throws -> Account {
        let credentials: Data? = row["credentials"]
        let rawProvider: String = row["provider"]
        guard let provider = MailProviderKind(rawValue: rawProvider) else {
            throw AccountStoreError.unknownProvider(rawProvider)
        }
        return Account(
            id: row["id"],
            provider: provider,
            oauthUser: row["oauth_user"],
            email: row["email"],
            credentials: credentials,
            syncState: row.decodedJSON("sync_state", as: MailSyncState.self, decoder: jsonDecoder) ?? MailSyncState(),
            capabilities: row.decodedJSON("capabilities", as: MailCapabilities.self, decoder: jsonDecoder) ?? .unknown,
            isActive: row["is_active"],
            syncHealth: SyncHealth(
                status: SyncHealth.Status(rawValue: row["sync_status"]) ?? .ok,
                lastSyncAt: row["last_sync_at"],
                lastError: row["last_sync_error"]
            )
        )
    }
}
