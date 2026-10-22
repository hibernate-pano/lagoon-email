import XCTest
import Foundation
import Logging
import GRDB
import Hummingbird
@testable import LagoonKit
@testable import LagoonServer

/// What one unreadable `advice` row does to the queue and to the distribution.
///
/// The `advice` table keeps its enums as plain TEXT with no CHECK
/// constraint, so a row can hold a value this build does not know: it was
/// written by a build that knew an action this one does not, or the value
/// was mangled on disk. Such a row cannot be shown — `AdviceRecord` has no
/// way to carry an unknown action — but it must not take the rest of the
/// queue down with it.
///
/// These tests pin behaviour, not intent. The store's own comment used to
/// say "skipping is the honest answer" while the code threw, and the
/// distribution's comment said unknown categories were skipped while the
/// code counted them as "other". Both comments were describing a program
/// nobody had.
final class AdviceStoreBadRowTests: XCTestCase {
    private func makeAccount() -> Account {
        Account(
            id: UUID(),
            provider: .qq,
            oauthUser: "badrow-\(UUID().uuidString)",
            email: "badrow-\(UUID().uuidString)@qq.com",
            credentials: nil
        )
    }

    private func seedAccount(_ account: Account, db: LagoonDB) async throws {
        try await AccountStore.upsert(
            account,
            credentials: try CredentialVault.seal(
                .imap(username: account.email, authCode: "auth-code")
            ),
            db: db
        )
    }

    private func seedMessage(_ remoteId: String, accountId: UUID, db: LagoonDB) async throws {
        try await MessageStore.upsert(
            MessageHeader(
                id: UUID(),
                accountId: accountId,
                remoteId: remoteId,
                threadId: "t-\(remoteId)",
                fromAddress: "sender@example.com",
                fromName: "Sender",
                subject: "Subject",
                snippet: "snippet",
                receivedAt: Date(),
                isRead: false,
                isArchived: false
            ),
            db: db
        )
    }

    /// Writes one suggestion through the store, the way the product does.
    private func seedAdvice(
        remoteId: String,
        accountId: UUID,
        action: AdvisedAction,
        category: ContentCategory?,
        decision: AdviceDecision = .pending,
        db: LagoonDB
    ) async throws {
        try await seedMessage(remoteId, accountId: accountId, db: db)
        // The await happens first and the unwrap second: `XCTUnwrap` takes an
        // autoclosure, and an autoclosure cannot be async -- awaiting inside it
        // is a compile error, not a runtime one.
        let upserted = try await AdviceStore.upsert(
            accountId: accountId,
            remoteId: remoteId,
            advice: Advice(action: action, category: category, confidence: .medium),
            source: .ai,
            model: "stub-model",
            db: db
        )
        let record = try XCTUnwrap(upserted)
        if decision != .pending {
            let updated = try await AdviceStore.setDecision(
                id: record.id, accountId: accountId, decision: decision, db: db
            )
            XCTAssertTrue(updated)
        }
    }

