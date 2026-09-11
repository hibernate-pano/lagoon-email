import Foundation
import XCTest
import PostgresNIO
import NIOCore
@testable import LagoonKit

/// Guarded Postgres access for the Lagoon server integration tests.
///
/// The old tests issued unqualified table-wide deletes against whatever
/// `DATABASE_URL` pointed at, so running `swift test` by hand against the dev
/// database wiped real data. `connect()` is fail-closed:
///
///   * `DATABASE_URL` (default `.../lagoon_test`) is parsed;
///   * the connection is only attempted when the host is loopback **and** the
///     database name ends in `_test`;
///   * otherwise it returns `nil`, callers `throw XCTSkip`, and nothing is
///     touched — there is no fallback to a non-test database.
///
/// Cleanup helpers delete only the rows a test created (by `id` / `oauth_user`).
enum TestDatabase {
    static let defaultURLString = "postgres://lagoon:lagoon@127.0.0.1:5433/lagoon_test"

    /// One shared group for the lifetime of the test process. NIO event loops
    /// keep their parent group alive, so a per-call group would leak a thread
    /// per test; a single shared group is the smallest safe footprint.
    private static let eventLoopGroup = LagoonPostgres.makeEventLoopGroup()

    // MARK: - Guard

    static func resolvedURL() -> URL? {
        let raw = ProcessInfo.processInfo.environment["DATABASE_URL"] ?? defaultURLString
        return URL(string: raw)
    }

    static func databaseName(from url: URL) -> String {
        url.path.split(separator: "/").map(String.init).last ?? ""
    }

    static func isLoopbackHost(_ host: String) -> Bool {
        switch host.lowercased() {
        case "127.0.0.1", "::1", "localhost": return true
        default: return false
        }
    }

    /// The data-loss guard: only a loopback host *and* a database whose name
    /// ends in `_test` may ever be touched.
    static func isSafeTestDatabase(_ url: URL) -> Bool {
        guard let host = url.host, !host.isEmpty else { return false }
        let name = databaseName(from: url)
        return isLoopbackHost(host) && name.lowercased().hasSuffix("_test")
    }

    static func makeConfig(from url: URL) -> PostgresConfig? {
        guard let host = url.host,
              let port = url.port,
              let user = url.user,
              let pass = url.password
        else { return nil }
        return PostgresConfig(
            host: host,
            port: port,
            username: user,
            password: pass,
            database: databaseName(from: url),
            tls: url.query?.contains("sslmode=require") ?? false
        )
    }

    /// Returns a connection to the dedicated test DB, or `nil` when the
    /// configured DB is not a safe test DB. Callers must skip on `nil` and
    /// never proceed against a non-test database.
    static func connect() async throws -> PostgresConnection? {
        guard let url = resolvedURL(), isSafeTestDatabase(url) else { return nil }
        guard let cfg = makeConfig(from: url) else { return nil }
        return try await LagoonPostgres.connect(cfg, on: eventLoopGroup.any())
    }

    // MARK: - Row-scoped cleanup (never DELETE the whole table)

    static func deleteAccount(id: UUID, db: PostgresConnection) async throws {
        try await db.query("DELETE FROM accounts WHERE id = $1", [PostgresData(uuid: id)]).get()
    }

    static func deleteAccount(
        oauthUser: String,
        provider: MailProviderKind,
        db: PostgresConnection
    ) async throws {
        try await db.query(
            "DELETE FROM accounts WHERE oauth_user = $1 AND provider = $2",
            [PostgresData(string: oauthUser), PostgresData(string: provider.rawValue)]
        ).get()
    }

    static func deleteMessages(accountId: UUID, db: PostgresConnection) async throws {
        try await db.query(
            "DELETE FROM message_headers WHERE account_id = $1",
            [PostgresData(uuid: accountId)]
        ).get()
    }

    // MARK: - Test harness

    /// Runs `body` with a guarded test connection and always runs `cleanup`
    /// (row-scoped) before closing — even when `body` throws. Skips the test
    /// when no safe test database is configured.
    static func withConnection(
        cleanup: @Sendable (PostgresConnection) async -> Void = { _ in },
        _ body: (PostgresConnection) async throws -> Void
    ) async throws {
        let maybe = try await connect()
        try XCTSkipIf(
            maybe == nil,
            "skipping: DATABASE_URL must be a loopback host and a database name ending in _test; refusing to touch a non-test database"
        )
        guard let conn = maybe else { return }
        do {
            try await body(conn)
        } catch {
            await cleanup(conn)
            try? await conn.close()
            throw error
        }
        await cleanup(conn)
        try await conn.close()
    }
}
