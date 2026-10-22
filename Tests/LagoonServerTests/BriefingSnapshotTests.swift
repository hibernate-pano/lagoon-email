import XCTest
import Foundation
import Logging
import Hummingbird
import HummingbirdTesting
import NIOCore
import GRDB
@testable import LagoonKit
@testable import LagoonServer

/// The briefing's rows and the numbers that describe them come from one
/// snapshot.
///
/// The feed says two things about the same window: "here are the rows" and
/// "here is how many rows the window holds". Read separately, the two can
/// describe different mailboxes — a write landing between the reads made the
/// count and the list disagree:
///
/// - a mail that **arrived** in between was reported as "left out of the
///   briefing", when it had simply arrived after the list was taken;
/// - a mail that **left** the window in between made the count smaller than
///   the list, so a window the cap had really truncated reported no
///   truncation at all — the failure mode the whole "say what is missing"
///   rule exists to prevent.
///
/// These tests place that write on purpose. It fires from the SQL trace the
/// moment the count statement is about to run, so it lands between the two
/// reads every time, instead of whenever the scheduler feels like it.
final class BriefingSnapshotTests: XCTestCase {
    private let logger = Logger(label: "briefing-snapshot-tests")

    private func makeAccount() -> Account {
        Account(
            id: UUID(),
            provider: .qq,
            oauthUser: "snap-\(UUID().uuidString)",
            email: "snap-\(UUID().uuidString)@qq.com",
            credentials: nil
        )
    }

    private func seed(_ account: Account, db: LagoonDB) async throws {
        try await AccountStore.upsert(
            account,
            credentials: try CredentialVault.seal(
                .imap(username: account.email, authCode: "auth-code")
            ),
            db: db
        )
    }

