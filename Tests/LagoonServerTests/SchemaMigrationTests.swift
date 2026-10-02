import XCTest
import GRDB
@testable import LagoonKit

/// GRDB records applied migrations by *identifier*, not by content. Editing
/// the body of an already-applied migration therefore does nothing, silently:
/// the 2026-09-29 index work looked correct in every fresh test database and
/// was absent from every real install. These pin the property that would have
/// caught it.
final class SchemaMigrationTests: XCTestCase {
    private func tempPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lagoon-mig-\(UUID().uuidString).sqlite").path
    }

    private func indexNames(_ db: Database) throws -> [String] {
        try Row.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index'")
            .map { $0["name"] as String }
    }

    /// A database created by the *old* single-migration schema, then brought
    /// forward: the index reconciliation must apply, without touching rows.
    func test_indexMigrationAppliesToAnAlreadyMigratedDatabase() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        // Stand up the pre-fix state: tables as they are, but with the three
        // indexes that were later removed and none of the four that were
        // added — i.e. exactly what a real install looks like today. The
        // schema string is not duplicated here on purpose: it has already
        // moved on, and re-typing it would make this fixture drift with it.
        let legacy = try DatabasePool(path: path)
        var legacyMigrator = DatabaseMigrator()
        legacyMigrator.registerMigration("lagoon-v1") { db in
            try db.execute(sql: LagoonDatabase.schema)
            try db.execute(sql: """
                DROP INDEX message_headers_account_sender_idx;
                DROP INDEX message_headers_unread_idx;
                DROP INDEX message_headers_list_unsubscribe_idx;
                DROP INDEX ai_actions_undo_of_idx;
                CREATE INDEX message_headers_thread_idx
                    ON message_headers (account_id, thread_id);
                CREATE INDEX accounts_provider_idx ON accounts (provider);
                CREATE INDEX ai_actions_expires_idx ON ai_actions(expires_at);
                """)
        }
        try legacyMigrator.migrate(legacy)

        let before = try legacy.read { try self.indexNames($0) }
        XCTAssertTrue(before.contains("message_headers_thread_idx"), "fixture must be pre-fix")
        XCTAssertFalse(before.contains("message_headers_unread_idx"))
        // Seed a row so the migration is proven not to touch data.
        try legacy.write { db in
            try db.execute(
                sql: "INSERT INTO accounts (id, provider, oauth_user, email, created_at) VALUES (?,?,?,?,?)",
                arguments: [UUID(), "qq", "a@b.c", "a@b.c", "2026-09-29 00:00:00.000"]
            )
        }
        try legacy.close()

        let after = try LagoonDatabase.open(path: path)
        defer { try? after.close() }
        let namesAfter = try after.read { try self.indexNames($0) }
        XCTAssertTrue(
            namesAfter.contains("message_headers_unread_idx"),
            "the added index must reach an existing install, not just fresh ones"
        )
        XCTAssertTrue(namesAfter.contains("ai_actions_undo_of_idx"))
        XCTAssertTrue(namesAfter.contains("message_headers_account_sender_idx"))
        XCTAssertTrue(namesAfter.contains("message_headers_list_unsubscribe_idx"))
        XCTAssertFalse(namesAfter.contains("message_headers_thread_idx"), "write-only index must be dropped")
        XCTAssertFalse(namesAfter.contains("accounts_provider_idx"))
        XCTAssertFalse(namesAfter.contains("ai_actions_expires_idx"))
        let accountCount = try after.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM accounts") ?? 0 }
        XCTAssertEqual(accountCount, 1, "an index migration must never touch data")
    }

    /// Fresh installs run `lagoon-v1` then `lagoon-v2`. The reconciliation is
    /// written `IF EXISTS` / `IF NOT EXISTS` precisely so this path does not
    /// fail on indexes `lagoon-v1` already omits.
    func test_freshInstallRunsBothMigrationsWithoutFailing() throws {
        let pool = try LagoonDatabase.open(path: tempPath())
        defer { try? pool.close() }
        let names = try pool.read { try self.indexNames($0) }
        XCTAssertTrue(names.contains("message_headers_unread_idx"))
        XCTAssertTrue(names.contains("message_headers_account_sender_idx"))
        XCTAssertTrue(names.contains("message_headers_list_unsubscribe_idx"))
        XCTAssertTrue(names.contains("ai_actions_undo_of_idx"))
        XCTAssertFalse(names.contains("message_headers_thread_idx"))
        XCTAssertFalse(names.contains("accounts_provider_idx"))
        XCTAssertFalse(names.contains("ai_actions_expires_idx"))
    }

    /// Re-opening a current database must be a no-op, not an error — the app
    /// opens its store on every launch.
    func test_reopeningIsIdempotent() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let first = try LagoonDatabase.open(path: path)
        try first.close()
        let second = try LagoonDatabase.open(path: path)
        defer { try? second.close() }
        let versions = try second.read {
            try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
        }
        // Compared as a set against the declared constants, not as a
        // lexicographically-ordered literal: `ORDER BY identifier` would put a
        // future `lagoon-v10` before `lagoon-v2`, and every new migration would
        // otherwise fail here for a reason unrelated to idempotency.
        XCTAssertEqual(
            Set(versions),
            Set([
                LagoonDatabase.currentVersion,
                LagoonDatabase.indexVersion,
                LagoonDatabase.advisoryOnlyVersion,
                LagoonDatabase.adviceVersion,
            ]),
            "every registered migration must be recorded exactly once"
        )
        XCTAssertEqual(versions.count, Set(versions).count, "a migration must not be recorded twice")
    }
}
