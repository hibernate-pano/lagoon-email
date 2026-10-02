import XCTest
import Foundation
import Logging
import Hummingbird
import NIOCore
import GRDB
@testable import LagoonKit
@testable import LagoonServer

/// End-to-end for the advice API and for the one place advice is produced:
/// the briefing classifier pass.
final class AdviceRouteTests: XCTestCase {
    private let logger = Logger(label: "advice-route-tests")

    private func makeAccount() -> Account {
        Account(
            id: UUID(),
            provider: .qq,
            oauthUser: "adv-\(UUID().uuidString)",
            email: "adv-\(UUID().uuidString)@qq.com",
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

    private func seedMessage(
        _ remoteId: String,
        accountId: UUID,
        db: LagoonDB,
        isRead: Bool = false
    ) async throws {
        try await MessageStore.upsert(
            MessageHeader(
                id: UUID(),
                accountId: accountId,
                remoteId: remoteId,
                threadId: "t-\(remoteId)",
                fromAddress: "sender@example.com",
                fromName: "Sender",
                subject: "Subject \(remoteId)",
                snippet: "snippet",
                receivedAt: Date(),
                isRead: isRead,
                isArchived: false
            ),
            db: conn(db)
        )
    }

    /// `MessageStore.upsert` wants the handle; this keeps the call sites short.
    private func conn(_ db: LagoonDB) -> LagoonDB { db }

    private func adviceRouter(_ db: LagoonDB) -> Router<BasicRequestContext> {
        let router = Router()
        AdviceRoutes.register(on: router, db: db, logger: self.logger)
        return router
    }

    private func iso8601() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // MARK: - GET /api/advice

    /// The queue defaults to pending suggestions and carries the provenance the
    /// audit view needs: which model, or that there was none.
    func test_getAdvice_returnsThePendingQueueWithProvenance() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await seedMessage("m1", accountId: account.id, db: conn)
                _ = try await AdviceStore.upsert(
                    accountId: account.id,
                    remoteId: "m1",
                    advice: Advice(
                        action: .delete,
                        category: .marketing,
                        confidence: .high,
                        rationale: "促销推广。"
                    ),
                    source: .ai,
                    model: "MiniMax-M3",
                    db: conn
                )
                let app = Application(router: adviceRouter(conn))
                try await app.test(.router) { client in
                    try await client.execute(
                        uri: "/api/advice?accountId=\(account.id.uuidString)",
                        method: .get
                    ) { response in
                        XCTAssertEqual(response.status, .ok)
                        let list = try self.iso8601().decode(
                            AdviceListResponse.self, from: Data(buffer: response.body)
                        )
                        XCTAssertEqual(list.advice.count, 1)
                        let row = try XCTUnwrap(list.advice.first)
                        XCTAssertEqual(row.remoteId, "m1")
                        XCTAssertEqual(row.advice.action, .delete)
                        XCTAssertEqual(row.advice.category, .marketing)
                        XCTAssertEqual(row.advice.rationale, "促销推广。")
                        XCTAssertEqual(row.source, .ai)
                        XCTAssertEqual(row.model, "MiniMax-M3")
                        XCTAssertEqual(row.decision, .pending)
                    }
                }
            }
        }
    }

    /// `decision=any` is the audit view; the default stays the queue.
    func test_getAdvice_decisionAny_includesDecidedRows() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await seedMessage("m1", accountId: account.id, db: conn)
                try await seedMessage("m2", accountId: account.id, db: conn)
                let written = try await AdviceStore.upsert(
                        accountId: account.id,
                        remoteId: "m1",
                        advice: Advice(action: .archive),
                        source: .heuristic,
                        model: nil,
                        db: conn
            )
                let stored = try XCTUnwrap(written)
                _ = try await AdviceStore.upsert(
                    accountId: account.id,
                    remoteId: "m2",
                    advice: Advice(action: .delete),
                    source: .ai,
                    model: "m",
                    db: conn
                )
                _ = try await AdviceStore.setDecision(
                    id: stored.id, accountId: account.id, decision: .dismissed, db: conn
                )

                let app = Application(router: adviceRouter(conn))
                try await app.test(.router) { client in
                    // Default: only the still-pending one.
                    try await client.execute(
                        uri: "/api/advice?accountId=\(account.id.uuidString)",
                        method: .get
                    ) { response in
                        let list = try self.iso8601().decode(
                            AdviceListResponse.self, from: Data(buffer: response.body)
                        )
                        XCTAssertEqual(list.advice.map(\.remoteId), ["m2"])
                    }
                    // Any: both, with the verdict visible.
                    try await client.execute(
                        uri: "/api/advice?accountId=\(account.id.uuidString)&decision=any",
                        method: .get
                    ) { response in
                        let list = try self.iso8601().decode(
                            AdviceListResponse.self, from: Data(buffer: response.body)
                        )
                        XCTAssertEqual(Set(list.advice.map(\.remoteId)), ["m1", "m2"])
                        let dismissed = try XCTUnwrap(list.advice.first { $0.remoteId == "m1" })
                        XCTAssertEqual(dismissed.decision, .dismissed)
                        XCTAssertNotNil(dismissed.decidedAt)
                    }
                }
            }
        }
    }

    /// Malformed and unknown input answers 400 rather than an empty 200, so a
    /// client bug cannot masquerade as "nothing to show".
    func test_getAdvice_rejectsBadInput() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            try await TestDatabase.withConnection { conn in
                let account = makeAccount()
                try await seed(account, db: conn)
                let app = Application(router: adviceRouter(conn))
                try await app.test(.router) { client in
                    let cases: [(String, HTTPResponse.Status)] = [
                        ("/api/advice", .badRequest),
                        ("/api/advice?accountId=not-a-uuid", .badRequest),
                        ("/api/advice?accountId=\(account.id.uuidString)&decision=maybe", .badRequest),
                        ("/api/advice?accountId=\(UUID().uuidString)", .notFound),
                    ]
                    for (uri, expected) in cases {
                        try await client.execute(uri: uri, method: .get) { response in
                            XCTAssertEqual(response.status, expected, "for \(uri)")
                        }
                    }
                }
            }
        }
    }

    // MARK: - POST /api/advice/{id}/decision

    func test_postDecision_recordsTheVerdictAndIsIdempotent() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await seedMessage("m1", accountId: account.id, db: conn)
                let written = try await AdviceStore.upsert(
                        accountId: account.id,
                        remoteId: "m1",
                        advice: Advice(action: .archive),
                        source: .heuristic,
                        model: nil,
                        db: conn
            )
                let stored = try XCTUnwrap(written)
                let app = Application(router: adviceRouter(conn))
                let uri = "/api/advice/\(stored.id)/decision?accountId=\(account.id.uuidString)"
                try await app.test(.router) { client in
                    for decision in ["accepted", "dismissed", "pending"] {
                        try await client.execute(
                            uri: uri,
                            method: .post,
                            body: ByteBuffer(string: #"{"decision":"\#(decision)"}"#)
                        ) { response in
                            XCTAssertEqual(response.status, .ok, "for \(decision)")
                        }
                    }
                }
                let after = try await AdviceStore.find(remoteId: "m1", accountId: account.id, db: conn)
                XCTAssertEqual(after?.decision, .pending)
                XCTAssertNil(after?.decidedAt)
            }
        }
    }

    /// A verdict is the only write this API has, and it writes no mail.
    func test_postDecision_doesNotTouchTheMessage() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await seedMessage("m1", accountId: account.id, db: conn)
                let written = try await AdviceStore.upsert(
                        accountId: account.id,
                        remoteId: "m1",
                        advice: Advice(action: .delete, confidence: .high),
                        source: .ai,
                        model: "m",
                        db: conn
            )
                let stored = try XCTUnwrap(written)
                let app = Application(router: adviceRouter(conn))
                try await app.test(.router) { client in
                    try await client.execute(
                        uri: "/api/advice/\(stored.id)/decision?accountId=\(account.id.uuidString)",
                        method: .post,
                        body: ByteBuffer(string: #"{"decision":"accepted"}"#)
                    ) { response in
                        XCTAssertEqual(response.status, .ok)
                    }
                }
                // Accepting a "delete this" suggestion must not delete anything.
                let message = try await MessageStore.find(
                    remoteId: "m1", accountId: account.id, db: conn
                )
                XCTAssertEqual(message?.isDeleted, false, "a verdict is not a mailbox action")
                XCTAssertEqual(message?.isArchived, false)
                let actions = try await AIActionStore.recent(accountId: account.id, db: conn)
                XCTAssertTrue(actions.isEmpty, "a verdict must write no action audit row")
            }
        }
    }

    func test_postDecision_rejectsBadInputAndUnknownIds() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                let app = Application(router: adviceRouter(conn))
                try await app.test(.router) { client in
                    let base = account.id.uuidString
                    let cases: [(String, String?, HTTPResponse.Status)] = [
                        ("/api/advice/1/decision", nil, .badRequest),
                        ("/api/advice/1/decision?accountId=nope", #"{"decision":"accepted"}"#, .badRequest),
                        ("/api/advice/x/decision?accountId=\(base)", #"{"decision":"accepted"}"#, .badRequest),
                        ("/api/advice/1/decision?accountId=\(base)", #"{"decision":"maybe"}"#, .badRequest),
                        ("/api/advice/1/decision?accountId=\(base)", "not json", .badRequest),
                        ("/api/advice/1/decision?accountId=\(base)", #"{"decision":"accepted"}"#, .notFound),
                    ]
                    for (uri, body, expected) in cases {
                        try await client.execute(
                            uri: uri,
                            method: .post,
                            body: body.map { ByteBuffer(string: $0) }
                        ) { response in
                            XCTAssertEqual(response.status, expected, "for \(uri) body=\(body ?? "nil")")
                        }
                    }
                }
            }
        }
    }
}

