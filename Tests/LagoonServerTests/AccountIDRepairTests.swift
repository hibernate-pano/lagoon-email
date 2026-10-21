import XCTest
import GRDB
@testable import LagoonServer
@testable import LagoonKit

/// The `accounts.id` encoding repair.
///
/// ## The defect these pin
///
/// `accounts.id` is `BLOB PRIMARY KEY` and GRDB stores a `UUID` as 16 raw
/// bytes. One real install had the same UUID in **two encodings**: the parent
/// row held the 36-character UTF-8 text, while every child table held the
/// 16-byte binary form. SQLite compares BLOB and TEXT as different values, so
/// the parent row was unreachable by every `WHERE id = ?` the server issues.
///
/// The user-visible damage was a lie: the account could not be found, the
/// sync failed, and the row's `sync_status` became `needsReconnect` — so the
/// app told the user their **authorization code had expired** when it was
/// perfectly fine.
///
/// These tests pin the properties the repair has to have: the text form is
/// rewritten to the binary form with every other column preserved, the repair
/// is idempotent, the store ends with zero foreign key violations, the
/// cascade fires afterwards, a fresh install is untouched, and the
/// mirror-image case (children holding text) is normalised too.
final class AccountIDRepairTests: XCTestCase {
    // MARK: - Fixtures