    private func header(
        _ remoteId: String,
        accountId: UUID,
        daysAgo: Double,
        isRead: Bool = false,
        isArchived: Bool = false
    ) -> MessageHeader {
        MessageHeader(
            id: UUID(),
            accountId: accountId,
            remoteId: remoteId,
            threadId: "t-\(remoteId)",
            fromAddress: "sender@example.com",
            fromName: "Sender",
            subject: "Subject \(remoteId)",
            snippet: nil,
            receivedAt: Date().addingTimeInterval(-daysAgo * 24 * 60 * 60),
            isRead: isRead,
            isArchived: isArchived
        )
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func router(_ db: LagoonDB) -> Router<BasicRequestContext> {
        let router = Router()
        BriefingRoutes.register(on: router, db: db, logger: self.logger)
        return router
    }

    private func briefing(
        _ accountId: UUID,
        db: LagoonDB,
        limit: Int
    ) async throws -> BriefingResponse {
        let app = Application(router: router(db))
        var out: BriefingResponse?
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/briefing?accountId=\(accountId.uuidString)&limit=\(limit)",
                method: .get
            ) { response in
                XCTAssertEqual(response.status, .ok)
                out = try Self.decoder().decode(
                    BriefingResponse.self,
                    from: Data(buffer: response.body)
                )
            }
        }
        return try XCTUnwrap(out)
    }

    /// A pool that hands every statement it runs to `hook`.
    ///
    /// The same temporary file, the same schema and the same cipher functions
    /// as `TestDatabase` — the trace is the only difference, and it is what
    /// lets a test put a write between two reads.
    private static func tracedPool(
        hook: StatementHook
    ) throws -> (pool: DatabasePool, db: LagoonDB) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lagoon-briefing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        TestDatabase.installTestBodyKey()
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.prepareDatabase { db in
            db.add(function: BodyCipher.containsFunction)
            db.add(function: BodyCipher.sealFunction)
            db.trace { event in
                guard case .statement(let statement) = event else { return }
                hook.handle(statement.sql)
            }
        }
        let pool = try DatabasePool(
            path: dir.appendingPathComponent("lagoon.sqlite").path,
            configuration: configuration
        )
        try LagoonDatabase.migrator.migrate(pool)
        return (pool, LagoonDB(pool))
    }

    /// The window's rows statement.
    ///
    /// The write has to land here, not on the count: a read transaction
    /// fixes its snapshot when it starts, so a write committed while the
    /// *count* runs is invisible to that count, while one committed while
    /// the *rows* are read falls between the two snapshots — which is the
    /// gap this file is about.
    private static func isWindowRows(_ sql: String) -> Bool {
        sql.contains("received_at >= ?") && sql.contains("ORDER BY h.received_at DESC")
    }

    /// The backlog's rows statement.
    private static func isBacklogRows(_ sql: String) -> Bool {
        sql.contains("received_at < ?") && sql.contains("ORDER BY h.received_at ASC")
    }

    // MARK: - The window

    /// A window that fits reports no omission.
    ///
    /// The plain case, and the rule the rest of this file defends: the count
    /// is only about rows the cap actually left out.
    func test_aWindowThatFits_reportsNoOmission() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                for i in 0..<3 {
                    try await MessageStore.upsert(
                        header("m-\(i)", accountId: account.id, daysAgo: 1), db: conn
                    )
                }
                let body = try await briefing(account.id, db: conn, limit: 5)
                XCTAssertEqual(body.items.count, 3, "the feed is the window")
                XCTAssertNil(
                    body.omittedCount,
                    "nothing was left out, so the response must not claim anything was"
                )
            }
        }
    }

    /// A mail that lands between the two reads is not "left out".
    ///
    /// It arrived after the list was taken; the next refresh carries it. The
    /// old arithmetic (`count - rows`, over two snapshots) turned it into an
    /// omission and told the user a mail was being withheld that was not.
    func test_aMailThatLandsBetweenTheReads_isNotReportedAsLeftOut() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            let hook = StatementHook()
            let (pool, db) = try Self.tracedPool(hook: hook)
            defer { try? pool.close() }
            try await seed(account, db: db)
            for i in 0..<3 {
                try await MessageStore.upsert(
                    header("m-\(i)", accountId: account.id, daysAgo: 1), db: db
                )
            }
            // Filed out of the inbox, so this snapshot does not see it.
            try await MessageStore.upsert(
                header("landed", accountId: account.id, daysAgo: 1, isArchived: true), db: db
            )
            hook.arm(matching: Self.isWindowRows) {
                try db.write { raw in
                    try raw.execute(
                        sql: "UPDATE message_headers SET is_archived = FALSE WHERE remote_id = ?",
                        arguments: ["landed"]
                    )
                }
            }

            let body = try await briefing(account.id, db: db, limit: 5)

            XCTAssertNil(hook.error, "the write between the reads must have landed")
            XCTAssertEqual(body.items.count, 3, "the mail that landed is not in this snapshot")
            XCTAssertNil(
                body.omittedCount,
                "a mail that arrived after the list was taken was never left out of it"
            )
        }
    }

    /// A mail that leaves the window between the two reads does not shrink
    /// the count below the list.
    ///
    /// This is the direction that hides something: eight rows in the window,
    /// five shown, three left out — and a mail archived in between made the
    /// count say "two left out", or, one row short of the cap, say nothing
    /// at all. The cap's omission is a fact about the window the list came
    /// from, and it has to be reported from that same window.
    func test_aMailThatLeavesTheWindowBetweenTheReads_doesNotHideTheTruncation() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            let hook = StatementHook()
            let (pool, db) = try Self.tracedPool(hook: hook)
            defer { try? pool.close() }
            try await seed(account, db: db)
            for i in 0..<8 {
                try await MessageStore.upsert(
                    header("m-\(i)", accountId: account.id, daysAgo: 1), db: db
                )
            }
            hook.arm(matching: Self.isWindowRows) {
                try db.write { raw in
                    try raw.execute(
                        sql: "UPDATE message_headers SET is_archived = TRUE WHERE remote_id = ?",
                        arguments: ["m-7"]
                    )
                }
            }

            let body = try await briefing(account.id, db: db, limit: 5)

            XCTAssertNil(hook.error, "the write between the reads must have landed")
            XCTAssertEqual(body.items.count, 5, "the cap is honoured")
            XCTAssertEqual(
                body.omittedCount, 3,
                "the window held 8 rows and 5 were shown: 3 were left out, and the mail that left the window in between does not change that"
            )
        }
    }

    // MARK: - The backlog

    /// The backlog's count describes the backlog the feed shows.
    ///
    /// The same defect, one list over: the backlog's rows and the backlog's
    /// count were read separately, so a mail archived in between left the
    /// response claiming fewer waiting mails than the feed was carrying.
    func test_theBacklogCountDescribesTheBacklogTheFeedShows() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            let hook = StatementHook()
            let (pool, db) = try Self.tracedPool(hook: hook)
            defer { try? pool.close() }
            try await seed(account, db: db)
            // Old, unread, still waiting — and nothing inside the window, so
            // every item in the feed is a backlog item.
            for i in 0..<3 {
                try await MessageStore.upsert(
                    header("old-\(i)", accountId: account.id, daysAgo: 40), db: db
                )
            }
            hook.arm(matching: Self.isBacklogRows) {
                try db.write { raw in
                    try raw.execute(
                        sql: "UPDATE message_headers SET is_archived = TRUE WHERE remote_id = ?",
                        arguments: ["old-2"]
                    )
                }
            }

            let body = try await briefing(account.id, db: db, limit: 500)

            XCTAssertNil(hook.error, "the write between the reads must have landed")
            XCTAssertEqual(body.items.count, 3, "the backlog's rows are in the feed")
            XCTAssertEqual(
                body.backlogCount, 3,
                "the count must describe the backlog the feed is showing, not a backlog one mail smaller"
            )
        }
    }
}

/// Runs one action, the first time a traced statement matches.
///
/// The action runs on the database's own thread, inside the statement that
/// matched — which is the only place a write can land and still fall
/// between two reads.
private final class StatementHook: @unchecked Sendable {
    private let lock = NSLock()
    private var predicate: ((String) -> Bool)?
    private var action: (() throws -> Void)?
    private var fired = false
    private var failure: Error?

    /// Arms the hook. It fires once, on the next matching statement.
    func arm(
        matching predicate: @escaping (String) -> Bool,
        action: @escaping () throws -> Void
    ) {
        lock.lock()
        defer { lock.unlock() }
        self.predicate = predicate
        self.action = action
        self.fired = false
        self.failure = nil
    }

    /// Called for every statement the database runs.
    func handle(_ sql: String) {
        lock.lock()
        let matches = !fired && (predicate?(sql) ?? false)
        if matches { fired = true }
        let action = self.action
        lock.unlock()
        guard matches, let action else { return }
        do {
            try action()
        } catch {
            lock.lock()
            failure = error
            lock.unlock()
        }
    }

    /// Why the write did not happen, if it did not.
    var error: Error? {
        lock.lock()
        defer { lock.unlock() }
        return failure
    }
}
