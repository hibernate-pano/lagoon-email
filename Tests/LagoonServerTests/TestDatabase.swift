import Foundation
import XCTest
import GRDB
@testable import LagoonKit
import LagoonServer

/// Hermetic SQLite test harness. Every `withConnection` opens a **fresh
/// temp-file database** with the full schema applied, so tests are fully
/// isolated from each other and from anything on the machine — no Docker, no
/// shared `lagoon_test` database, and nothing is ever skipped because a test
/// DB is unreachable.
///
/// The old Postgres harness needed the row-scoped `cleanup:` discipline
/// because `lagoon_test` persisted between runs and a table-wide wipe could
/// destroy real data. A per-test file that is deleted afterwards makes that
/// concern structurally impossible; `cleanup:` is still accepted (legacy call
/// sites pass it) and is simply a no-op slot now.
enum TestDatabase {
    /// Runs `body` with a private LagoonDB over a fresh SQLite file.
    static func withConnection(
        cleanup: (LagoonDB) async -> Void = { _ in },
        _ body: (LagoonDB) async throws -> Void
    ) async throws {
        let pool = try makePool()
        defer { try? pool.close() }
        try await body(LagoonDB(pool))
    }

    /// A second, independent store for tests that need two (the SyncEngine
    /// tests that used to need one Postgres connection per loop). The engine
    /// shares one pool now, so this mostly serves direct-construction tests.
    static func requireConnection() async throws -> LagoonDB {
        LagoonDB(try makePool())
    }

    static func makePool() throws -> DatabasePool {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lagoon-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try LagoonDatabase.open(path: dir.appendingPathComponent("lagoon.sqlite").path)
    }

    // MARK: - Direct helpers (ported call sites; scoped deletes)

    static func deleteAccount(id: UUID, db: LagoonDB) async throws {
        try db.write {
            try $0.execute(sql: "DELETE FROM accounts WHERE id = ?", arguments: [id])
        }
    }

    static func deleteAccount(
        oauthUser: String,
        provider: MailProviderKind,
        db: LagoonDB
    ) async throws {
        try db.write {
            try $0.execute(
                sql: "DELETE FROM accounts WHERE oauth_user = ? AND provider = ?",
                arguments: [oauthUser, provider.rawValue]
            )
        }
    }

    static func deleteMessages(accountId: UUID, db: LagoonDB) async throws {
        try db.write {
            try $0.execute(
                sql: "DELETE FROM message_headers WHERE account_id = ?",
                arguments: [accountId]
            )
        }
    }
}
