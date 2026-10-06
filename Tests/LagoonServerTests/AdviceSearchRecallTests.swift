import XCTest
import Foundation
import Logging
import Hummingbird
import NIOCore
import GRDB
@testable import LagoonKit
@testable import LagoonServer

/// The `advice` arm of search recall.
///
/// ## Why this file exists
///
/// Lagoon has already paid a model to classify every message it has seen, and
/// stored the verdict in *columns* rather than prose. Matching on those columns
/// means "show me the marketing" works without any extra inference — which is
/// the whole promise of spending AI at all. These tests pin both halves of that
/// claim: the structured fields are recalled, and the model's own sentence is
/// not.
final class AdviceSearchRecallTests: XCTestCase {
    private let logger = Logger(label: "advice-search-tests")

    private func makeAccount() -> Account {
        Account(
            id: UUID(),
            provider: .qq,
            oauthUser: "sr-\(UUID().uuidString)",
            email: "sr-\(UUID().uuidString)@qq.com",
            credentials: nil
        )
    }

    private func seed(_ account: Account, db: LagoonDB) async throws {
        try await AccountStore.upsert(
            account,
            credentials: try CredentialVault.seal(
                .imap(username: account.email, authCode: "code")
            ),
            db: db
        )
    }

    @discardableResult
    private func seedMessage(
        _ remoteId: String,
        accountId: UUID,
        db: LagoonDB,
        subject: String,
        snippet: String = "snippet"
    ) async throws -> UUID {
        let id = UUID()
        try await MessageStore.upsert(
            MessageHeader(
                id: id,
                accountId: accountId,
                remoteId: remoteId,
                threadId: "t-\(remoteId)",
                fromAddress: "sender@example.com",
                fromName: "Sender",
                subject: subject,
                snippet: snippet,
                receivedAt: Date(),
                isRead: true,
                isArchived: false
            ),
            db: db
        )
        return id
    }

    private func search(_ accountId: UUID, q: String, db: LagoonDB) async throws -> [MessageHeader] {
        let router = Router<BasicRequestContext>()
        SearchRoutes.register(on: router, db: db, logger: self.logger)
        let app = Application(router: router)
        var out: [MessageHeader] = []
        try await app.test(.router) { client in
            let escaped = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
            try await client.execute(
                uri: "/api/search?accountId=\(accountId.uuidString)&q=\(escaped)",
                method: .get
            ) { response in
                XCTAssertEqual(response.status, .ok)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let decoded = try decoder.decode(
                    SearchResponse.self,
                    from: Data(response.body.readableBytesView)
                )
                out = decoded.results
            }
        }
        return out
    }