    private func tempPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lagoon-accountid-\(UUID().uuidString).sqlite").path
    }

    /// Creates the full schema without leaving a connection open.
    ///
    /// `LagoonDatabase.open` is the one place that knows the schema; using it
    /// here means the fixture can never drift from the real tables. The
    /// migrations run against an empty store, so every one of them is a
    /// no-op for the data.
    private func makeSchema(at path: String) throws {
        let pool = try LagoonDatabase.open(path: path)
        try pool.close()
    }

    /// A store whose `accounts` row holds the text form of a UUID while
    /// every child row holds the binary form — the exact shape the real
    /// install had.
    ///
    /// The rows are written with raw SQL, not through `AccountStore`, because
    /// the point is to reproduce a store the *current* code could not have
    /// produced. Foreign keys are off for the fixture write, since the
    /// fixture is by definition violating them.
    private func seedMismatchedAccount(
        at path: String,
        uuid: UUID,
        headers: Int = 3,
        advice: Int = 2,
        actions: Int = 4,
        drafts: Int = 1
    ) throws {
        let binary = AccountIDRepair.binaryBytes(for: uuid)
        let text = uuid.uuidString.lowercased()
        let pool = try DatabasePool(path: path)
        defer { try? pool.close() }
        try pool.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try db.execute(
                sql: """
                    INSERT INTO accounts (
                        id, provider, oauth_user, email, credentials, sync_state,
                        capabilities, is_active, sync_status, last_sync_at,
                        last_sync_error, created_at, updated_at
                    ) VALUES (
                        ?, 'qq', 'u@example.com', 'u@example.com', ?, '{}', '{}',
                        1, 'needsReconnect', '2026-10-06 14:21:10.410',
                        'not-configured', '2026-09-29 02:26:49.145',
                        '2026-10-06 14:38:24.411'
                    )
                    """,
                arguments: [text, Data([0xAB, 0xCD, 0xEF])]
            )
            for index in 0..<headers {
                try db.execute(
                    sql: """
                        INSERT INTO message_headers (
                            id, account_id, remote_id, thread_id, from_address,
                            subject, received_at
                        ) VALUES (?, ?, ?, 't1', 'a@example.com', 's', '2026-10-01 00:00:00.000')
                        """,
                    arguments: [UUID().uuidString, binary, "remote-\(index)"]
                )
            }
            for index in 0..<advice {
                try db.execute(
                    sql: """
                        INSERT INTO advice (
                            account_id, remote_id, action, confidence, source
                        ) VALUES (?, ?, 'remind', 'medium', 'heuristic')
                        """,
                    arguments: [binary, "remote-\(index % max(headers, 1))"]
                )
            }
            for _ in 0..<actions {
                try db.execute(
                    sql: "INSERT INTO ai_actions (account_id, kind, payload) VALUES (?, 'undo', '{}')",
                    arguments: [binary]
                )
            }
            for index in 0..<drafts {
                try db.execute(
                    sql: """
                        INSERT INTO draft_replies (account_id, remote_id, variants)
                        VALUES (?, ?, '[]')
                        """,
                    arguments: [binary, "remote-\(index % max(headers, 1))"]
                )
            }
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
    }

    /// Runs the repair exactly the way the migration does.
    @discardableResult
    private func runRepair(on pool: DatabasePool) throws -> [AccountIDRepair.Outcome] {
        try pool.write { db in
            try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
            defer { try? db.execute(sql: "PRAGMA defer_foreign_keys = OFF") }
            return try AccountIDRepair.repairAccountIDs(in: db)
        }
    }

    /// How many rows `PRAGMA foreign_key_check` reports.
    private func violationCount(_ pool: DatabasePool) throws -> Int {
        try pool.read { db in
            var count = 0
            try db.foreignKeyViolations().forEach { _ in count += 1 }
            return count
        }
    }

    /// The number of rows matching `sql` — used for the "did anything change"
    /// assertions.
    private func count(_ pool: DatabasePool, _ sql: String, _ arguments: StatementArguments = []) throws -> Int {
        try pool.read { db in
            try Int.fetchOne(db, sql: sql, arguments: arguments) ?? 0
        }
    }

    /// The stored form of the single account row.
    ///
    /// Read through `LagoonDB` rather than `DatabasePool.read` directly:
    /// `StoredForm` is `Sendable`, so the bare `pool.read` call resolves to
    /// the *async* overload and the test would have to `await` a read it
    /// wants to be synchronous. `LagoonDB.read` has one synchronous
    /// signature, which is the one these tests mean.
    private func storedAccountForm(_ pool: DatabasePool) throws -> AccountIDRepair.StoredForm? {
        try LagoonDB(pool).read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT id FROM accounts") else {
                return nil
            }
            let value: DatabaseValue = row["id"]
            return AccountIDRepair.storedForm(of: value)
        }
    }

    // MARK: - The repair

    /// The text-encoded id is rewritten to the binary form, and **every other
    /// column of the row is preserved byte for byte**.
    func test_repairRewritesTextIDToBinaryAndPreservesTheRestOfTheRow() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try makeSchema(at: path)
        let uuid = UUID()
        try seedMismatchedAccount(at: path, uuid: uuid)

        let pool = try DatabasePool(path: path)
        defer { try? pool.close() }

        let before = try pool.read { db -> Row in
            try XCTUnwrap(Row.fetchOne(db, sql: "SELECT * FROM accounts"))
        }
        XCTAssertEqual(
            AccountIDRepair.storedForm(of: before["id"]),
            .text(uuid.uuidString.lowercased())
        )
        XCTAssertEqual(
            try count(pool, "SELECT COUNT(*) FROM accounts WHERE id = ?", [uuid]),
            0,
            "a text-encoded id must be unreachable by the binary id the app holds"
        )

        let outcomes = try runRepair(on: pool)
        XCTAssertEqual(outcomes.count, 1, "exactly one account row needed repair")
        XCTAssertEqual(outcomes.first?.uuid, uuid)
        XCTAssertEqual(outcomes.first?.childRowsRewritten, 0, "children were already binary")

        let after = try pool.read { db -> Row in
            try XCTUnwrap(Row.fetchOne(db, sql: "SELECT * FROM accounts"))
        }
        XCTAssertEqual(
            AccountIDRepair.storedForm(of: after["id"]),
            .binary(AccountIDRepair.binaryBytes(for: uuid))
        )
        XCTAssertEqual(
            try count(pool, "SELECT COUNT(*) FROM accounts WHERE id = ?", [uuid]),
            1,
            "after the repair the account must be findable by the id the app holds"
        )

        // Every other column, unchanged. `credentials` especially: the user's
        // sealed authorization code must survive the repair untouched.
        XCTAssertEqual(after["provider"] as String, before["provider"] as String)
        XCTAssertEqual(after["oauth_user"] as String, before["oauth_user"] as String)
        XCTAssertEqual(after["email"] as String, before["email"] as String)
        XCTAssertEqual(after["credentials"] as Data, before["credentials"] as Data)
        XCTAssertEqual(after["credentials"] as Data, Data([0xAB, 0xCD, 0xEF]))
        XCTAssertEqual(after["sync_state"] as String, before["sync_state"] as String)
        XCTAssertEqual(after["capabilities"] as String, before["capabilities"] as String)
        XCTAssertEqual(after["is_active"] as Int, before["is_active"] as Int)
        XCTAssertEqual(after["sync_status"] as String, before["sync_status"] as String)
        XCTAssertEqual(after["last_sync_at"] as String, before["last_sync_at"] as String)
        XCTAssertEqual(after["last_sync_error"] as String, before["last_sync_error"] as String)
        XCTAssertEqual(after["created_at"] as String, before["created_at"] as String)
        XCTAssertEqual(after["updated_at"] as String, before["updated_at"] as String)
    }

    /// The repair is idempotent: running it again changes nothing and
    /// reports nothing.
    func test_repairIsIdempotent() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try makeSchema(at: path)
        let uuid = UUID()
        try seedMismatchedAccount(at: path, uuid: uuid)

        let pool = try DatabasePool(path: path)
        defer { try? pool.close() }

        XCTAssertEqual(try runRepair(on: pool).count, 1)
        XCTAssertTrue(
            try runRepair(on: pool).isEmpty,
            "a second run must find nothing to do, not repeat the work"
        )
        XCTAssertEqual(try count(pool, "SELECT COUNT(*) FROM accounts"), 1)
        XCTAssertEqual(
            try storedAccountForm(pool),
            .binary(AccountIDRepair.binaryBytes(for: uuid))
        )
    }

    /// After the repair the store has **zero** foreign key violations —
    /// before the repair it had one per child row.
    func test_repairClearsForeignKeyViolations() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try makeSchema(at: path)
        try seedMismatchedAccount(at: path, uuid: UUID(), headers: 5, advice: 3, actions: 6, drafts: 2)

        let pool = try DatabasePool(path: path)
        defer { try? pool.close() }

        XCTAssertGreaterThan(
            try violationCount(pool), 0,
            "the fixture must actually violate the foreign keys, or the test proves nothing"
        )
        try runRepair(on: pool)
        XCTAssertEqual(
            try violationCount(pool), 0,
            "the repair must leave the store with no foreign key violations"
        )
    }

    /// After the repair, `DELETE FROM accounts` really cascades: the child
    /// rows go with it. Before the repair it did not — the cascade never
    /// matched, which is how a deleted account left hundreds of orphans.
    func test_deleteCascadesAfterTheRepair() throws {
        // Before the repair: deleting by the stored (text) id removes the
        // parent and leaves every child behind.
        let beforePath = tempPath()
        defer { try? FileManager.default.removeItem(atPath: beforePath) }
        try makeSchema(at: beforePath)
        let uuid = UUID()
        try seedMismatchedAccount(at: beforePath, uuid: uuid, headers: 4, advice: 2, actions: 5, drafts: 1)
        do {
            let pool = try DatabasePool(path: beforePath)
            defer { try? pool.close() }
            try pool.write { db in
                try db.execute(
                    sql: "DELETE FROM accounts WHERE id = ?",
                    arguments: [uuid.uuidString.lowercased()]
                )
            }
            XCTAssertEqual(
                try count(pool, "SELECT COUNT(*) FROM message_headers"), 4,
                "a text parent key must not match a binary child key, so nothing cascades"
            )
        }

        // After the repair: the same delete takes the children with it.
        let afterPath = tempPath()
        defer { try? FileManager.default.removeItem(atPath: afterPath) }
        try makeSchema(at: afterPath)
        try seedMismatchedAccount(at: afterPath, uuid: uuid, headers: 4, advice: 2, actions: 5, drafts: 1)
        let repaired = try DatabasePool(path: afterPath)
        defer { try? repaired.close() }
        try runRepair(on: repaired)

        try repaired.write { db in
            try db.execute(
                sql: "DELETE FROM accounts WHERE id = ?",
                arguments: [AccountIDRepair.binaryBytes(for: uuid)]
            )
        }

        // Written out per table rather than built from a name: a table name
        // cannot be a bound parameter, and the project's guardrail forbids
        // splicing one into a SQL literal — including in a test.
        let remaining: [(String, Int)] = [
            ("message_headers", try count(repaired, "SELECT COUNT(*) FROM message_headers")),
            ("advice", try count(repaired, "SELECT COUNT(*) FROM advice")),
            ("ai_actions", try count(repaired, "SELECT COUNT(*) FROM ai_actions")),
            ("draft_replies", try count(repaired, "SELECT COUNT(*) FROM draft_replies")),
        ]
        for (table, rows) in remaining {
            XCTAssertEqual(rows, 0, "\(table) must be cascaded away with the account row")
        }
        XCTAssertEqual(try count(repaired, "SELECT COUNT(*) FROM accounts"), 0)
    }

    /// A fresh install — one where the account id is already in the binary
    /// form — is untouched by the repair.
    func test_freshInstallIsUnaffected() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try makeSchema(at: path)
        let uuid = UUID()
        let binary = AccountIDRepair.binaryBytes(for: uuid)
        do {
            let pool = try DatabasePool(path: path)
            defer { try? pool.close() }
            try pool.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO accounts (id, provider, oauth_user, email)
                        VALUES (?, 'qq', 'u@example.com', 'u@example.com')
                        """,
                    arguments: [binary]
                )
            }
        }

        let reopened = try DatabasePool(path: path)
        defer { try? reopened.close() }
        XCTAssertTrue(
            try runRepair(on: reopened).isEmpty,
            "a correctly-encoded account needs no repair"
        )
        XCTAssertEqual(try storedAccountForm(reopened), .binary(binary))
    }

    /// The mirror-image case: the *children* hold the text form while the
    /// parent holds the binary form. The children have to be brought along —
    /// a parent that stays binary while its children hold text is still a
    /// broken tree, and the children are still orphaned.
    func test_repairAlsoNormalisesChildrenThatHoldTheTextForm() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try makeSchema(at: path)
        let uuid = UUID()
        let binary = AccountIDRepair.binaryBytes(for: uuid)
        let text = uuid.uuidString.lowercased()
        do {
            let pool = try DatabasePool(path: path)
            defer { try? pool.close() }
            try pool.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA foreign_keys = OFF")
                try db.execute(
                    sql: """
                        INSERT INTO accounts (id, provider, oauth_user, email)
                        VALUES (?, 'qq', 'u@example.com', 'u@example.com')
                        """,
                    arguments: [binary]
                )
                for index in 0..<3 {
                    try db.execute(
                        sql: """
                            INSERT INTO message_headers (
                                id, account_id, remote_id, thread_id, from_address,
                                received_at
                            ) VALUES (?, ?, ?, 't1', 'a@example.com', '2026-10-01 00:00:00.000')
                            """,
                        arguments: [UUID().uuidString, text, "remote-\(index)"]
                    )
                }
                try db.execute(sql: "PRAGMA foreign_keys = ON")
            }
        }

        let reopened = try DatabasePool(path: path)
        defer { try? reopened.close() }

        XCTAssertGreaterThan(try violationCount(reopened), 0)

        let outcomes = try runRepair(on: reopened)
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(outcomes.first?.childRowsRewritten, 3)
        XCTAssertEqual(
            try violationCount(reopened), 0,
            "the children must be normalised too, or the tree is still broken"
        )
        let childForms = try LagoonDB(reopened).read { db -> [AccountIDRepair.StoredForm] in
            try Row.fetchAll(db, sql: "SELECT account_id FROM message_headers").map {
                AccountIDRepair.storedForm(of: $0["account_id"])!
            }
        }
        XCTAssertEqual(childForms.count, 3)
        XCTAssertTrue(childForms.allSatisfy { $0 == .binary(binary) })
    }

    /// A row whose id is not a UUID at all is left alone. The repair is not
    /// allowed to guess at a value it does not understand.
    func test_nonUUIDIDIsLeftAlone() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try makeSchema(at: path)
        do {
            let pool = try DatabasePool(path: path)
            defer { try? pool.close() }
            try pool.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO accounts (id, provider, oauth_user, email)
                        VALUES ('not-a-uuid', 'qq', 'u@example.com', 'u@example.com')
                        """
                )
            }
        }

        let reopened = try DatabasePool(path: path)
        defer { try? reopened.close() }
        XCTAssertTrue(try runRepair(on: reopened).isEmpty)
        XCTAssertEqual(
            try count(reopened, "SELECT COUNT(*) FROM accounts WHERE id = ?", ["not-a-uuid"]), 1
        )
    }

    // MARK: - Resilience: a mismatch the migration cannot fix

    /// A lookup that cannot find the account by id must **not** present as an
    /// expired authorization code.
    ///
    /// This is the part of the bug the user actually experienced. The row was
    /// there, the credentials were fine, and the app told them their
    /// authorization code had expired — sending them to re-enter a code that
    /// could not help, because the write went to a row the server could not
    /// address. The two states must be distinguishable, and the honest one
    /// must be the one that is reported.
    ///
    /// The UI half of this assertion lives in
    /// `Tests/LagoonTests/AccountMissingCopyTests.swift` — that is the target
    /// that can see `L10n`.
    func test_missingAccountIsItsOwnStatusAndCarriesItsOwnLabel() {
        let health = SyncHealth(
            status: .accountMissing,
            lastSyncAt: nil,
            lastError: MailError.accountMissing("").logLabel
        )
        XCTAssertEqual(health.lastError, "account-missing")
        XCTAssertNotEqual(
            health.status, .needsReconnect,
            "a store that cannot find the account is not the same thing as a rejected code"
        )
        XCTAssertNotEqual(
            MailError.accountMissing("").logLabel,
            MailError.authFailed.logLabel,
            "the two failures must not share a label, or the UI cannot tell them apart"
        )
        XCTAssertEqual(
            SyncHealthViewState.from(health),
            .accountMissing(reason: "account-missing"),
            "the view projection must keep the distinction, not collapse it"
        )
    }

    /// The tolerant lookup finds a row whose id is stored as text, so a
    /// store the migration could not repair still yields a working mailbox.
    ///
    /// It only ever reads: the stored id is left exactly as it was, because
    /// rewriting a primary key under a live connection is the migration's
    /// job, not a lookup's.
    func test_tolerantLookupFindsATextEncodedRowAndLeavesItAlone() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try makeSchema(at: path)
        let uuid = UUID()
        try seedMismatchedAccount(at: path, uuid: uuid, headers: 0, advice: 0, actions: 0, drafts: 0)

        let pool = try DatabasePool(path: path)
        defer { try? pool.close() }
        let db = LagoonDB(pool)

        // The strict lookup cannot see it — that is the defect.
        let strict = try await AccountStore.find(byId: uuid, db: db)
        XCTAssertNil(strict, "the strict lookup is exactly what failed the user")

        // The tolerant one can.
        let tolerant = try await AccountStore.findToleratingIDEncoding(byId: uuid, db: db)
        XCTAssertEqual(tolerant?.id, uuid)
        XCTAssertEqual(tolerant?.email, "u@example.com")

        // …and it did not rewrite anything.
        XCTAssertEqual(
            try storedAccountForm(pool), .text(uuid.uuidString.lowercased()),
            "a lookup must not rewrite the primary key; that is the migration's job"
        )
    }
}
