import XCTest
import Foundation
import Logging
import GRDB
import Hummingbird
import HummingbirdTesting
@testable import LagoonKit
@testable import LagoonServer

/// The advice table is the one table in the store that is safe to prune, and
/// `AdviceStore.pruneDismissed` is the function that does it.
///
/// It had an implementation and exactly one caller: the test. Production code
/// never called it, so every suggestion the user dismissed stayed in the
/// `advice` table for good, and the table grew with every mail the account
/// received. The briefing is where advice is produced, so it is where the
/// pruning belongs.
final class BriefingAdvicePruningTests: XCTestCase {
    private func makeAccount() -> Account {
        Account(
            id: UUID(),
            provider: .qq,
            oauthUser: "prune-\(UUID().uuidString)",
            email: "prune-\(UUID().uuidString)@qq.com",
            credentials: nil
        )
    }

    private func seedAccount(_ account: Account, db: LagoonDB) async throws {
        // Opaque bytes: nothing in this file decrypts the credential blob, and
        // the briefing route never touches it.
        try await AccountStore.upsert(
            account,
            credentials: Data([1, 2, 3]),
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

    /// Writes one advice row and puts it in the given state.
    private func seedAdvice(
        _ remoteId: String,
        accountId: UUID,
        decision: AdviceDecision,
        createdAt: Date,
        db: LagoonDB
    ) async throws {
        try await seedMessage(remoteId, accountId: accountId, db: db)
        let stored = try await AdviceStore.upsert(
            accountId: accountId,
            remoteId: remoteId,
            advice: Advice(action: .reply, rationale: "r"),
            source: .ai,
            model: "stub-model",
            db: db
        )
        let record = try XCTUnwrap(stored)
        if decision != .pending {
            let updated = try await AdviceStore.setDecision(
                id: record.id, accountId: accountId, decision: decision, db: db
            )
            XCTAssertTrue(updated)
        }
        // `created_at` is the column the pruning window is measured on, and
        // the store writes it with a database default — so the test dates the
        // row itself.
        // `LagoonDB.write` is synchronous — it runs the closure on the
        // calling thread inside a transaction. The `await` that used to be
        // here was doing nothing at all.
        try db.write { raw in
            try raw.execute(
                sql: "UPDATE advice SET created_at = ? WHERE id = ?",
                arguments: [createdAt, record.id]
            )
        }
    }

    private func adviceIds(accountId: UUID, db: LagoonDB) async throws -> [Int64] {
        try db.read { raw in
            try Row.fetchAll(
                raw,
                sql: "SELECT id FROM advice WHERE account_id = ? ORDER BY id",
                arguments: [accountId]
            ).map { $0["id"] }
        }
    }

    private func getBriefing(accountId: UUID, db: LagoonDB) async throws {
        let router = Router()
        BriefingRoutes.register(on: router, db: db, logger: Logger(label: "prune-tests"))
        let app = Application(router: router)
        let uri = "/api/briefing?accountId=\(accountId.uuidString)"
        try await app.test(.router) { client in
            try await client.execute(uri: uri, method: .get) { response in
                XCTAssertEqual(response.status, .ok)
            }
        }
    }

    /// Reading the briefing prunes the dismissed suggestions that have aged
    /// out of the retention window.
    ///
    /// Before the fix, nothing in production ever called `pruneDismissed`, so
    /// this row — and every other dismissed row — stayed forever.
    func test_briefing_prunesDismissedAdviceOlderThanTheWindow() async throws {
        let account = makeAccount()
        try await TestDatabase.withConnection { conn in
            try await seedAccount(account, db: conn)
            let old = Date().addingTimeInterval(
                -Double(BriefingRoutes.dismissedAdviceRetentionDays + 1) * 24 * 60 * 60
            )
            try await seedAdvice(
                "old-dismissed", accountId: account.id, decision: .dismissed,
                createdAt: old, db: conn
            )
            let before = try await adviceIds(accountId: account.id, db: conn)
            XCTAssertEqual(before.count, 1)

            try await getBriefing(accountId: account.id, db: conn)

            let after = try await adviceIds(accountId: account.id, db: conn)
            XCTAssertEqual(
                after.count, 0,
                "a dismissed suggestion past the window is pruned by the briefing"
            )
        }
    }

    /// The pruning is narrow on purpose: only *dismissed* advice that has
    /// aged out goes. A suggestion the user has not answered yet is still on
    /// their desk, and a freshly dismissed one is still what they just said
    /// "no" to — both have to survive.
    func test_briefing_keepsPendingAndRecentlyDismissedAdvice() async throws {
        let account = makeAccount()
        try await TestDatabase.withConnection { conn in
            try await seedAccount(account, db: conn)
            let old = Date().addingTimeInterval(
                -Double(BriefingRoutes.dismissedAdviceRetentionDays + 1) * 24 * 60 * 60
            )
            try await seedAdvice(
                "pending-old", accountId: account.id, decision: .pending,
                createdAt: old, db: conn
            )
            try await seedAdvice(
                "dismissed-new", accountId: account.id, decision: .dismissed,
                createdAt: Date(), db: conn
            )

            try await getBriefing(accountId: account.id, db: conn)

            let remaining = try await adviceIds(accountId: account.id, db: conn)
            XCTAssertEqual(remaining.count, 2, "neither of those may be pruned")
        }
    }

    /// Another account's dismissed advice is none of this account's business.
    func test_briefing_doesNotPruneAnotherAccountsAdvice() async throws {
        let account = makeAccount()
        let other = makeAccount()
        try await TestDatabase.withConnection { conn in
            try await seedAccount(account, db: conn)
            try await seedAccount(other, db: conn)
            let old = Date().addingTimeInterval(
                -Double(BriefingRoutes.dismissedAdviceRetentionDays + 1) * 24 * 60 * 60
            )
            try await seedAdvice(
                "theirs", accountId: other.id, decision: .dismissed,
                createdAt: old, db: conn
            )

            try await getBriefing(accountId: account.id, db: conn)

            let theirs = try await adviceIds(accountId: other.id, db: conn)
            XCTAssertEqual(
                theirs.count, 1,
                "the pruning is scoped to the account the briefing is for"
            )
        }
    }
}
