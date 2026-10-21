import XCTest
import Foundation
import Logging
import GRDB
import Hummingbird
import HummingbirdTesting
@testable import LagoonKit
@testable import LagoonServer

/// P1-08, server half: the accepted `(category, action)` distribution.
///
/// `AdviceDecision.accepted` was never written by the client, so the
/// learning loop the constitution describes (Phase 4) had nothing to read.
/// Now that the client writes it, the server has to *read* it back — this
/// query is the read side, and its output is what the classifier prompt
/// carries as a few-shot hint.
///
/// The properties that matter:
///
/// * only `accepted` rows count (`dismissed` is the opposite signal and
///   `pending` is no signal at all),
/// * the distribution is scoped to one account,
/// * the result is bounded and ordered by frequency, because it feeds a
///   prompt and a prompt that grows with the user's history is a cost
///   problem.
final class AcceptedAdviceStatsTests: XCTestCase {
    private func makeAccount() -> Account {
        Account(
            id: UUID(),
            provider: .qq,
            oauthUser: "stats-\(UUID().uuidString)",
            email: "stats-\(UUID().uuidString)@qq.com",
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

    /// Writes one suggestion and puts it in the given state.
    @discardableResult
    private func seedAdvice(
        _ remoteId: String,
        accountId: UUID,
        action: AdvisedAction,
        category: ContentCategory?,
        decision: AdviceDecision,
        db: LagoonDB
    ) async throws -> AdviceRecord {
        try await seedMessage(remoteId, accountId: accountId, db: db)
        let stored = try await AdviceStore.upsert(
            accountId: accountId,
            remoteId: remoteId,
            advice: Advice(action: action, category: category, confidence: .medium),
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
        return record
    }

    /// Runs `body` against a fresh store, with a token key in place.
    ///
    /// The key is what `AccountStore.upsert` needs to seal the credential
    /// blob; without it the account never lands and the test fails on
    /// "missingKey" instead of on the thing it is about.
    private func withStore(
        _ body: (LagoonDB) async throws -> Void
    ) async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            try await TestDatabase.withConnection { conn in
                try await body(conn)
            }
        }
    }

    // MARK: - The distribution

    /// The distribution counts what the user acted on, grouped by
    /// `(category, action)`.
    func test_acceptedStats_countsByCategoryAndAction() async throws {
        let account = makeAccount()
        try await withStore { conn in
            try await seedAccount(account, db: conn)
            try await seedAdvice(
                "m1", accountId: account.id, action: .archive, category: .newsletter,
                decision: .accepted, db: conn
            )
            try await seedAdvice(
                "m2", accountId: account.id, action: .archive, category: .newsletter,
                decision: .accepted, db: conn
            )
            try await seedAdvice(
                "m3", accountId: account.id, action: .unsubscribe, category: .marketing,
                decision: .accepted, db: conn
            )

            let stats = try await AdviceStore.acceptedStats(
                accountId: account.id, limit: 5, db: conn
            )

            XCTAssertEqual(stats.count, 2, "two distinct (category, action) pairs")
            let newsletter = try XCTUnwrap(
                stats.first { $0.category == .newsletter && $0.action == .archive }
            )
            XCTAssertEqual(newsletter.count, 2, "both newsletter archives must be counted")
            let marketing = try XCTUnwrap(
                stats.first { $0.category == .marketing && $0.action == .unsubscribe }
            )
            XCTAssertEqual(marketing.count, 1)
        }
    }

    /// Only `accepted` counts.
    ///
    /// A dismissed suggestion is the user saying "no" and a pending one is
    /// silence. Counting either would make the distribution say something the
    /// user never said — and the whole point of the loop is that it says
    /// what the user *did*.
    func test_acceptedStats_ignoresDismissedAndPending() async throws {
        let account = makeAccount()
        try await withStore { conn in
            try await seedAccount(account, db: conn)
            try await seedAdvice(
                "accepted", accountId: account.id, action: .archive, category: .newsletter,
                decision: .accepted, db: conn
            )
            try await seedAdvice(
                "dismissed", accountId: account.id, action: .archive, category: .newsletter,
                decision: .dismissed, db: conn
            )
            try await seedAdvice(
                "pending", accountId: account.id, action: .archive, category: .newsletter,
                decision: .pending, db: conn
            )

            let stats = try await AdviceStore.acceptedStats(
                accountId: account.id, limit: 5, db: conn
            )
            XCTAssertEqual(stats.count, 1)
            XCTAssertEqual(stats.first?.count, 1, "only the accepted row may count")
        }
    }

    /// The distribution is one account's, not the whole install's.
    func test_acceptedStats_areScopedToTheAccount() async throws {
        let account = makeAccount()
        let other = makeAccount()
        try await withStore { conn in
            try await seedAccount(account, db: conn)
            try await seedAccount(other, db: conn)
            try await seedAdvice(
                "mine", accountId: account.id, action: .archive, category: .newsletter,
                decision: .accepted, db: conn
            )
            try await seedAdvice(
                "theirs", accountId: other.id, action: .delete, category: .spam,
                decision: .accepted, db: conn
            )

            let stats = try await AdviceStore.acceptedStats(
                accountId: account.id, limit: 5, db: conn
            )
            XCTAssertEqual(stats.count, 1)
            XCTAssertEqual(stats.first?.action, .archive)
            XCTAssertEqual(stats.first?.category, .newsletter)
        }
    }

    /// The result is bounded, and the most frequent pairs come first.
    ///
    /// The bound is not a nicety: this list is spliced into a classifier
    /// prompt, and a prompt that grows with the user's history is a cost
    /// problem. The order matters because a truncated list must keep the
    /// pairs that actually describe the user.
    func test_acceptedStats_areBoundedAndOrderedByFrequency() async throws {
        let account = makeAccount()
        try await withStore { conn in
            try await seedAccount(account, db: conn)
            // Two distinct pairs: one hit four times, one hit once.
            for index in 0..<4 {
                try await seedAdvice(
                    "frequent-\(index)", accountId: account.id, action: .archive,
                    category: .newsletter, decision: .accepted, db: conn
                )
            }
            try await seedAdvice(
                "rare", accountId: account.id, action: .delete, category: .spam,
                decision: .accepted, db: conn
            )

            let stats = try await AdviceStore.acceptedStats(
                accountId: account.id, limit: 1, db: conn
            )
            XCTAssertEqual(stats.count, 1, "the result must respect the limit")
            XCTAssertEqual(stats.first?.count, 4, "the most frequent pair must survive the cut")
            XCTAssertEqual(stats.first?.action, .archive)
        }
    }

    /// A suggestion with no category still counts — under `other`.
    ///
    /// The shape is still a fact about the user ("you acted on this kind of
    /// suggestion"), and dropping it would lose the signal for exactly the
    /// rows the classifier was least sure about.
    func test_acceptedStats_countSuggestionsWithoutACategory() async throws {
        let account = makeAccount()
        try await withStore { conn in
            try await seedAccount(account, db: conn)
            try await seedAdvice(
                "no-category", accountId: account.id, action: .archive, category: nil,
                decision: .accepted, db: conn
            )

            let stats = try await AdviceStore.acceptedStats(
                accountId: account.id, limit: 5, db: conn
            )
            XCTAssertEqual(stats.count, 1)
            XCTAssertNil(stats.first?.category)
            XCTAssertEqual(stats.first?.action, .archive)
            XCTAssertEqual(stats.first?.count, 1)
        }
    }

    /// An account that never acted on a suggestion has an empty
    /// distribution — and that is a normal state, not a failure.
    func test_acceptedStats_areEmptyWithoutAnyAcceptance() async throws {
        let account = makeAccount()
        try await withStore { conn in
            try await seedAccount(account, db: conn)
            try await seedAdvice(
                "pending", accountId: account.id, action: .archive, category: .newsletter,
                decision: .pending, db: conn
            )

            let stats = try await AdviceStore.acceptedStats(
                accountId: account.id, limit: 5, db: conn
            )
            XCTAssertTrue(stats.isEmpty)
        }
    }

    // MARK: - The route

    /// The distribution is also readable over HTTP, so the signal can be
    /// audited rather than being invisible inside the prompt.
    func test_acceptedStatsRoute_returnsTheDistribution() async throws {
        let account = makeAccount()
        try await withStore { conn in
            try await seedAccount(account, db: conn)
            try await seedAdvice(
                "m1", accountId: account.id, action: .archive, category: .newsletter,
                decision: .accepted, db: conn
            )

            let router = Router()
            AdviceRoutes.register(on: router, db: conn, logger: Logger(label: "stats-tests"))
            let app = Application(router: router)
            let uri = "/api/advice/accepted-stats?accountId=\(account.id.uuidString)"
            try await app.test(.router) { client in
                try await client.execute(uri: uri, method: .get) { response in
                    XCTAssertEqual(response.status, .ok)
                    let body = String(decoding: response.body.readableBytesView, as: UTF8.self)
                    XCTAssertTrue(body.contains("newsletter"), "the category must reach the wire: \(body)")
                    XCTAssertTrue(body.contains("archive"), "the action must reach the wire: \(body)")
                }
            }
        }
    }

    /// An unknown account is a 404, not an empty distribution — an empty
    /// list would be indistinguishable from "the user has never accepted
    /// anything", which is a different fact.
    func test_acceptedStatsRoute_rejectsAnUnknownAccount() async throws {
        try await withStore { conn in
            let router = Router()
            AdviceRoutes.register(on: router, db: conn, logger: Logger(label: "stats-tests"))
            let app = Application(router: router)
            let uri = "/api/advice/accepted-stats?accountId=\(UUID().uuidString)"
            try await app.test(.router) { client in
                try await client.execute(uri: uri, method: .get) { response in
                    XCTAssertEqual(response.status, .notFound)
                }
            }
        }
    }

    /// A malformed account id is a 400 — the same rule every other advice
    /// route follows.
    func test_acceptedStatsRoute_rejectsAMissingAccountId() async throws {
        try await withStore { conn in
            let router = Router()
            AdviceRoutes.register(on: router, db: conn, logger: Logger(label: "stats-tests"))
            let app = Application(router: router)
            try await app.test(.router) { client in
                try await client.execute(uri: "/api/advice/accepted-stats", method: .get) { response in
                    XCTAssertEqual(response.status, .badRequest)
                }
            }
        }
    }
}
