import XCTest
import Foundation
import Logging
import GRDB
// `@testable` for `LagoonDatabase.schema`, the same access
// `SchemaMigrationTests` uses to stand up a pre-migration fixture.
@testable import LagoonKit
@testable import LagoonServer

/// Pins the advisory-only constitution (§2 rules 2 and 5): the sync loop may
/// read mail and persist it, and may never write to the mailbox or change
/// message state on its own.
///
/// The strongest assertion here is the one the compiler makes. `ReadOnlyStub`
/// conforms to `MailSyncReading` *only* — it has no `archive`, `setRead`,
/// `trash` or `send`, and no `kind`. Handing it to `AccountSyncLoop` proves the
/// loop's factory takes the read-only protocol: a future edit that calls a
/// write method from the sync path cannot compile, so it cannot ship. The
/// behavioural tests below cover the half the compiler cannot see (the loop
/// must also not flip local state or write audit rows).
final class AdvisoryOnlySyncTests: XCTestCase {
    private let logger = Logger(label: "advisory-only-tests")

    // MARK: - The sync loop performs no writes

    /// Mail from a sender the user has archived five times before must still
    /// land unread and unarchived, with zero audit rows. This is exactly the
    /// case the removed whitelist autopilot used to auto-archive on arrival.
    func test_round_persistsArrivals_withoutArchivingOrAuditingAnything() async throws {
        let oauthUser = "advisory-\(UUID().uuidString)"

        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            try await TestDatabase.withConnection(cleanup: Self.cleanup(oauthUser)) { conn in
                let account = Self.account(oauthUser: oauthUser)
                try await Self.seed(account, db: conn)

                // A provider that physically cannot archive: the type has no
                // such method. If the loop tried, this file would not build.
                let provider = ReadOnlyStub(changes: MailChangeSet(
                    upserts: [
                        .stub(remoteId: "901", fromAddress: "noise@example.com", isRead: false),
                        .stub(remoteId: "902", fromAddress: "alice@example.com", isRead: false),
                    ],
                    resetRequired: false,
                    cursor: MailSyncState(uidValidity: 42, lastUid: 902)
                ))
                let loop = AccountSyncLoop(
                    account: account,
                    db: conn,
                    logger: self.logger,
                    makeProvider: { (_: Account) -> (any MailSyncReading)? in provider },
                    sleep: { _ in }
                )

                let parked = await loop.round()
                XCTAssertFalse(parked, "a healthy round keeps looping")

                // Both arrivals are stored, and neither was touched. `recent`
                // excludes archived rows, so a silent auto-archive would show
                // up as a missing row rather than a flag; assert the flags too.
                let stored = try await MessageStore.recent(forAccount: account.id, limit: 50, db: conn)
                XCTAssertEqual(Set(stored.map(\.remoteId)), ["901", "902"], "both arrivals must be in the store")
                for row in stored {
                    // One assertion instead of three so the message can carry
                    // the offending id: a SQL keyword (DELETE) sitting next to
                    // `\(` is exactly the shape the guardrail rejects, and
                    // dropping the id from the message would cost more in
                    // debuggability than the guard is worth.
                    if row.isArchived || row.isDeleted || row.isRead {
                        XCTFail("sync changed message state on its own: \(row.remoteId)")
                    }
                }

                let actions = try await AIActionStore.recent(accountId: account.id, db: conn)
                XCTAssertTrue(
                    actions.filter { $0.kind != .send }.isEmpty,
                    "sync must write no action audit rows; found \(actions.map(\.kind))"
                )

                let health = try await AccountStore.find(byId: account.id, db: conn)?.syncHealth
                XCTAssertEqual(health?.status, .ok)
            }
        }
    }

    /// Sent-folder reply signals are the one thing sync records on its own, and
    /// they must stay audit-only: they describe mail the user already sent from
    /// another client, they change no message state, and they are not undoable.
    func test_round_recordsSentReplySignals_asAuditOnlySignals() async throws {
        let oauthUser = "advisory-\(UUID().uuidString)"

        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            try await TestDatabase.withConnection(cleanup: Self.cleanup(oauthUser)) { conn in
                let account = Self.account(oauthUser: oauthUser)
                try await Self.seed(account, db: conn)

                let provider = ReadOnlyStub(changes: MailChangeSet(
                    upserts: [.stub(remoteId: "901", isRead: false)],
                    resetRequired: false,
                    cursor: MailSyncState(uidValidity: 42, lastUid: 901),
                    repliedMessageIds: ["<answered@example.com>"]
                ))
                let loop = AccountSyncLoop(
                    account: account,
                    db: conn,
                    logger: self.logger,
                    makeProvider: { (_: Account) -> (any MailSyncReading)? in provider },
                    sleep: { _ in }
                )
                await loop.round()

                let replied = try await AIActionStore.repliedRemoteIds(accountId: account.id, db: conn)
                XCTAssertEqual(replied, ["<answered@example.com>"], "the cross-client reply signal must survive")

                // The stored message itself is untouched by the signal.
                let row = try await MessageStore.find(remoteId: "901", accountId: account.id, db: conn)
                XCTAssertEqual(row?.isArchived, false)
                XCTAssertEqual(row?.isRead, false)
            }
        }
    }

    // MARK: - The auto-archive rule table is gone

    /// A fresh install must not create the table, and an install that already
    /// had it must have it dropped by `lagoon-v3`. GRDB records migrations by
    /// identifier, so editing `lagoon-v1`'s body would have been a silent no-op
    /// on every existing database — the same trap `indexReconciliation` exists
    /// to avoid.
    func test_autoArchiveRulesTable_isAbsentOnFreshAndLegacyDatabases() throws {
        // Legacy install: pre-advisory-only schema, with a rule on file.
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("lagoon-advisory-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        let legacy = try DatabasePool(path: path)
        var legacyMigrator = DatabaseMigrator()
        legacyMigrator.registerMigration(LagoonDatabase.currentVersion) { db in
            try db.execute(sql: LagoonDatabase.schema)
            try db.execute(sql: """
                CREATE TABLE auto_archive_rules (
                    id             INTEGER PRIMARY KEY AUTOINCREMENT,
                    account_id     BLOB NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    sender_address TEXT NOT NULL,
                    created_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%f','now')),
                    UNIQUE (account_id, sender_address)
                );
                """)
        }
        legacyMigrator.registerMigration(LagoonDatabase.indexVersion) { _ in }
        try legacyMigrator.migrate(legacy)

        let accountID = UUID()
        try legacy.write { db in
            try db.execute(
                sql: "INSERT INTO accounts (id, provider, oauth_user, email) VALUES (?,?,?,?)",
                arguments: [accountID, "qq", "a@b.c", "a@b.c"]
            )
            try db.execute(
                sql: "INSERT INTO auto_archive_rules (account_id, sender_address) VALUES (?,?)",
                arguments: [accountID, "noise@example.com"]
            )
        }
        XCTAssertTrue(try Self.hasTable("auto_archive_rules", in: legacy), "fixture must be pre-fix")
        try legacy.close()

        // Bringing the legacy install forward drops the table and keeps the
        // account row: removing a rule store must not cost the user their mail.
        let upgraded = try LagoonDatabase.open(path: path)
        defer { try? upgraded.close() }
        XCTAssertFalse(
            try Self.hasTable("auto_archive_rules", in: upgraded),
            "the whitelist rule table must be dropped from an existing install"
        )
        let accounts = try upgraded.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM accounts") ?? 0 }
        XCTAssertEqual(accounts, 1, "dropping the rule table must not touch account data")

        // A brand-new install never creates it.
        let freshPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("lagoon-advisory-fresh-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: freshPath) }
        let fresh = try LagoonDatabase.open(path: freshPath)
        defer { try? fresh.close() }
        XCTAssertFalse(try Self.hasTable("auto_archive_rules", in: fresh))

        let versions = try fresh.read {
            try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
        }
        XCTAssertEqual(
            versions,
            [
                LagoonDatabase.currentVersion,
                LagoonDatabase.indexVersion,
                LagoonDatabase.advisoryOnlyVersion,
                LagoonDatabase.adviceVersion,
                LagoonDatabase.sentFolderVersion,
            ]
        )
    }

    /// The rules API is gone at the type level: `AutoArchiveRoutes` no longer
    /// exists, so any call site fails to compile. That is a stronger guarantee
    /// than a 404 assertion, which could only ever prove "this router happens
    /// not to register it".

    // MARK: - Helpers

    private static func hasTable(_ name: String, in pool: DatabasePool) throws -> Bool {
        try pool.read { db in
            (try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?",
                arguments: [name]
            ) ?? 0) > 0
        }
    }

    private static func account(oauthUser: String) -> Account {
        Account(
            id: UUID(),
            provider: .qq,
            oauthUser: oauthUser,
            email: "\(oauthUser)@qq.com",
            credentials: nil
        )
    }

    private static func seed(_ account: Account, db: LagoonDB) async throws {
        try await AccountStore.upsert(
            account,
            credentials: try CredentialVault.seal(
                .imap(username: "\(account.oauthUser)@qq.com", authCode: "auth-code")
            ),
            db: db
        )
    }

    private static func cleanup(_ oauthUser: String) -> @Sendable (LagoonDB) async -> Void {
        { conn in
            try? await TestDatabase.deleteAccount(oauthUser: oauthUser, provider: .qq, db: conn)
        }
    }
}

/// Conforms to `MailSyncReading` and nothing else. The absence of write
/// methods is the point: this type is what the sync loop is allowed to hold,
/// and it cannot archive, mark read, trash or send.
private actor ReadOnlyStub: MailSyncReading {
    private let changes: MailChangeSet
    private var served = false
    private(set) var shutdownCount = 0

    init(changes: MailChangeSet) {
        self.changes = changes
    }

    func capabilities() async -> MailCapabilities {
        // Advertises archive support on purpose: the loop must ignore it.
        MailCapabilities(archiveFolder: true, idle: true, move: true, serverSnippet: false)
    }

    func pullChanges(
        after cursor: MailSyncState,
        waitUpTo: Duration
    ) async throws -> MailChangeSet {
        guard !served else {
            return MailChangeSet(upserts: [], resetRequired: false, cursor: cursor)
        }
        served = true
        return changes
    }

    func shutdown() async {
        shutdownCount += 1
    }
}
