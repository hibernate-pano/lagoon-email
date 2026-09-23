import Foundation
import Logging
import PostgresNIO
import LagoonKit

public enum AccountStoreError: Error { case notFound }

public enum AccountStore {
    // Every query uses $N placeholders — no SQL is ever concatenated. The
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

    private static func encodeJSON<T: Encodable>(_ value: T) throws -> Data {
        try jsonEncoder.encode(value)
    }

    private static func decodeJSON<T: Decodable>(_ type: T.Type, from data: Data?) -> T? {
        guard let data else { return nil }
        return try? jsonDecoder.decode(T.self, from: data)
    }

    /// Insert a new account or refresh the stored credentials of the existing
    /// one (same provider + oauth_user). Credentials arrive already sealed.
    public static func upsert(
        _ account: Account,
        credentials: Data,
        db: PostgresConnection
    ) async throws {
        let sql = """
            INSERT INTO accounts (
                id, provider, oauth_user, email, credentials, sync_state, capabilities,
                is_active, sync_status, last_sync_at, last_sync_error, created_at, updated_at
            ) VALUES (
                $1, $2, $3, $4, $5, $6, $7,
                $8, $9, $10, $11, now(), now()
            )
            ON CONFLICT (provider, oauth_user) DO UPDATE SET
                email = EXCLUDED.email,
                credentials = EXCLUDED.credentials,
                updated_at = now()
        """
        try await db.query(sql, [
            PostgresData(uuid: account.id),
            PostgresData(string: account.provider.rawValue),
            PostgresData(string: account.oauthUser),
            PostgresData(string: account.email),
            PostgresData(bytes: credentials),
            PostgresData(jsonb: try encodeJSON(account.syncState)),
            PostgresData(jsonb: try encodeJSON(account.capabilities)),
            PostgresData(bool: account.isActive),
            PostgresData(string: account.syncHealth.status.rawValue),
            account.syncHealth.lastSyncAt.map { PostgresData(date: $0) } ?? .null,
            account.syncHealth.lastError.map { PostgresData(string: $0) } ?? .null
        ]).get()
    }

    /// Replace only the sealed credential blob (token refresh / re-auth).
    /// Never touches read state, cursor, or health.
    public static func updateCredentials(
        accountId: UUID,
        credentials: Data,
        db: PostgresConnection
    ) async throws {
        let sql = """
            UPDATE accounts
            SET credentials = $2, updated_at = now()
            WHERE id = $1
        """
        try await db.query(sql, [
            PostgresData(uuid: accountId),
            PostgresData(bytes: credentials)
        ]).get()
    }

    public static func updateSyncState(
        accountId: UUID,
        syncState: MailSyncState,
        db: PostgresConnection
    ) async throws {
        let sql = """
            UPDATE accounts
            SET sync_state = $2, updated_at = now()
            WHERE id = $1
        """
        try await db.query(sql, [
            PostgresData(uuid: accountId),
            PostgresData(jsonb: try encodeJSON(syncState))
        ]).get()
    }

    public static func updateCapabilities(
        accountId: UUID,
        capabilities: MailCapabilities,
        db: PostgresConnection
    ) async throws {
        let sql = """
            UPDATE accounts
            SET capabilities = $2, updated_at = now()
            WHERE id = $1
        """
        try await db.query(sql, [
            PostgresData(uuid: accountId),
            PostgresData(jsonb: try encodeJSON(capabilities))
        ]).get()
    }

    /// Writes the three health columns. `lastSyncAt` is set on success by the
    /// caller; a `needsReconnect` write keeps whatever error text explains it.
    public static func updateHealth(
        accountId: UUID,
        health: SyncHealth,
        db: PostgresConnection
    ) async throws {
        let sql = """
            UPDATE accounts
            SET sync_status = $2,
                last_sync_at = COALESCE($3, last_sync_at),
                last_sync_error = $4,
                updated_at = now()
            WHERE id = $1
        """
        try await db.query(sql, [
            PostgresData(uuid: accountId),
            PostgresData(string: health.status.rawValue),
            health.lastSyncAt.map { PostgresData(date: $0) } ?? .null,
            health.lastError.map { PostgresData(string: $0) } ?? .null
        ]).get()
    }

    /// All connected accounts, used by GET /api/accounts.
    public static func all(db: PostgresConnection) async throws -> [Account] {
        let sql = """
            SELECT id, provider, oauth_user, email, credentials, sync_state,
                   capabilities, is_active, sync_status, last_sync_at, last_sync_error
            FROM accounts
            ORDER BY email
        """
        let rows = try await db.query(sql, []).get()
        return try rows.map { try Self.decode($0) }
    }

    /// The client's selected mailbox (filter marker). All accounts sync
    /// concurrently; this only decides which mailbox the UI shows.
    public static func active(db: PostgresConnection) async throws -> Account? {
        let sql = """
            SELECT id, provider, oauth_user, email, credentials, sync_state,
                   capabilities, is_active, sync_status, last_sync_at, last_sync_error
            FROM accounts
            WHERE is_active = TRUE
            LIMIT 1
        """
        let rows = try await db.query(sql, []).get()
        return try rows.first.map { try Self.decode($0) }
    }

