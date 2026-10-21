import Foundation
import XCTest
import GRDB
import Crypto
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
        installTestBodyKey()
        return try LagoonDatabase.open(path: dir.appendingPathComponent("lagoon.sqlite").path)
    }

    /// The body is sealed at rest, so every test that opens a store needs a
    /// body key. It is a **fixed** key, not a random one: the same key has
    /// to be in place for the whole test process, because the seal/open
    /// round trip and the migration both use the process-wide provider, and
    /// a key that changed between two calls would read back as garbage.
    ///
    /// A test key is not a secret. It protects nothing — the store is a
    /// throwaway file in the temporary directory.
    static func installTestBodyKey() {
        guard BodyCipher.keyProvider == nil else { return }
        let bytes = Data((0..<32).map { UInt8($0) })
        BodyCipher.keyProvider = { SymmetricKey(data: bytes) }
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