    /// Writes one suggestion straight into SQLite, bypassing the store.
    ///
    /// The store only ever writes enum values it knows, so a row with an
    /// unknown one cannot be staged through the API — it is what a row from
    /// another build (or a corrupted one) looks like. SQL is the only way to
    /// put one there.
    private func insertRawAdvice(
        remoteId: String,
        accountId: UUID,
        action: String,
        category: String? = nil,
        confidence: String = "medium",
        source: String = "heuristic",
        decision: String = "pending",
        db: LagoonDB
    ) async throws {
        try await seedMessage(remoteId, accountId: accountId, db: db)
        try db.write { raw in
            try raw.execute(
                sql: """
                    INSERT INTO advice (
                        account_id, remote_id, action, category, confidence, source, decision
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    accountId, remoteId, action, category, confidence, source, decision,
                ]
            )
        }
    }

    /// Runs `body` against a fresh store, with a token key in place.
    private func withStore(
        _ body: (LagoonDB) async throws -> Void
    ) async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            try await TestDatabase.withConnection { conn in
                try await body(conn)
            }
        }
    }

    // MARK: - The queue

    /// One unreadable row must not take the queue with it.
    ///
    /// The queue is the surface the user opens; a single suggestion this
    /// build cannot parse is a skipped suggestion, not a failed request.
    func test_list_skipsUnreadableRowsInsteadOfFailingTheQueue() async throws {
        let account = makeAccount()
        try await withStore { conn in
            try await seedAccount(account, db: conn)
            try await seedAdvice(
                remoteId: "good", accountId: account.id, action: .archive, category: .newsletter, db: conn
            )
            try await insertRawAdvice(
                remoteId: "bad", accountId: account.id, action: "not-a-real-action", db: conn
            )

            let rows = try await AdviceStore.list(
                accountId: account.id, filter: .all, limit: 50, db: conn
            )

            XCTAssertEqual(rows.count, 1, "the readable row must survive")
            XCTAssertEqual(rows.first?.remoteId, "good")
        }
    }

    /// The same rule for the batched read the feed uses.
    func test_byRemoteIds_skipsUnreadableRows() async throws {
        let account = makeAccount()
        try await withStore { conn in
            try await seedAccount(account, db: conn)
            try await seedAdvice(
                remoteId: "good", accountId: account.id, action: .archive, category: .newsletter, db: conn
            )
            try await insertRawAdvice(
                remoteId: "bad", accountId: account.id, action: "not-a-real-action", db: conn
            )

            let found = try await AdviceStore.byRemoteIds(
                ["good", "bad"], accountId: account.id, db: conn
            )

            XCTAssertEqual(found.count, 1, "only the readable row comes back")
            XCTAssertNotNil(found["good"])
            XCTAssertNil(found["bad"])
        }
    }

    // MARK: - The distribution

    /// A row the distribution cannot read must not be counted.
    ///
    /// The count is what the classifier prompt learns from: it says what the
    /// user actually did. Counting a row that could not be read is a number
    /// the user never produced.
    func test_acceptedStats_excludesRowsWithAnUnreadableAction() async throws {
        let account = makeAccount()
        try await withStore { conn in
            try await seedAccount(account, db: conn)
            try await seedAdvice(
                remoteId: "good", accountId: account.id, action: .archive, category: .newsletter,
                decision: .accepted, db: conn
            )
            try await insertRawAdvice(
                remoteId: "bad", accountId: account.id, action: "not-a-real-action",
                category: "newsletter", decision: "accepted", db: conn
            )

            let stats = try await AdviceStore.acceptedStats(
                accountId: account.id, limit: 5, db: conn
            )

            XCTAssertEqual(stats.count, 1, "the unreadable row must not become an entry")
            XCTAssertEqual(stats.first?.category, .newsletter)
            XCTAssertEqual(stats.first?.action, .archive)
            XCTAssertEqual(stats.first?.count, 1, "the unreadable row must not be counted")
        }
    }

    /// The same rule when the unreadable part is the confidence.
    ///
    /// This row shares its `(category, action)` shape with a good one, so a
    /// count taken before the row is checked would quietly include it.
    func test_acceptedStats_excludesRowsWithAnUnreadableConfidence() async throws {
        let account = makeAccount()
        try await withStore { conn in
            try await seedAccount(account, db: conn)
            try await seedAdvice(
                remoteId: "good", accountId: account.id, action: .archive, category: .newsletter,
                decision: .accepted, db: conn
            )
            try await insertRawAdvice(
                remoteId: "bad", accountId: account.id, action: "archive", category: "newsletter",
                confidence: "not-a-confidence", decision: "accepted", db: conn
            )

            let stats = try await AdviceStore.acceptedStats(
                accountId: account.id, limit: 5, db: conn
            )

            XCTAssertEqual(stats.count, 1)
            XCTAssertEqual(stats.first?.count, 1, "the unreadable row must not be counted")
        }
    }

    /// A category this build does not know is not "no category".
    ///
    /// Counting it as "other" would teach the model a preference nobody
    /// expressed: the row says something about a category that no longer
    /// exists in this build, and lumping it into the uncategorised bucket
    /// invents a shape.
    func test_acceptedStats_skipsRowsWithAnUnknownCategory() async throws {
        let account = makeAccount()
        try await withStore { conn in
            try await seedAccount(account, db: conn)
            try await seedAdvice(
                remoteId: "good", accountId: account.id, action: .archive, category: .newsletter,
                decision: .accepted, db: conn
            )
            try await insertRawAdvice(
                remoteId: "bad", accountId: account.id, action: "archive", category: "not-a-real-category",
                decision: "accepted", db: conn
            )

            let stats = try await AdviceStore.acceptedStats(
                accountId: account.id, limit: 5, db: conn
            )

            XCTAssertEqual(stats.count, 1, "an unknown category must not become an 'other' entry")
            XCTAssertEqual(stats.first?.category, .newsletter)
            XCTAssertEqual(stats.first?.count, 1)
        }
    }

    // MARK: - The route

    /// A skipped row is reported, not swallowed.
    ///
    /// A suggestion that disappears from the queue without a word is
    /// indistinguishable from one that was never written, and that
    /// difference is exactly what is needed when a suggestion goes missing.
    func test_list_reportsSkippedRowsInsteadOfSwallowingThem() async throws {
        let account = makeAccount()
        try await withStore { conn in
            try await seedAccount(account, db: conn)
            try await seedAdvice(
                remoteId: "good", accountId: account.id, action: .archive, category: .newsletter, db: conn
            )
            try await insertRawAdvice(
                remoteId: "bad", accountId: account.id, action: "not-a-real-action", db: conn
            )

            let (logger, log) = Logger.recording(label: "advice-bad-row-tests")
            let rows = try await AdviceStore.list(
                accountId: account.id, filter: .all, limit: 50, db: conn, logger: logger
            )

            XCTAssertEqual(rows.count, 1)
            XCTAssertTrue(
                log.messages.contains("advice.rowUnreadable"),
                "a skipped row must be recorded, not swallowed: \(log.messages)"
            )
        }
    }

    /// The distribution reports its skips too — it is the one reader that
    /// counts rows, so a row it dropped is a number the user never produced.
    func test_acceptedStats_reportsSkippedRowsInsteadOfSwallowingThem() async throws {
        let account = makeAccount()
        try await withStore { conn in
            try await seedAccount(account, db: conn)
            try await seedAdvice(
                remoteId: "good", accountId: account.id, action: .archive, category: .newsletter,
                decision: .accepted, db: conn
            )
            try await insertRawAdvice(
                remoteId: "bad", accountId: account.id, action: "not-a-real-action",
                category: "newsletter", decision: "accepted", db: conn
            )

            let (logger, log) = Logger.recording(label: "advice-bad-row-tests")
            let stats = try await AdviceStore.acceptedStats(
                accountId: account.id, limit: 5, db: conn, logger: logger
            )

            XCTAssertEqual(stats.count, 1)
            XCTAssertTrue(
                log.messages.contains("advice.rowUnreadable"),
                "a skipped row must be recorded, not swallowed: \(log.messages)"
            )
        }
    }

    /// The queue over HTTP: one unreadable row, and the user still gets a queue.
    func test_adviceRoute_servesTheQueueWhenOneRowIsUnreadable() async throws {
        let account = makeAccount()
        try await withStore { conn in
            try await seedAccount(account, db: conn)
            try await seedAdvice(
                remoteId: "good", accountId: account.id, action: .archive, category: .newsletter, db: conn
            )
            try await insertRawAdvice(
                remoteId: "bad", accountId: account.id, action: "not-a-real-action", db: conn
            )

            let router = Router()
            AdviceRoutes.register(on: router, db: conn, logger: Logger(label: "bad-row-tests"))
            let app = Application(router: router)
            let uri = "/api/advice?accountId=\(account.id.uuidString)"
            try await app.test(.router) { client in
                try await client.execute(uri: uri, method: .get) { response in
                    XCTAssertEqual(response.status, .ok, "one bad row must not 500 the queue")
                    let body = String(decoding: response.body.readableBytesView, as: UTF8.self)
                    XCTAssertTrue(body.contains("good"), "the readable row must reach the wire")
                    XCTAssertFalse(body.contains("not-a-real-action"))
                }
            }
        }
    }
}
