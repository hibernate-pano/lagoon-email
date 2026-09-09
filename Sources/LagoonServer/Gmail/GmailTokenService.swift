import Foundation
import Logging
import PostgresNIO
import LagoonKit

/// Shared access-token acquisition for every server-side Gmail call.
///
/// Extracted from `GmailPoller` so the poller and the message routes share one
/// refresh path (and one single-flight registry) instead of duplicating the
/// refresh logic. Semantics are unchanged from the original poller:
///
///   * proactive refresh when the stored token is within 60s of expiry;
///   * single-flight: overlapping callers for the same account await the first
///     in-flight refresh instead of POSTing to Google twice;
///   * the stored refresh token survives when Google omits a new one;
///   * new tokens are persisted before they are returned.
public actor GmailTokenService {
    public struct Token: Sendable {
        public let accessToken: String
        /// True when this call refreshed (so a subsequent 401 is genuine and
        /// must not trigger a second refresh in the same operation).
        public let didRefresh: Bool

        public init(accessToken: String, didRefresh: Bool) {
            self.accessToken = accessToken
            self.didRefresh = didRefresh
        }
    }

    private let db: PostgresConnection
    private let oauth: GoogleOAuthClient
    private let logger: Logger

    /// In-flight refreshes keyed by account id. Overlapping callers await the
    /// first refresh instead of issuing a duplicate POST to Google.
    private var refreshInFlight: [UUID: Task<AccessTokenCipher.StoredCredentials, Error>] = [:]

    public init(db: PostgresConnection, oauth: GoogleOAuthClient, logger: Logger) {
        self.db = db
        self.oauth = oauth
        self.logger = logger
    }

    /// A token that is valid for at least ~60s, refreshing proactively when the
    /// stored one is at or near expiry.
    public func validToken(for account: Account) async throws -> Token {
        var creds = try await AccessTokenCipher.read(accountId: account.id, db: db)
        // Refresh a little before expiry so an in-flight call does not 401.
        if creds.expiresAt <= Date().addingTimeInterval(60) {
            creds = try await refreshSingleFlight(account: account, current: creds)
            return Token(accessToken: creds.accessToken, didRefresh: true)
        }
        return Token(accessToken: creds.accessToken, didRefresh: false)
    }

    /// Force a refresh after a 401 and return the new access token. Still
    /// single-flight: if a refresh for this account is already running, this
    /// call returns that result rather than starting another one.
    @discardableResult
    public func forceRefresh(for account: Account) async throws -> String {
        let current = try await AccessTokenCipher.read(accountId: account.id, db: db)
        let creds = try await refreshSingleFlight(account: account, current: current)
        return creds.accessToken
    }

    /// Single-flight wrapper: if a refresh for this account is already in
    /// flight, await that result instead of starting a second one. Cleared as
    /// soon as the in-flight attempt finishes (success or failure).
    private func refreshSingleFlight(
        account: Account,
        current: AccessTokenCipher.StoredCredentials
    ) async throws -> AccessTokenCipher.StoredCredentials {
        if let inFlight = refreshInFlight[account.id] {
            return try await inFlight.value
        }
        let task = Task { try await self.refreshCredentials(account: account, current: current) }
        refreshInFlight[account.id] = task
        defer { refreshInFlight[account.id] = nil }
        return try await task.value
    }

    /// Exchange the stored refresh token, persist the new tokens, and return
    /// them. Google usually omits a new refresh token on refresh; when it does
    /// we keep the stored one.
    private func refreshCredentials(
        account: Account,
        current: AccessTokenCipher.StoredCredentials
    ) async throws -> AccessTokenCipher.StoredCredentials {
        let result = try await oauth.refresh(refreshToken: current.refreshToken)
        let refreshToken = result.refreshToken ?? current.refreshToken
        let expiresAt = Date().addingTimeInterval(TimeInterval(result.expiresIn))
        try await AccountStore.updateTokens(
            accountId: account.id,
            accessTokenCiphertext: try AccessTokenCipher.seal(result.accessToken),
            refreshTokenCiphertext: try AccessTokenCipher.seal(refreshToken),
            expiresAt: expiresAt,
            db: db
        )
        logger.info("refreshed access token", metadata: ["account": .string(account.email)])
        return AccessTokenCipher.StoredCredentials(
            accessToken: result.accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt
        )
    }
}