    /// The headline capability: a message whose text never contains the word is
    /// still found by the category the AI assigned it.
    ///
    /// This is what makes the feature worth having. The mail says "本周六专场",
    /// the user searches "marketing", and the row comes back — because a model
    /// already read it and concluded exactly that.
    func test_categoryIsRecalledEvenWhenAbsentFromTheText() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await seedMessage(
                    "promo", accountId: account.id, db: conn, subject: "本周六专场"
                )
                _ = try await AdviceStore.upsert(
                    accountId: account.id,
                    remoteId: "promo",
                    advice: Advice(action: .archive, category: .marketing, confidence: .high),
                    source: .ai,
                    model: "MiniMax-M3",
                    db: conn
                )
                let hits = try await search(account.id, q: "marketing", db: conn)
                XCTAssertEqual(hits.map(\.remoteId), ["promo"])
            }
        }
    }

    /// The advised action is recalled too, so "which mail did the AI think was
    /// disposable" is answerable.
    func test_actionIsRecalled() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await seedMessage(
                    "a", accountId: account.id, db: conn, subject: "一号邮件"
                )
                _ = try await AdviceStore.upsert(
                    accountId: account.id,
                    remoteId: "a",
                    advice: Advice(action: .unsubscribe, category: .newsletter),
                    source: .heuristic,
                    model: nil,
                    db: conn
                )
                let hits = try await search(account.id, q: "unsubscribe", db: conn)
                XCTAssertEqual(hits.map(\.remoteId), ["a"])
            }
        }
    }

    /// The model's own sentence is deliberately NOT searched.
    ///
    /// `rationale` is prose in whatever language the model was asked to answer
    /// in. A LIKE against it would be accidental translation rather than a real
    /// filter — searching the English word "promotion" would hit a rationale
    /// that happens to contain it, in a UI set to Chinese. Only the enum-shaped
    /// columns participate, so recall stays predictable across languages.
    func test_rationaleIsNotSearched() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await seedMessage(
                    "r", accountId: account.id, db: conn, subject: "无关标题"
                )
                _ = try await AdviceStore.upsert(
                    accountId: account.id,
                    remoteId: "r",
                    advice: Advice(
                        action: .archive,
                        category: .other,
                        rationale: "这是一封促销邮件 promotion sale"
                    ),
                    source: .ai,
                    model: "MiniMax-M3",
                    db: conn
                )
                // The rationale's *category* is `other`, so neither the enum
                // column nor the mail text contains "promotion" — only the
                // excluded rationale prose does.
                let hits = try await search(account.id, q: "promotion", db: conn)
                XCTAssertTrue(
                    hits.isEmpty,
                    "rationale prose must stay out of recall, or recall becomes a translation bug"
                )
            }
        }
    }

    /// Messages with no advice row still search normally.
    ///
    /// The join is a LEFT JOIN precisely so this holds: a mailbox that predates
    /// the advice store, or whose classification never ran, must not silently
    /// become unsearchable.
    func test_messagesWithoutAdviceRemainSearchable() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await seedMessage(
                    "plain", accountId: account.id, db: conn, subject: "发票抬头"
                )
                let hits = try await search(account.id, q: "发票", db: conn)
                XCTAssertEqual(hits.map(\.remoteId), ["plain"])
            }
        }
    }

    /// The join must not fan out rows: a message with advice still appears once.
    ///
    /// `advice` is UNIQUE on (account_id, remote_id), so this holds by schema —
    /// but a search that returned a message twice would be a visible duplicate,
    /// and the schema guarantee is exactly the thing worth asserting.
    func test_aMessageWithAdviceIsReturnedOnce() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await seedMessage(
                    "one", accountId: account.id, db: conn, subject: "重复检查"
                )
                // Upsert twice: the second call replaces the row rather than
                // adding another, which is what "unique identity" means.
                for _ in 0..<2 {
                    _ = try await AdviceStore.upsert(
                        accountId: account.id,
                        remoteId: "one",
                        advice: Advice(action: .archive, category: .work),
                        source: .heuristic,
                        model: nil,
                        db: conn
                    )
                }
                let hits = try await search(account.id, q: "重复检查", db: conn)
                XCTAssertEqual(hits.count, 1, "the advice join must not duplicate rows")
            }
        }
    }

    /// Searching stays a read. A query with advice in it must not promote,
    /// demote, or otherwise touch a message — the panel is for looking, and the
    /// advice row it now joins is not a licence to act (constitution §2 rules 1
    /// and 6).
    func test_searchDoesNotChangeAnyRow() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await seedMessage("m1", accountId: account.id, db: conn, subject: "读我")
                _ = try await AdviceStore.upsert(
                    accountId: account.id,
                    remoteId: "m1",
                    advice: Advice(action: .delete, category: .spam),
                    source: .ai,
                    model: "MiniMax-M3",
                    db: conn
                )
                let before = try await MessageStore.find(
                    remoteId: "m1", accountId: account.id, db: conn
                )
                _ = try await search(account.id, q: "spam", db: conn)
                let after = try await MessageStore.find(
                    remoteId: "m1", accountId: account.id, db: conn
                )
                XCTAssertEqual(before, after)
                // The verdict itself is untouched too.
                let stillPending = try await AdviceStore.list(
                    accountId: account.id, filter: .pending, limit: 10, db: conn
                )
                XCTAssertEqual(stillPending.count, 1)
                XCTAssertEqual(stillPending[0].decision, .pending)
            }
        }
    }
}