/// The briefing pass is the only producer of advice, and it runs detached from
/// the request. These pin the two properties that follow from that: advice
/// lands, and a storage problem never costs the user their inbox.
extension AdviceRouteTests {
    private struct AdviceClassifier: BriefingClassifying {
        let outcomes: [String: ClassificationOutcome]
        func classify(
            _ messages: [MessageHeader],
            accountEmail: String,
            language: String?
        ) async throws -> [String: ClassificationOutcome] { outcomes }
    }

    private func briefingRouter(_ db: LagoonDB, classifier: any BriefingClassifying) -> Router<BasicRequestContext> {
        let router = Router()
        BriefingRoutes.register(
            on: router, db: db, logger: self.logger,
            classifier: classifier,
            classificationMode: .synchronous
        )
        return router
    }

    /// The classifier's advice half becomes a row, with the model stamped on it.
    /// Without this the whole feature is a type that nothing ever fills.
    func test_briefingPass_persistsTheAdviceItReceived() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await seedMessage("m1", accountId: account.id, db: conn)
                try await seedMessage("m2", accountId: account.id, db: conn)
                let classifier = AdviceClassifier(outcomes: [
                    "m1": ClassificationOutcome(
                        group: .subscriptionNoise,
                        advice: Advice(
                            action: .unsubscribe,
                            category: .marketing,
                            confidence: .high,
                            rationale: "每日促销。"
                        ),
                        model: "MiniMax-M3"
                    ),
                    // Group-only: a model that gave no advice must still group,
                    // and must not create an advice row.
                    "m2": ClassificationOutcome(group: .needsReply),
                ])
                let app = Application(router: briefingRouter(conn, classifier: classifier))

