import Foundation
import Logging
import XCTest
import Hummingbird
import HummingbirdTesting
import NIOCore
import PostgresNIO
@testable import LagoonServer
@testable import LagoonKit

/// End-to-end route tests. `POST /webhook/gmail` needs no database; the
/// `GET /api/accounts` and M1 `/api/briefing` + `/api/messages/*` tests use a
/// guarded test-DB connection injected into the router.
final class RouteTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.reset()
        super.tearDown()
    }
    func test_postWebhookGmail_returns501() async throws {
        let router = Router()
        GmailWebhookRoutes.register(on: router)
        let app = Application(router: router)

        try await app.test(.router) { client in
            try await client.execute(uri: "/webhook/gmail", method: .post) { response in
                XCTAssertEqual(response.status, .notImplemented)
                XCTAssertTrue(
                    String(buffer: response.body).contains("Pub/Sub"),
                    "expected explanatory 501 body"
                )
            }
        }
    }

    func test_getAccounts_emptyTestDatabase_returnsEmptyJSONArray() async throws {
        try await TestDatabase.withConnection { conn in
            // The shared lagoon_test DB is only empty if prior tests cleaned up
            // after themselves; if not, skip rather than weaken the assertion.
            let existing = try await AccountStore.all(db: conn)
            guard existing.isEmpty else {
                throw XCTSkip("test DB has \(existing.count) leftover account row(s); empty-array assertion skipped")
            }

            let router = Router()
            AccountsRoutes.register(on: router, db: conn)
            let app = Application(router: router)

            try await app.test(.router) { client in
                try await client.execute(uri: "/api/accounts", method: .get) { response in
                    XCTAssertEqual(response.status, .ok)
                    XCTAssertEqual(
                        response.headers[.contentType],
                        "application/json; charset=utf-8"
                    )
                    XCTAssertEqual(String(buffer: response.body), "[]")
                }
            }
        }
    }

    func test_getAccounts_returnsInsertedAccountAsConnectedAccount() async throws {
        let oauthUser = "route-\(UUID().uuidString)"
        try await TestDatabase.withConnection(cleanup: { conn in
            try? await TestDatabase.deleteAccount(oauthUser: oauthUser, provider: .gmail, db: conn)
        }) { conn in
            let account = Account(
                id: UUID(),
                provider: .gmail,
                oauthUser: oauthUser,
                email: "route-\(UUID().uuidString)@example.com",
                credentials: nil,
                isActive: true
            )
            let preExistingCount = try await AccountStore.all(db: conn).count
            try await AccountStore.upsert(
                account,
                credentials: Data([1, 2, 3]),
                db: conn
            )

            let router = Router()
            AccountsRoutes.register(on: router, db: conn)
            let app = Application(router: router)

            try await app.test(.router) { client in
                try await client.execute(uri: "/api/accounts", method: .get) { response in
                    XCTAssertEqual(response.status, .ok)
                    XCTAssertEqual(
                        response.headers[.contentType],
                        "application/json; charset=utf-8"
                    )
                    let decoded = try JSONDecoder().decode(
                        [ConnectedAccount].self,
                        from: Data(buffer: response.body)
                    )
                    // Exactly one more element than before the insert, and it
                    // is the inserted account serialized as ConnectedAccount.
                    XCTAssertEqual(decoded.count, preExistingCount + 1)
                    XCTAssertTrue(
                        decoded.contains(ConnectedAccount(
                            id: account.id,
                            provider: .gmail,
                            email: account.email,
                            isActive: true,
                            syncHealth: SyncHealth(status: .ok),
                            capabilities: .unknown
                        )),
                        "response \(decoded) must contain the inserted account"
                    )
                }
            }
        }
    }

    // MARK: - M1 fakes

    private enum RouteTestError: Error { case classifierFailed }

    /// Returns a fixed remoteId → group map. Ids it omits keep the heuristic
    /// grouping (the route only overrides the ids present in the map).
    private struct FakeBriefingClassifier: BriefingClassifying {
        let groups: [String: BriefingGroup]

        func classify(
            _ messages: [MessageHeader],
            accountEmail: String,
            language: String?
        ) async throws -> [String: BriefingGroup] {
            groups
        }
    }

    private struct ThrowingBriefingClassifier: BriefingClassifying {
        func classify(
            _ messages: [MessageHeader],
            accountEmail: String,
            language: String?
        ) async throws -> [String: BriefingGroup] {
            throw RouteTestError.classifierFailed
        }
    }

    private struct FakeSummarizer: MessageSummarizing {
        let summary: String
        let actionItems: [String]
        let provider: String?

        func summarize(_ body: MessageBody, language: String?, accountEmail: String) async throws -> MessageSummary {
            MessageSummary(
                remoteId: body.remoteId,
                summary: summary,
                actionItems: actionItems,
                provider: provider
            )
        }
    }

    // MARK: - M1 helpers

    private static let testLogger = Logger(label: "route-tests")

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: config)
    }

    /// Registers `MessageRoutes` with a URLProtocol-stubbed Gmail client and a
    /// token service pointed at the same guarded test DB. The Gmail client is
    /// only exercised by the `/summary` test; the other message routes touch
    /// the DB alone.
    private func makeMessageRouter(
        db: PostgresConnection,
        summarizer: (any MessageSummarizing)? = nil
    ) -> Router<BasicRequestContext> {
        let session = Self.makeSession()
        let router = Router()
        MessageRoutes.register(
            on: router,
            db: db,
            client: GmailClient(session: session),
            tokens: GmailTokenService(
                db: db,
                oauth: GoogleOAuthClient(
                    clientID: "test-client",
                    clientSecret: "test-secret",
                    redirectURI: "http://127.0.0.1:9999/callback",
                    session: session
                ),
                logger: Self.testLogger
            ),
            logger: Self.testLogger,
            summarizer: summarizer
        )
        return router
    }

    private func makeBriefingRouter(
        db: PostgresConnection,
        classifier: (any BriefingClassifying)? = nil
    ) -> Router<BasicRequestContext> {
        let router = Router()
        BriefingRoutes.register(
            on: router,
            db: db,
            logger: Self.testLogger,
            classifier: classifier
        )
        return router
    }

    /// Message + briefing routes on one router, for tests that mutate state
    /// through a message route and observe it through the feed (pinning).
    private func makeM1Router(
        db: PostgresConnection,
        summarizer: (any MessageSummarizing)? = nil,
        classifier: (any BriefingClassifying)? = nil
    ) -> Router<BasicRequestContext> {
        let router = makeMessageRouter(db: db, summarizer: summarizer)
        BriefingRoutes.register(
            on: router,
            db: db,
            logger: Self.testLogger,
            classifier: classifier
        )
        return router
    }

    private func makeAccount(oauthUser: String, email: String) -> Account {
        Account(
            id: UUID(),
            provider: .gmail,
            oauthUser: oauthUser,
            email: email,
            credentials: nil,
            isActive: true
        )
    }

    private func makeHeader(
        accountId: UUID,
        remoteId: String,
        from: String,
        isRead: Bool = false,
        daysAgo: Double = 0
    ) -> MessageHeader {
        MessageHeader(
            id: UUID(),
            accountId: accountId,
            remoteId: remoteId,
            threadId: "thread-\(remoteId)",
            fromAddress: from,
            fromName: nil,
            subject: "subject \(remoteId)",
            snippet: nil,
            receivedAt: Date().addingTimeInterval(-daysAgo * 24 * 60 * 60),
            isRead: isRead,
            isArchived: false
        )
    }

    /// Row-scoped cleanup: only the account this test created (and its
    /// cascading message_headers / message_pins rows) is removed.
    private func cleanup(accountId: UUID) -> @Sendable (PostgresConnection) async -> Void {
        { conn in
            try? await TestDatabase.deleteMessages(accountId: accountId, db: conn)
            try? await TestDatabase.deleteAccount(id: accountId, db: conn)
        }
    }

    private func seedAccount(
        _ account: Account,
        credentials: Data = Data([1, 2, 3]),
        db: PostgresConnection
    ) async throws {
        try await AccountStore.upsert(
            account,
            credentials: credentials,
            db: db
        )
    }

    /// Server encodes dates ISO-8601; the plain `JSONDecoder()` default cannot
    /// read them.
    private static func iso8601Decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func errorCode(from buffer: ByteBuffer) throws -> String? {
        let object = try JSONSerialization.jsonObject(with: Data(buffer: buffer))
        return (object as? [String: Any])?["error"] as? String
    }

    private static func http(_ url: URL, _ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    }

    /// Minimal Gmail `format=full` payload: one text/plain part plus From /
    /// Subject / To headers, enough for `GmailBodyExtractor.plainText`.
    private static func gmailFullMessageJSON(
        remoteId: String,
        subject: String,
        from: String,
        text: String
    ) -> Data {
        let payload: [String: Any] = [
            "mimeType": "text/plain",
            "headers": [
                ["name": "From", "value": from],
                ["name": "Subject", "value": subject],
                ["name": "To", "value": "me@example.com"],
            ],
            "body": ["data": Data(text.utf8).base64EncodedString()],
        ]
        let message: [String: Any] = [
            "id": remoteId,
            "threadId": "thread-\(remoteId)",
            "internalDate": "1700000000000",
            "payload": payload,
        ]
        return (try? JSONSerialization.data(withJSONObject: message)) ?? Data("{}".utf8)
    }

    /// Every key appearing anywhere in a JSON object/array tree.
    private static func allKeys(_ value: Any) -> [String] {
        if let dict = value as? [String: Any] {
            return Array(dict.keys) + dict.values.flatMap { allKeys($0) }
        }
        if let array = value as? [Any] {
            return array.flatMap { allKeys($0) }
        }
        return []
    }

    // MARK: - GET /api/briefing

    /// The feed is 200 + JSON, and every item lands in the group the
    /// deterministic heuristic classifier assigns (pinned wins, no-reply sender
    /// → subscription noise, sender == owner → awaiting reply, read & >7d →
    /// safe to archive, otherwise needs reply).
    func test_getBriefing_heuristicGrouping_returns200JSON() async throws {
        let oauthUser = "route-\(UUID().uuidString)"
        let account = makeAccount(oauthUser: oauthUser, email: "me-\(UUID().uuidString)@example.com")

        try await TestDatabase.withConnection(cleanup: cleanup(accountId: account.id)) { conn in
            try await seedAccount(account, db: conn)

            let needsReply = makeHeader(accountId: account.id, remoteId: "n-\(UUID())", from: "alice@example.com")
            let subscription = makeHeader(accountId: account.id, remoteId: "s-\(UUID())", from: "no-reply@news.example.com")
            let awaiting = makeHeader(accountId: account.id, remoteId: "a-\(UUID())", from: account.email)
            let archive = makeHeader(
                accountId: account.id,
                remoteId: "r-\(UUID())",
                from: "bob@example.com",
                isRead: true,
                daysAgo: 30
            )
            let pinned = makeHeader(accountId: account.id, remoteId: "p-\(UUID())", from: "carol@example.com")
            for header in [needsReply, subscription, awaiting, archive, pinned] {
                try await MessageStore.upsert(header, db: conn)
            }
            try await MessageStore.setPinned(
                true,
                remoteId: pinned.remoteId,
                accountId: account.id,
                db: conn
            )

            let app = Application(router: makeBriefingRouter(db: conn))
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/api/briefing?accountId=\(account.id.uuidString)",
                    method: .get
                ) { response in
                    XCTAssertEqual(response.status, .ok)
                    XCTAssertEqual(
                        response.headers[.contentType],
                        "application/json; charset=utf-8"
                    )
                    let decoded = try Self.iso8601Decoder().decode(
                        BriefingResponse.self,
                        from: Data(buffer: response.body)
                    )
                    XCTAssertEqual(decoded.items.count, 5)
                    var groups: [String: BriefingGroup] = [:]
                    for item in decoded.items { groups[item.message.remoteId] = item.group }
                    XCTAssertEqual(groups[needsReply.remoteId], .needsReply)
                    XCTAssertEqual(groups[subscription.remoteId], .subscriptionNoise)
                    XCTAssertEqual(groups[awaiting.remoteId], .awaitingReply)
                    XCTAssertEqual(groups[archive.remoteId], .safeToArchive)
                    XCTAssertEqual(groups[pinned.remoteId], .pinned)
                    for item in decoded.items {
                        XCTAssertNotNil(item.reasonCode, "item \(item.message.remoteId) needs a reason code")
                        XCTAssertFalse(item.reasonCode?.isEmpty ?? true)
                    }
                }
            }
        }
    }

    /// An injected `BriefingClassifying` overrides the heuristic only for the
    /// ids it returns; other ids keep the heuristic grouping.
    func test_getBriefing_injectedClassifier_overridesHeuristicForReturnedIds() async throws {
        let account = makeAccount(
            oauthUser: "route-\(UUID().uuidString)",
            email: "me-\(UUID().uuidString)@example.com"
        )

        try await TestDatabase.withConnection(cleanup: cleanup(accountId: account.id)) { conn in
            try await seedAccount(account, db: conn)
            let overridden = makeHeader(
                accountId: account.id,
                remoteId: "o-\(UUID())",
                from: "alice@example.com"
            )
            let heuristicOnly = makeHeader(
                accountId: account.id,
                remoteId: "h-\(UUID())",
                from: "bob@example.com"
            )
            try await MessageStore.upsert(overridden, db: conn)
            try await MessageStore.upsert(heuristicOnly, db: conn)

            let classifier = FakeBriefingClassifier(
                groups: [overridden.remoteId: .subscriptionNoise]
            )
            let app = Application(router: makeBriefingRouter(db: conn, classifier: classifier))
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/api/briefing?accountId=\(account.id.uuidString)",
                    method: .get
                ) { response in
                    XCTAssertEqual(response.status, .ok)
                    let decoded = try Self.iso8601Decoder().decode(
                        BriefingResponse.self,
                        from: Data(buffer: response.body)
                    )
                    let overriddenItem = decoded.items.first {
                        $0.message.remoteId == overridden.remoteId
                    }
                    XCTAssertEqual(overriddenItem?.group, .subscriptionNoise)
                    XCTAssertEqual(overriddenItem?.reasonCode, "ai")
                    let heuristicItem = decoded.items.first {
                        $0.message.remoteId == heuristicOnly.remoteId
                    }
                    XCTAssertEqual(
                        heuristicItem?.group, .needsReply,
                        "ids the classifier omits must keep the heuristic group"
                    )
                }
            }
        }
    }

    /// A classifier outage must never 500 the feed: the heuristics stand and
    /// the response is still 200.
    func test_getBriefing_throwingClassifier_stillReturns200WithHeuristics() async throws {
        let account = makeAccount(
            oauthUser: "route-\(UUID().uuidString)",
            email: "me-\(UUID().uuidString)@example.com"
        )

        try await TestDatabase.withConnection(cleanup: cleanup(accountId: account.id)) { conn in
            try await seedAccount(account, db: conn)
            let message = makeHeader(
                accountId: account.id,
                remoteId: "t-\(UUID())",
                from: "alice@example.com"
            )
            try await MessageStore.upsert(message, db: conn)

            let app = Application(
                router: makeBriefingRouter(db: conn, classifier: ThrowingBriefingClassifier())
            )
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/api/briefing?accountId=\(account.id.uuidString)",
                    method: .get
                ) { response in
                    XCTAssertEqual(response.status, .ok)
                    let decoded = try Self.iso8601Decoder().decode(
                        BriefingResponse.self,
                        from: Data(buffer: response.body)
                    )
                    XCTAssertEqual(decoded.items.count, 1)
                    XCTAssertEqual(decoded.items.first?.message.remoteId, message.remoteId)
                    XCTAssertEqual(decoded.items.first?.group, .needsReply)
                }
            }
        }
    }

    /// The briefing payload carries header fields only — never a body/text.
    func test_getBriefing_payloadNeverContainsBodyOrText() async throws {
        let account = makeAccount(
            oauthUser: "route-\(UUID().uuidString)",
            email: "me-\(UUID().uuidString)@example.com"
        )

        try await TestDatabase.withConnection(cleanup: cleanup(accountId: account.id)) { conn in
            try await seedAccount(account, db: conn)
            try await MessageStore.upsert(
                makeHeader(
                    accountId: account.id,
                    remoteId: "b-\(UUID())",
                    from: "alice@example.com"
                ),
                db: conn
            )

            let app = Application(router: makeBriefingRouter(db: conn))
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/api/briefing?accountId=\(account.id.uuidString)",
                    method: .get
                ) { response in
                    XCTAssertEqual(response.status, .ok)
                    let object = try JSONSerialization.jsonObject(with: Data(buffer: response.body))
                    let keys = Self.allKeys(object)
                    XCTAssertTrue(keys.contains("message"), "sanity: item carries a message object")
                    XCTAssertFalse(
                        keys.contains("body"),
                        "briefing payload must not include a body field (keys: \(Set(keys))) "
                    )
                    XCTAssertFalse(
                        keys.contains("text"),
                        "briefing payload must not include a text field (keys: \(Set(keys)))"
                    )
                }
            }
        }
    }

    // MARK: - GET /api/messages/{remoteId}/summary

    /// No AI provider configured → 503 with the stable error envelope. The
    /// check happens before the account lookup, so no DB rows are needed.
    func test_getSummary_nilSummarizer_returns503AiNotConfigured() async throws {
        try await TestDatabase.withConnection { conn in
            let app = Application(router: makeMessageRouter(db: conn, summarizer: nil))
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/api/messages/msg-1/summary?accountId=\(UUID().uuidString)",
                    method: .get
                ) { response in
                    XCTAssertEqual(response.status, .serviceUnavailable)
                    XCTAssertEqual(
                        response.headers[.contentType],
                        "application/json; charset=utf-8"
                    )
                    let code = try Self.errorCode(from: response.body)
                    XCTAssertEqual(code, "ai-not-configured")
                }
            }
        }
    }

    /// With a summarizer injected, the route fetches the body from the stubbed
    /// Gmail full response and returns the normalized 200 `MessageSummary`.
    func test_getSummary_fakeSummarizer_returns200MessageSummary() async throws {
        let oauthUser = "route-\(UUID().uuidString)"
        let account = makeAccount(oauthUser: oauthUser, email: "me-\(UUID().uuidString)@example.com")
        let remoteId = "msg-\(UUID())"

        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            try await TestDatabase.withConnection(cleanup: cleanup(accountId: account.id)) { conn in
                // Valid (non-expired) token so the route uses it directly and
                // never calls the OAuth refresh endpoint.
                try await seedAccount(
                    account,
                    credentials: try CredentialVault.seal(.gmail(
                        accessToken: "access-\(UUID())",
                        refreshToken: "refresh-\(UUID())",
                        expiresAt: Date().addingTimeInterval(3600)
                    )),
                    db: conn
                )
                let bodyJSON = Self.gmailFullMessageJSON(
                    remoteId: remoteId,
                    subject: "Hello",
                    from: "Alice <alice@example.com>",
                    text: "Please review the plan."
                )
                URLProtocolStub.install { request in
                    let url = request.url!
                    guard url.host == "gmail.googleapis.com" else {
                        return (Self.http(url, 404), Data())
                    }
                    return (Self.http(url, 200), bodyJSON)
                }

                let summarizer = FakeSummarizer(
                    summary: "Review plan",
                    actionItems: ["Review plan"],
                    provider: "fake"
                )
                let app = Application(router: makeMessageRouter(db: conn, summarizer: summarizer))
                try await app.test(.router) { client in
                    try await client.execute(
                        uri: "/api/messages/\(remoteId)/summary?accountId=\(account.id.uuidString)",
                        method: .get
                    ) { response in
                        XCTAssertEqual(response.status, .ok)
                        XCTAssertEqual(
                            response.headers[.contentType],
                            "application/json; charset=utf-8"
                        )
                        let decoded = try JSONDecoder().decode(
                            MessageSummary.self,
                            from: Data(buffer: response.body)
                        )
                        XCTAssertEqual(decoded.remoteId, remoteId)
                        XCTAssertEqual(decoded.summary, "Review plan")
                        XCTAssertEqual(decoded.actionItems, ["Review plan"])
                        XCTAssertEqual(decoded.provider, "fake")
                    }
                }
            }
        }
    }

    // MARK: - POST /api/messages/{remoteId}/read

    func test_postRead_returns204AndFlipsIsRead() async throws {
        let account = makeAccount(
            oauthUser: "route-\(UUID().uuidString)",
            email: "me-\(UUID().uuidString)@example.com"
        )

        try await TestDatabase.withConnection(cleanup: cleanup(accountId: account.id)) { conn in
            try await seedAccount(account, db: conn)
            let message = makeHeader(
                accountId: account.id,
                remoteId: "m-\(UUID())",
                from: "alice@example.com",
                isRead: false
            )
            try await MessageStore.upsert(message, db: conn)

            let app = Application(router: makeMessageRouter(db: conn))
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/api/messages/\(message.remoteId)/read?accountId=\(account.id.uuidString)",
                    method: .post
                ) { response in
                    XCTAssertEqual(response.status, .noContent)
                }
            }

            let recent = try await MessageStore.recent(
                forAccount: account.id,
                limit: 50,
                db: conn
            )
            XCTAssertEqual(
                recent.first { $0.remoteId == message.remoteId }?.isRead,
                true,
                "POST /read must persist is_read = TRUE"
            )
        }
    }

    // MARK: - POST /api/messages/{remoteId}/pin

    /// `pinned=true` moves the item into the pinned group; `pinned=false`
    /// removes the pin and the item returns to its heuristic group.
    func test_postPin_movesItemBetweenPinnedAndHeuristicGroup() async throws {
        let account = makeAccount(
            oauthUser: "route-\(UUID().uuidString)",
            email: "me-\(UUID().uuidString)@example.com"
        )

        try await TestDatabase.withConnection(cleanup: cleanup(accountId: account.id)) { conn in
            try await seedAccount(account, db: conn)
            let message = makeHeader(
                accountId: account.id,
                remoteId: "p-\(UUID())",
                from: "alice@example.com"
            )
            try await MessageStore.upsert(message, db: conn)

            let briefingURI = "/api/briefing?accountId=\(account.id.uuidString)"
            let pinURI: (Bool) -> String = { pinned in
                "/api/messages/\(message.remoteId)/pin?accountId=\(account.id.uuidString)&pinned=\(pinned)"
            }
            let app = Application(router: makeM1Router(db: conn))
            try await app.test(.router) { client in
                // Baseline: no pin yet → heuristic group.
                try await client.execute(uri: briefingURI, method: .get) { response in
                    XCTAssertEqual(response.status, .ok)
                    let decoded = try Self.iso8601Decoder().decode(
                        BriefingResponse.self,
                        from: Data(buffer: response.body)
                    )
                    let item = decoded.items.first { $0.message.remoteId == message.remoteId }
                    XCTAssertEqual(item?.group, .needsReply)
                }

                try await client.execute(uri: pinURI(true), method: .post) { response in
                    XCTAssertEqual(response.status, .noContent)
                }
                try await client.execute(uri: briefingURI, method: .get) { response in
                    XCTAssertEqual(response.status, .ok)
                    let decoded = try Self.iso8601Decoder().decode(
                        BriefingResponse.self,
                        from: Data(buffer: response.body)
                    )
                    let item = decoded.items.first { $0.message.remoteId == message.remoteId }
                    XCTAssertEqual(item?.group, .pinned)
                }

                try await client.execute(uri: pinURI(false), method: .post) { response in
                    XCTAssertEqual(response.status, .noContent)
                }
                try await client.execute(uri: briefingURI, method: .get) { response in
                    XCTAssertEqual(response.status, .ok)
                    let decoded = try Self.iso8601Decoder().decode(
                        BriefingResponse.self,
                        from: Data(buffer: response.body)
                    )
                    let item = decoded.items.first { $0.message.remoteId == message.remoteId }
                    XCTAssertEqual(
                        item?.group, .needsReply,
                        "unpinning must fall back to the heuristic group"
                    )
                }
            }

            let pinnedIds = try await MessageStore.pinnedIds(forAccount: account.id, db: conn)
            XCTAssertTrue(pinnedIds.isEmpty, "unpin must delete the message_pins row")
        }
    }

    // MARK: - Malformed input

    func test_malformedAccountId_returns400OnAllM1Routes() async throws {
        try await TestDatabase.withConnection { conn in
            let messageApp = Application(router: makeMessageRouter(db: conn))
            let briefingApp = Application(router: makeBriefingRouter(db: conn))

            let messageRoutes: [(String, HTTPRequest.Method)] = [
                ("/api/messages/msg-1/read?accountId=not-a-uuid", .post),
                ("/api/messages/msg-1/pin?accountId=not-a-uuid&pinned=true", .post),
                ("/api/messages/msg-1/summary?accountId=not-a-uuid", .get),
            ]
            try await messageApp.test(.router) { client in
                for (uri, method) in messageRoutes {
                    try await client.execute(uri: uri, method: method) { response in
                        let code = try Self.errorCode(from: response.body)
                        XCTAssertEqual(response.status, .badRequest, "expected 400 for \(uri)")
                        XCTAssertEqual(code, "malformed-accountId", "for \(uri)")
                    }
                }
            }

            try await briefingApp.test(.router) { client in
                try await client.execute(
                    uri: "/api/briefing?accountId=not-a-uuid",
                    method: .get
                ) { response in
                    let code = try Self.errorCode(from: response.body)
                    XCTAssertEqual(response.status, .badRequest)
                    XCTAssertEqual(code, "malformed-accountId")
                }
            }
        }
    }

    /// Documents that the `malformed-remoteId` 400 branch is unreachable: the
    /// router splits paths with `omittingEmptySubsequences: true`, so an empty
    /// path segment collapses and the `:remoteId` capture can never be empty.
    /// `/api/messages//read` therefore 404s (route does not match).
    func test_emptyGmailIdPathSegment_is404_malformedGmailId400BranchUnreachable() async throws {
        try await TestDatabase.withConnection { conn in
            let app = Application(router: makeMessageRouter(db: conn))
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/api/messages//read?accountId=\(UUID().uuidString)",
                    method: .post
                ) { response in
                    XCTAssertEqual(response.status, .notFound)
                }
            }
        }
    }

    // MARK: - Unknown account

    func test_unknownAccount_returns404OnBriefingAndSummary() async throws {
        try await TestDatabase.withConnection { conn in
            let unknown = UUID()
            let summarizer = FakeSummarizer(summary: "s", actionItems: [], provider: nil)
            let briefingApp = Application(router: makeBriefingRouter(db: conn))
            let messageApp = Application(router: makeMessageRouter(db: conn, summarizer: summarizer))

            try await briefingApp.test(.router) { client in
                try await client.execute(
                    uri: "/api/briefing?accountId=\(unknown.uuidString)",
                    method: .get
                ) { response in
                    let code = try Self.errorCode(from: response.body)
                    XCTAssertEqual(response.status, .notFound)
                    XCTAssertEqual(code, "unknown-account")
                }
            }

            try await messageApp.test(.router) { client in
                try await client.execute(
                    uri: "/api/messages/msg-1/summary?accountId=\(unknown.uuidString)",
                    method: .get
                ) { response in
                    let code = try Self.errorCode(from: response.body)
                    XCTAssertEqual(response.status, .notFound)
                    XCTAssertEqual(code, "unknown-account")
                }
            }
        }
    }

    /// Documents the M1 contract gap found while writing these tests:
    /// `/read` and `/pin` never look up the account. `/read` is a no-op 204 for
    /// an unknown account, and `/pin?pinned=true` hits the `message_pins`
    /// foreign key and surfaces a 500 instead of the contracted 404. Not fixed
    /// here (Sources/ is out of scope); reported as a product bug.
    func test_unknownAccount_readAndPinReturn404() async throws {
        try await TestDatabase.withConnection { conn in
            let unknown = UUID()
            let app = Application(router: makeMessageRouter(db: conn))
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/api/messages/msg-1/read?accountId=\(unknown.uuidString)",
                    method: .post
                ) { response in
                    XCTAssertEqual(response.status, .notFound)
                    XCTAssertEqual(try Self.errorCode(from: response.body), "unknown-account")
                }
                try await client.execute(
                    uri: "/api/messages/msg-1/pin?accountId=\(unknown.uuidString)&pinned=true",
                    method: .post
                ) { response in
                    XCTAssertEqual(response.status, .notFound)
                    XCTAssertEqual(try Self.errorCode(from: response.body), "unknown-account")
                }
            }
        }
    }
}