    /// Atomically move the selection marker. Exclusivity is now a client
    /// convention (no partial unique index since 014); the transaction keeps
    /// the read-modify-write atomic.
    public static func setActive(
        accountId: UUID,
        db: PostgresConnection
    ) async throws {
        try await db.withTransaction(logger: Logger(label: "lagoon.account-store")) { transaction in
            try await transaction.query(
                "UPDATE accounts SET is_active = FALSE WHERE is_active = TRUE"
            ).get()
            try await transaction.query(
                """
                UPDATE accounts
                SET is_active = TRUE, updated_at = now()
                WHERE id = $1
                """,
                [PostgresData(uuid: accountId)]
            ).get()
        }
    }

    /// Repair a zero-selected state after a delete or an interrupted switch.
    public static func reconcileActive(db: PostgresConnection) async throws {
        if try await active(db: db) != nil { return }
        guard let newest = try await mostRecentlyUpdated(db: db) else { return }
        try await setActive(accountId: newest.id, db: db)
    }

    private static func mostRecentlyUpdated(
        db: PostgresConnection
    ) async throws -> Account? {
        let sql = """
            SELECT id, provider, oauth_user, email, credentials, sync_state,
                   capabilities, is_active, sync_status, last_sync_at, last_sync_error
            FROM accounts
            ORDER BY updated_at DESC, id
            LIMIT 1
        """
        let rows = try await db.query(sql, []).get()
        return try rows.first.map { try Self.decode($0) }
    }

    /// Deletes the account row; foreign keys cascade to messages/pins/drafts.
    public static func delete(accountId: UUID, db: PostgresConnection) async throws {
        let sql = "DELETE FROM accounts WHERE id = $1"
        try await db.query(sql, [PostgresData(uuid: accountId)]).get()
    }

    public static func find(
        byOAuthUser oauthUser: String,
        provider: MailProviderKind,
        db: PostgresConnection
    ) async throws -> Account? {
        let sql = """
            SELECT id, provider, oauth_user, email, credentials, sync_state,
                   capabilities, is_active, sync_status, last_sync_at, last_sync_error
            FROM accounts
            WHERE oauth_user = $1 AND provider = $2
            LIMIT 1
        """
        let rows = try await db.query(sql, [
            PostgresData(string: oauthUser),
            PostgresData(string: provider.rawValue)
        ]).get()
        for row in rows {
            return try Self.decode(row)
        }
        return nil
    }

    public static func find(
        byEmail email: String,
        provider: MailProviderKind,
        db: PostgresConnection
    ) async throws -> Account? {
        let sql = """
            SELECT id, provider, oauth_user, email, credentials, sync_state,
                   capabilities, is_active, sync_status, last_sync_at, last_sync_error
            FROM accounts
            WHERE email = $1 AND provider = $2
            LIMIT 1
        """
        let rows = try await db.query(sql, [
            PostgresData(string: email),
            PostgresData(string: provider.rawValue)
        ]).get()
        for row in rows {
            return try Self.decode(row)
        }
        return nil
    }

    public static func find(
        byId id: UUID,
        db: PostgresConnection
    ) async throws -> Account? {
        let sql = """
            SELECT id, provider, oauth_user, email, credentials, sync_state,
                   capabilities, is_active, sync_status, last_sync_at, last_sync_error
            FROM accounts
            WHERE id = $1
            LIMIT 1
        """
        let rows = try await db.query(sql, [PostgresData(uuid: id)]).get()
        for row in rows {
            return try Self.decode(row)
        }
        return nil
    }

    public static func decode(_ row: PostgresNIO.PostgresRow) throws -> Account {
        let r = row.makeRandomAccess()
        let id: UUID = try r["id"].decode(UUID.self)
        let providerRaw: String = try r["provider"].decode(String.self)
        let oauthUser: String = try r["oauth_user"].decode(String.self)
        let email: String = try r["email"].decode(String.self)
        let credentials: Data? = try r["credentials"].decode(Data?.self)
        let syncState = decodeJSON(MailSyncState.self, from: r[data: "sync_state"].jsonb) ?? MailSyncState()
        let capabilities = decodeJSON(MailCapabilities.self, from: r[data: "capabilities"].jsonb) ?? .unknown
        let isActive: Bool = try r["is_active"].decode(Bool.self)
        let statusRaw: String = try r["sync_status"].decode(String.self)
        let lastSyncAt: Date? = try r["last_sync_at"].decode(Date?.self)
        let lastError: String? = try r["last_sync_error"].decode(String?.self)
        return Account(
            id: id,
            provider: MailProviderKind(rawValue: providerRaw) ?? .gmail,
            oauthUser: oauthUser,
            email: email,
            credentials: credentials,
            syncState: syncState,
            capabilities: capabilities,
            isActive: isActive,
            syncHealth: SyncHealth(
                status: SyncHealth.Status(rawValue: statusRaw) ?? .ok,
                lastSyncAt: lastSyncAt,
                lastError: lastError
            )
        )
    }
}