                try await app.test(.router) { client in
                    try await client.execute(
                        uri: "/api/briefing?accountId=\(account.id.uuidString)",
                        method: .get
                    ) { response in
                        XCTAssertEqual(response.status, .ok)
                    }
                }

                let queue = try await AdviceStore.list(
                    accountId: account.id, filter: .pending, db: conn
                )
                XCTAssertEqual(queue.map(\.remoteId), ["m1"], "only advised messages get rows")
                let row = try XCTUnwrap(queue.first)
                XCTAssertEqual(row.advice.action, .unsubscribe)
                XCTAssertEqual(row.advice.category, .marketing)
                XCTAssertEqual(row.advice.rationale, "每日促销。")
                XCTAssertEqual(row.model, "MiniMax-M3", "provenance survives the write")

                // And the mail is untouched by any of it.
                for id in ["m1", "m2"] {
                    let message = try await MessageStore.find(
                        remoteId: id, accountId: account.id, db: conn
                    )
                    XCTAssertEqual(message?.isArchived, false)
                    XCTAssertEqual(message?.isDeleted, false)
                    XCTAssertEqual(message?.isRead, false)
                }
                let actions = try await AIActionStore.recent(accountId: account.id, db: conn)
                XCTAssertTrue(actions.isEmpty, "advice must write no action audit rows")
            }
        }
    }

    /// A classifier that fails must not take the feed with it, and must not
    /// write advice either. The feed is the product; a suggestion is a nicety.
    func test_briefingPass_survivesAThrowingClassifier() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await seedMessage("m1", accountId: account.id, db: conn)
                let classifier = AdviceClassifier(outcomes: [:])
                let router = Router()
                BriefingRoutes.register(
                    on: router, db: conn, logger: self.logger,
                    classifier: ThrowingClassifier(),
                    classificationMode: .synchronous
                )
                _ = classifier
                let app = Application(router: router)

                try await app.test(.router) { client in
                    try await client.execute(
                        uri: "/api/briefing?accountId=\(account.id.uuidString)",
                        method: .get
                    ) { response in
                        XCTAssertEqual(
                            response.status, .ok,
                            "a classifier outage must never 500 the whole feed"
                        )
                    }
                }
                let queue = try await AdviceStore.list(
                    accountId: account.id, filter: .all, db: conn
                )
                XCTAssertTrue(queue.isEmpty, "a failed pass writes no advice")
            }
        }
    }

    private struct ThrowingClassifier: BriefingClassifying {
        struct Boom: Error {}
        func classify(
            _ messages: [MessageHeader],
            accountEmail: String,
            language: String?
        ) async throws -> [String: ClassificationOutcome] { throw Boom() }
    }
}
