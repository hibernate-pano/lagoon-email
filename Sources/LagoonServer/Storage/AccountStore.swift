import Foundation
import PostgresNIO
import LagoonKit

public enum AccountStoreError: Error { case notFound }

public enum AccountStore {
    /// Every query uses $N placeholders — no SQL is ever concatenated.
    public static func upsert(
        _ account: Account,
        accessToken: Data,
        refreshToken: Data,
        db: PostgresConnection
    ) async throws {
        let sql = """
            INSERT INTO accounts (
                id, provider, oauth_user, email,
                access_token, refresh_token, token_expires_at, history_id,
                created_at, updated_at
            ) VALUES (
                $1, $2, $3, $4,
                $5, $6, $7, $8,
                now(), now()
            )
            ON CONFLICT (provider, oauth_user) DO UPDATE SET
                email = EXCLUDED.email,
                access_token = EXCLUDED.access_token,
                refresh_token = EXCLUDED.refresh_token,
                token_expires_at = EXCLUDED.token_expires_at,
                history_id = CASE WHEN EXCLUDED.history_id IS NOT NULL
                                  THEN EXCLUDED.history_id
                                  ELSE accounts.history_id END,
                updated_at = now()
        """
        try await db.query(sql, [
            PostgresData(uuid: account.id),
            PostgresData(string: account.provider.rawValue),
            PostgresData(string: account.oauthUser),
            PostgresData(string: account.email),
            PostgresData(bytes: accessToken),
            PostgresData(bytes: refreshToken),
            PostgresData(date: account.tokenExpiresAt),
            account.historyId.map { PostgresData(string: $0) } ?? PostgresData.null
        ]).get()
    }

    /// Update only the OAuth tokens (refresh flow). Never touches read state.
    public static func updateTokens(
        accountId: UUID,
        accessTokenCiphertext: Data,
        refreshTokenCiphertext: Data,
        expiresAt: Date,
        db: PostgresConnection
    ) async throws {
        let sql = """
            UPDATE accounts
            SET access_token = $2,
                refresh_token = $3,
                token_expires_at = $4,
                updated_at = now()
            WHERE id = $1
        """
        try await db.query(sql, [
            PostgresData(uuid: accountId),
            PostgresData(bytes: accessTokenCiphertext),
            PostgresData(bytes: refreshTokenCiphertext),
            PostgresData(date: expiresAt)
        ]).get()
    }

    /// All connected accounts, used by GET /api/accounts.
    public static func all(db: PostgresConnection) async throws -> [Account] {
        let sql = """
            SELECT id, provider, oauth_user, email, token_expires_at, history_id
            FROM accounts
            ORDER BY email
        """
        let rows = try await db.query(sql, []).get()
        return try rows.map { try Self.decode($0) }
    }

    public static func find(
        byOAuthUser oauthUser: String,
        provider: MailProvider,
        db: PostgresConnection
    ) async throws -> Account? {
        let sql = """
            SELECT id, provider, oauth_user, email, token_expires_at, history_id
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
        byId id: UUID,
        db: PostgresConnection
    ) async throws -> Account? {
        let sql = """
            SELECT id, provider, oauth_user, email, token_expires_at, history_id
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
        let tokenExpiresAt: Date = try r["token_expires_at"].decode(Date.self)
        let historyRaw: String = (try? r["history_id"].decode(String.self)) ?? ""
        return Account(
            id: id,
            provider: MailProvider(rawValue: providerRaw) ?? .gmail,
            oauthUser: oauthUser,
            email: email,
            tokenExpiresAt: tokenExpiresAt,
            historyId: historyRaw.isEmpty ? nil : historyRaw
        )
    }
}