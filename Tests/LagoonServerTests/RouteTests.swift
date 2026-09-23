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
        // No secret configured (nil + empty env) → the ceiling holds.
        // The 501 path never touches the database.
        try await TestDatabase.withConnection { conn in
            let router = Router()
            GmailWebhookRoutes.register(
                on: router, db: conn, logger: Self.testLogger, webhookSecret: nil
            )
            let app = Application(router: router)

            try await app.test(.router) { client in
                try await client.execute(uri: "/webhook/gmail", method: .post) { response in
                    // Nil secret + empty env → 501 ceiling. If the ambient
                    // environment exports LAGOON_WEBHOOK_SECRET the route
                    // instead demands auth (401) — either way no sync happens.
                    XCTAssertTrue(
                        response.status == .notImplemented || response.status == .unauthorized
                    )
                }
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
            AccountsRoutes.register(
                on: router, db: conn, logger: Self.testLogger, makeProvider: { _ in nil }
            )
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
                isActive: false
            )
            let preExistingCount = try await AccountStore.all(db: conn).count
            try await AccountStore.upsert(
                account,
                credentials: Data([1, 2, 3]),
                db: conn
            )

            let router = Router()
            AccountsRoutes.register(
                on: router, db: conn, logger: Self.testLogger, makeProvider: { _ in nil }
            )
            let app = Application(router: router)

            try await app.test(.router) { client in
                try await client.execute(uri: "/api/accounts", method: .get) { response in
                    XCTAssertEqual(response.status, .ok)
                    XCTAssertEqual(
                        response.headers[.contentType],
                        "application/json; charset=utf-8"
                    )
                    let decoded = try Self.iso8601Decoder().decode(
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

    /// Gmail collaborators for routes whose default provider builder needs them.
    /// The stubbed session keeps any accidental network call inside the process.
    private func makeGmailCollaborators(
        db: PostgresConnection
    ) -> (GmailClient, GmailTokenService) {
        let session = Self.makeSession()
        let client = GmailClient(session: session)
        let tokens = GmailTokenService(
            db: db,
            oauth: GoogleOAuthClient(
                clientID: "test-client",
                clientSecret: "test-secret",
                redirectURI: "http://127.0.0.1:9999/callback",
                session: session
            ),
            logger: Self.testLogger
        )
        return (client, tokens)
    }

    private func makeMessageRouter(
        db: PostgresConnection,
        summarizer: (any MessageSummarizing)? = nil,
        makeProvider: MailProviderFactory.Builder? = nil
    ) -> Router<BasicRequestContext> {
        let (client, tokens) = makeGmailCollaborators(db: db)
        let router = Router()
        MessageRoutes.register(
            on: router,
            db: db,
            client: client,
            tokens: tokens,
            logger: Self.testLogger,
            summarizer: summarizer,
            makeProvider: makeProvider
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
            isActive: false
        )
    }

    private func makeHeader(
        accountId: UUID,
        remoteId: String,
        from: String,
        isRead: Bool = false,
        daysAgo: Double = 0,
        subject: String? = nil,
        messageIdHeader: String? = nil,
        inReplyTo: String? = nil,
        references: String? = nil
    ) -> MessageHeader {
        MessageHeader(
            id: UUID(),
            accountId: accountId,
            remoteId: remoteId,
            threadId: "thread-\(remoteId)",
            fromAddress: from,
            fromName: nil,
            subject: subject ?? "subject \(remoteId)",
            snippet: nil,
            receivedAt: Date().addingTimeInterval(-daysAgo * 24 * 60 * 60),
            isRead: isRead,
            isArchived: false,
            messageIdHeader: messageIdHeader,
            inReplyTo: inReplyTo,
            references: references
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

    // MARK: - T8: account write path + provider dispatch

    /// Scripted `MailProvider` for route tests. Failures are injected as typed
    /// `MailError`s so the assertions are about the route's status mapping, and
    /// calls are recorded so "the provider was actually asked to do it" is
    /// testable without a live connection.
    private actor StubMailProvider: MailProvider {
        nonisolated let kind: MailProviderKind
        private(set) var capabilitiesValue: MailCapabilities
        private var probeError: MailError?
        private var bodyError: MailError?
        private var archiveError: MailError?
        var bodyText = "stub body text"
        private(set) var probeCalls = 0
        private(set) var archivedRemoteIds: [String] = []
        private(set) var unarchivedRemoteIds: [String] = []
        private(set) var readCalls: [String] = []
        private(set) var sentOutbounds: [OutboundMessage] = []
        private var sendResult: String? = "stub-provider-message-id"
        private var sendError: MailError?
        private var probeHook: (@Sendable () async -> Void)?

        init(
            kind: MailProviderKind = .qq,
            capabilities: MailCapabilities = MailCapabilities(
                archiveFolder: true, idle: true, move: true, serverSnippet: true
            )
        ) {
            self.kind = kind
            self.capabilitiesValue = capabilities
        }

        func setProbeError(_ error: MailError?) { probeError = error }
        func setBodyError(_ error: MailError?) { bodyError = error }
        func setArchiveError(_ error: MailError?) { archiveError = error }

        func capabilities() async -> MailCapabilities { capabilitiesValue }

        func pullChanges(after cursor: MailSyncState, waitUpTo: Duration) async throws -> MailChangeSet {
            MailChangeSet(upserts: [], resetRequired: false, cursor: cursor)
        }

        func fetchBody(remoteId: String) async throws -> FetchedBody {
            if let bodyError { throw bodyError }
            return FetchedBody(text: bodyText, html: nil, attachments: [], hasMore: false)
        }

        func fetchAttachment(remoteId: String, attachmentId: String) async throws -> FetchedAttachmentBytes {
            throw AttachmentError.notFound
        }

        func fetchRawMessage(remoteId: String) async throws -> Data {
            Data(bodyText.utf8)
        }

        func fetchRawHeaderValues(remoteId: String) async throws -> [String: String] { [:] }

        func setRead(remoteId: String, isRead: Bool) async throws {
            readCalls.append(remoteId)
        }

        func archive(remoteId: String) async throws {
            if let archiveError { throw archiveError }
            archivedRemoteIds.append(remoteId)
        }

        func unarchive(remoteId: String) async throws {
            unarchivedRemoteIds.append(remoteId)
        }

        func send(_ outbound: OutboundMessage) async throws -> String? {
            sentOutbounds.append(outbound)
            if let sendError { throw sendError }
            return sendResult
        }

        func probe() async throws {
            probeCalls += 1
            if let probeHook { await probeHook() }
            if let probeError { throw probeError }
        }

        func setProbeHook(_ hook: (@Sendable () async -> Void)?) { probeHook = hook }

        func setSendResult(_ id: String?) { sendResult = id }
        func setSendError(_ error: MailError?) { sendError = error }
    }

    private func makeAccountsRouter(
        db: PostgresConnection,
        provider: any MailProvider,
        sync: SyncEngine? = nil
    ) -> Router<BasicRequestContext> {
        let router = Router()
        AccountsRoutes.register(
            on: router,
            db: db,
            logger: Self.testLogger,
            sync: sync,
            makeProvider: { _ in provider }
        )
        return router
    }

    private static func jsonBody(_ object: [String: String]) -> ByteBuffer {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        return ByteBuffer(data: data)
    }

    func test_postAccountsIMAP_missingField_returns400() async throws {
        try await TestDatabase.withConnection { conn in
            let provider = StubMailProvider()
            let app = Application(router: makeAccountsRouter(db: conn, provider: provider))
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/api/accounts/imap",
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: Self.jsonBody(["provider": "qq", "email": "me@qq.com"])
                ) { response in
                    XCTAssertEqual(response.status, .badRequest)
                    XCTAssertEqual(try Self.errorCode(from: response.body), "missing-field")
                }
                let calls = await provider.probeCalls
                XCTAssertEqual(calls, 0, "a malformed request must never touch the network")
            }
        }
    }

    func test_postAccountsIMAP_probeAuthFailed_returns401() async throws {
        let email = "imap-\(UUID().uuidString)@qq.com"
        // The connect flow seals the credential blob before probing, so the
        // cipher needs a key even for the rejected path.
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            try await TestDatabase.withConnection(cleanup: { conn in
                try? await TestDatabase.deleteAccount(oauthUser: email, provider: .qq, db: conn)
            }) { conn in
                let provider = StubMailProvider()
                await provider.setProbeError(.authFailed)
                let app = Application(router: makeAccountsRouter(db: conn, provider: provider))
                try await app.test(.router) { client in
                    try await client.execute(
                        uri: "/api/accounts/imap",
                        method: .post,
                        headers: [.contentType: "application/json"],
                        body: Self.jsonBody(["provider": "qq", "email": email, "authCode": "wrong-code"])
                    ) { response in
                        XCTAssertEqual(response.status, .unauthorized)
                        XCTAssertEqual(try Self.errorCode(from: response.body), "imap-auth-failed")
                    }
                }
                let stored = try await AccountStore.find(byOAuthUser: email, provider: .qq, db: conn)
                XCTAssertNil(stored, "a failed probe must not leave an account row")
            }
        }
    }

    func test_postAccountsIMAP_success_returns201ActiveWithCapabilities() async throws {
        let email = "imap-\(UUID().uuidString)@qq.com"
        let authCode = "auth-code-\(UUID().uuidString)"
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            try await TestDatabase.withConnection(cleanup: { conn in
                try? await TestDatabase.deleteAccount(oauthUser: email, provider: .qq, db: conn)
            }) { conn in
                let provider = StubMailProvider()
                let app = Application(router: makeAccountsRouter(db: conn, provider: provider))
                try await app.test(.router) { client in
                    try await client.execute(
                        uri: "/api/accounts/imap",
                        method: .post,
                        headers: [.contentType: "application/json"],
                        body: Self.jsonBody(["provider": "qq", "email": email, "authCode": authCode])
                    ) { response in
                        XCTAssertEqual(response.status, .created)
                        let raw = String(buffer: response.body)
                        XCTAssertFalse(raw.contains(authCode), "the auth code must never be echoed")
                        let decoded = try Self.iso8601Decoder().decode(
                            ConnectedAccount.self, from: Data(buffer: response.body)
                        )
                        XCTAssertEqual(decoded.provider, .qq)
                        XCTAssertEqual(decoded.email, email)
                        XCTAssertTrue(decoded.isActive)
                        XCTAssertEqual(
                            decoded.capabilities,
                            MailCapabilities(archiveFolder: true, idle: true, move: true, serverSnippet: true)
                        )
                    }
                    try await client.execute(uri: "/api/accounts", method: .get) { response in
                        let raw = String(buffer: response.body)
                        XCTAssertFalse(raw.contains(authCode), "GET /api/accounts must never echo secrets")
                        let decoded = try Self.iso8601Decoder().decode(
                            [ConnectedAccount].self, from: Data(buffer: response.body)
                        )
                        let mine = decoded.first { $0.email == email }
                        XCTAssertNotNil(mine, "the fresh account must be listed")
                        XCTAssertTrue(mine?.isActive ?? false)
                        XCTAssertTrue(mine?.capabilities.archiveFolder ?? false)
                    }
                }

                let stored = try await AccountStore.find(byOAuthUser: email, provider: .qq, db: conn)
                let account = try XCTUnwrap(stored)
                XCTAssertTrue(account.isActive)
                let credentials = try await CredentialVault.read(accountId: account.id, db: conn)
                XCTAssertEqual(credentials, .imap(username: email, authCode: authCode))
                XCTAssertEqual(account.capabilities.archiveFolder, true)
            }
        }
    }

    func test_postAccountsIMAP_existingAccount_returns409() async throws {
        let email = "imap-\(UUID().uuidString)@qq.com"
        try await TestDatabase.withConnection(cleanup: { conn in
            try? await TestDatabase.deleteAccount(oauthUser: email, provider: .qq, db: conn)
        }) { conn in
            try await seedAccount(
                Account(
                    id: UUID(), provider: .qq, oauthUser: email, email: email,
                    credentials: Data([1, 2, 3]), isActive: false
                ),
                db: conn
            )
            let provider = StubMailProvider()
            let app = Application(router: makeAccountsRouter(db: conn, provider: provider))
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/api/accounts/imap",
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: Self.jsonBody(["provider": "qq", "email": email, "authCode": "code"])
                ) { response in
                    XCTAssertEqual(response.status, .conflict)
                    XCTAssertEqual(try Self.errorCode(from: response.body), "account-exists")
                }
            }
            let calls = await provider.probeCalls
            XCTAssertEqual(calls, 0, "an existing account is reported before any network work")
        }
    }

    /// Rule 2: a `needsReconnect` row is re-authenticated in place with the
    /// submitted code and keeps its original id. This is the fix for the
    /// "QQ account that can never be repaired" lock-out.
    func test_postAccountsIMAP_unhealthyExistingAccount_reAuthsInPlaceWithSameId() async throws {
        let email = "imap-\(UUID().uuidString)@qq.com"
        let newAuthCode = "new-auth-code-\(UUID().uuidString)"
        let seededId = UUID()
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            try await TestDatabase.withConnection(cleanup: { conn in
                try? await TestDatabase.deleteAccount(oauthUser: email, provider: .qq, db: conn)
            }) { conn in
                try await seedAccount(
                    Account(
                        id: seededId, provider: .qq, oauthUser: email, email: email,
                        credentials: Data([1, 2, 3]), isActive: false,
                        syncHealth: SyncHealth(status: .needsReconnect, lastError: "auth code rejected")
                    ),
                    db: conn
                )
                let provider = StubMailProvider()
                let app = Application(router: makeAccountsRouter(db: conn, provider: provider))
                try await app.test(.router) { client in
                    try await client.execute(
                        uri: "/api/accounts/imap",
                        method: .post,
                        headers: [.contentType: "application/json"],
                        body: Self.jsonBody(["provider": "qq", "email": email, "authCode": newAuthCode])
                    ) { response in
                        XCTAssertEqual(response.status, .created)
                        let raw = String(buffer: response.body)
                        XCTAssertFalse(raw.contains(newAuthCode), "the auth code must never be echoed")
                        let decoded = try Self.iso8601Decoder().decode(
                            ConnectedAccount.self, from: Data(buffer: response.body)
                        )
                        XCTAssertEqual(decoded.id, seededId, "re-auth must keep the existing row id")
                        XCTAssertEqual(decoded.email, email)
                        XCTAssertEqual(decoded.syncHealth.status, .ok)
                    }
                }
                let calls = await provider.probeCalls
                XCTAssertGreaterThanOrEqual(calls, 1, "an unhealthy existing row must be probed with the new code")

                let stored = try await AccountStore.find(byOAuthUser: email, provider: .qq, db: conn)
                let account = try XCTUnwrap(stored)
                XCTAssertEqual(account.id, seededId)
                XCTAssertEqual(account.syncHealth.status, .ok)
                XCTAssertNil(account.syncHealth.lastError, "the red reconnect banner must clear")
                XCTAssertTrue(account.isActive)
                let credentials = try await CredentialVault.read(accountId: account.id, db: conn)
                XCTAssertEqual(credentials, .imap(username: email, authCode: newAuthCode))
            }
        }
    }

    /// Rule 2's safety guarantee: a failed re-auth probe must leave the
    /// existing unhealthy row completely untouched (no credentials,
    /// sync_status, capabilities or is_active write).
    func test_postAccountsIMAP_unhealthyExistingAccount_probeFails_leavesRowUntouched() async throws {
        let email = "imap-\(UUID().uuidString)@qq.com"
        let seededId = UUID()
        let seededCredentials = Data([7, 7, 7])
        let seededCapabilities = MailCapabilities(
            archiveFolder: false, idle: true, move: false, serverSnippet: true
        )
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            try await TestDatabase.withConnection(cleanup: { conn in
                try? await TestDatabase.deleteAccount(oauthUser: email, provider: .qq, db: conn)
            }) { conn in
                try await seedAccount(
                    Account(
                        id: seededId, provider: .qq, oauthUser: email, email: email,
                        credentials: nil, capabilities: seededCapabilities, isActive: false,
                        syncHealth: SyncHealth(status: .needsReconnect, lastError: "old failure")
                    ),
                    credentials: seededCredentials,
                    db: conn
                )
                let provider = StubMailProvider()
                await provider.setProbeError(.authFailed)
                let app = Application(router: makeAccountsRouter(db: conn, provider: provider))
                try await app.test(.router) { client in
                    try await client.execute(
                        uri: "/api/accounts/imap",
                        method: .post,
                        headers: [.contentType: "application/json"],
                        body: Self.jsonBody(["provider": "qq", "email": email, "authCode": "stale-code"])
                    ) { response in
                        XCTAssertEqual(response.status, .unauthorized)
                        XCTAssertEqual(try Self.errorCode(from: response.body), "imap-auth-failed")
                    }
                }
                let calls = await provider.probeCalls
                XCTAssertGreaterThanOrEqual(calls, 1, "the submitted code must still be probed")

                let stored = try await AccountStore.find(byOAuthUser: email, provider: .qq, db: conn)
                let account = try XCTUnwrap(stored)
                XCTAssertEqual(account.id, seededId)
                XCTAssertEqual(account.credentials, seededCredentials, "a failed re-auth must not rewrite credentials")
                XCTAssertEqual(account.syncHealth.status, .needsReconnect)
                XCTAssertEqual(account.syncHealth.lastError, "old failure")
                XCTAssertEqual(account.capabilities, seededCapabilities)
                XCTAssertFalse(account.isActive, "a failed re-auth must not activate the row")
            }
        }
    }

    /// MUST 2 regression: `upsert`'s `ON CONFLICT ... DO UPDATE` keeps the row
    /// id already in the DB, so the route must answer with the row read back
    /// after persisting rather than the request-local UUID. The probe hook
    /// deterministically simulates the concurrent insert that a double-POST
    /// would otherwise race.
    func test_postAccountsIMAP_upsertConflict_returnsStoredId() async throws {
        let email = "imap-\(UUID().uuidString)@qq.com"
        let racedId = UUID()
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            try await TestDatabase.withConnection(cleanup: { conn in
                try? await TestDatabase.deleteAccount(oauthUser: email, provider: .qq, db: conn)
            }) { conn in
                let provider = StubMailProvider()
                await provider.setProbeHook {
                    try? await AccountStore.upsert(
                        Account(
                            id: racedId, provider: .qq, oauthUser: email, email: email,
                            credentials: Data([9, 9, 9]), isActive: false
                        ),
                        credentials: Data([9, 9, 9]),
                        db: conn
                    )
                }
                let app = Application(router: makeAccountsRouter(db: conn, provider: provider))
                try await app.test(.router) { client in
                    try await client.execute(
                        uri: "/api/accounts/imap",
                        method: .post,
                        headers: [.contentType: "application/json"],
                        body: Self.jsonBody(["provider": "qq", "email": email, "authCode": "code"])
                    ) { response in
                        XCTAssertEqual(response.status, .created)
                        let decoded = try Self.iso8601Decoder().decode(
                            ConnectedAccount.self, from: Data(buffer: response.body)
                        )
                        XCTAssertEqual(decoded.id, racedId, "201 must echo the id the DB actually kept")
                    }
                }
                let rows = try await AccountStore.all(db: conn).filter { $0.oauthUser == email }
                XCTAssertEqual(rows.count, 1, "the conflict must update, not duplicate")
                XCTAssertEqual(rows.first?.id, racedId)
            }
        }
    }

    /// MUST 2 regression, literal two-POST form: two concurrent POSTs for the
    /// same email both return the single id the database kept.
    func test_postAccountsIMAP_concurrentDoublePost_returnsSameStoredId() async throws {
        let email = "imap-\(UUID().uuidString)@qq.com"
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            try await TestDatabase.withConnection(cleanup: { conn in
                try? await TestDatabase.deleteAccount(oauthUser: email, provider: .qq, db: conn)
            }) { conn in
                let gate = ProbeGate()
                let provider = StubMailProvider()
                await provider.setProbeHook { await gate.arriveAndWait() }
                let app = Application(router: makeAccountsRouter(db: conn, provider: provider))
                try await app.test(.router) { client in
                    async let first = client.executeRequest(
                        uri: "/api/accounts/imap",
                        method: .post,
                        headers: [.contentType: "application/json"],
                        body: Self.jsonBody(["provider": "qq", "email": email, "authCode": "code-a"])
                    )
                    async let second = client.executeRequest(
                        uri: "/api/accounts/imap",
                        method: .post,
                        headers: [.contentType: "application/json"],
                        body: Self.jsonBody(["provider": "qq", "email": email, "authCode": "code-b"])
                    )
                    // Never hang if the harness happens to serialize requests.
                    let timeout = Task {
                        try? await Task.sleep(for: .seconds(5))
                        await gate.release()
                    }
                    let (r1, r2) = try await (first, second)
                    timeout.cancel()
                    XCTAssertEqual(r1.status, .created)
                    XCTAssertEqual(r2.status, .created)
                    let id1 = try Self.iso8601Decoder().decode(
                        ConnectedAccount.self, from: Data(buffer: r1.body)
                    ).id
                    let id2 = try Self.iso8601Decoder().decode(
                        ConnectedAccount.self, from: Data(buffer: r2.body)
                    ).id
                    XCTAssertEqual(id1, id2, "both POSTs must return the stored row id")
                }
            }
        }
    }

    func test_deleteAccount_returns204AndRemovesRow() async throws {
        let account = makeAccount(oauthUser: "route-\(UUID().uuidString)", email: "d-\(UUID())@example.com")
        try await TestDatabase.withConnection(cleanup: { conn in
            try? await TestDatabase.deleteAccount(id: account.id, db: conn)
        }) { conn in
            try await seedAccount(account, db: conn)
            let provider = StubMailProvider()
            let app = Application(router: makeAccountsRouter(db: conn, provider: provider))
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/api/accounts/\(account.id.uuidString)",
                    method: .delete
                ) { response in
                    XCTAssertEqual(response.status, .noContent)
                }
                try await client.execute(uri: "/api/accounts", method: .get) { response in
                    let decoded = try Self.iso8601Decoder().decode(
                        [ConnectedAccount].self, from: Data(buffer: response.body)
                    )
                    XCTAssertFalse(decoded.contains { $0.id == account.id })
                }
            }
        }
    }

    func test_deleteAccount_unknownAccount_returns404() async throws {
        try await TestDatabase.withConnection { conn in
            let provider = StubMailProvider()
            let app = Application(router: makeAccountsRouter(db: conn, provider: provider))
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/api/accounts/\(UUID().uuidString)",
                    method: .delete
                ) { response in
                    XCTAssertEqual(response.status, .notFound)
                }
            }
        }
    }

    func test_postActivate_movesTheSingleActiveAccount() async throws {
        let first = makeAccount(
            oauthUser: "route-\(UUID().uuidString)",
            email: "activate-a-\(UUID().uuidString)@example.com"
        )
        let second = makeAccount(
            oauthUser: "route-\(UUID().uuidString)",
            email: "activate-b-\(UUID().uuidString)@example.com"
        )
        try await TestDatabase.withConnection(cleanup: { conn in
            try? await TestDatabase.deleteAccount(id: first.id, db: conn)
            try? await TestDatabase.deleteAccount(id: second.id, db: conn)
        }) { conn in
            try await seedAccount(first, db: conn)
            try await seedAccount(second, db: conn)
            try await AccountStore.setActive(accountId: first.id, db: conn)

            let app = Application(
                router: makeAccountsRouter(db: conn, provider: StubMailProvider())
            )
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/api/accounts/\(second.id.uuidString)/activate",
                    method: .post
                ) { response in
                    XCTAssertEqual(response.status, .noContent)
                }
                try await client.execute(uri: "/api/accounts", method: .get) { response in
                    let decoded = try Self.iso8601Decoder().decode(
                        [ConnectedAccount].self, from: Data(buffer: response.body)
                    )
                    XCTAssertEqual(decoded.filter(\.isActive).map(\.id), [second.id])
                }
            }

            let oldActive = try await AccountStore.find(byId: first.id, db: conn)
            let newActive = try await AccountStore.find(byId: second.id, db: conn)
            XCTAssertEqual(oldActive?.isActive, false)
            XCTAssertEqual(newActive?.isActive, true)
        }
    }

    func test_postActivate_unknownAccount_returns404() async throws {
        try await TestDatabase.withConnection { conn in
            let app = Application(
                router: makeAccountsRouter(db: conn, provider: StubMailProvider())
            )
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/api/accounts/\(UUID().uuidString)/activate",
                    method: .post
                ) { response in
                    XCTAssertEqual(response.status, .notFound)
                    XCTAssertEqual(try Self.errorCode(from: response.body), "unknown-account")
                }
            }
        }
    }

    func test_getBody_providerText_returns200MessageBody() async throws {
        let account = makeAccount(oauthUser: "route-\(UUID().uuidString)", email: "me-\(UUID())@example.com")
        try await TestDatabase.withConnection(cleanup: cleanup(accountId: account.id)) { conn in
            try await seedAccount(account, db: conn)
            let message = makeHeader(accountId: account.id, remoteId: "77", from: "alice@example.com")
            try await MessageStore.upsert(message, db: conn)

            let provider = StubMailProvider()
            let app = Application(
                router: makeMessageRouter(db: conn, makeProvider: { _ in provider })
            )
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/api/messages/77/body?accountId=\(account.id.uuidString)",
                    method: .get
                ) { response in
                    XCTAssertEqual(response.status, .ok)
                    let decoded = try Self.iso8601Decoder().decode(
                        MessageBody.self, from: Data(buffer: response.body)
                    )
                    XCTAssertEqual(decoded.remoteId, "77")
                    XCTAssertEqual(decoded.text, "stub body text")
                    XCTAssertEqual(decoded.fromAddress, "alice@example.com")
                    XCTAssertEqual(decoded.subject, message.subject)
                }
            }
        }
    }

    func test_getBody_providerGone_returns410() async throws {
        let account = makeAccount(oauthUser: "route-\(UUID().uuidString)", email: "me-\(UUID())@example.com")
        try await TestDatabase.withConnection(cleanup: cleanup(accountId: account.id)) { conn in
            try await seedAccount(account, db: conn)
            let provider = StubMailProvider()
            await provider.setBodyError(.messageGone)
            let app = Application(
                router: makeMessageRouter(db: conn, makeProvider: { _ in provider })
            )
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/api/messages/78/body?accountId=\(account.id.uuidString)",
                    method: .get
                ) { response in
                    XCTAssertEqual(response.status, .gone)
                    XCTAssertEqual(try Self.errorCode(from: response.body), "message-gone")
                }
            }
        }
    }

    func test_getBody_providerAuthFailed_returns401() async throws {
        let account = makeAccount(oauthUser: "route-\(UUID().uuidString)", email: "me-\(UUID())@example.com")
        try await TestDatabase.withConnection(cleanup: cleanup(accountId: account.id)) { conn in
            try await seedAccount(account, db: conn)
            let provider = StubMailProvider()
            await provider.setBodyError(.authFailed)
            let app = Application(
                router: makeMessageRouter(db: conn, makeProvider: { _ in provider })
            )
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/api/messages/79/body?accountId=\(account.id.uuidString)",
                    method: .get
                ) { response in
                    XCTAssertEqual(response.status, .unauthorized)
                    XCTAssertEqual(try Self.errorCode(from: response.body), "provider-auth-failed")
                }
            }
        }
    }

    func test_postArchive_providerMovesTheMessage() async throws {
        let account = makeAccount(oauthUser: "route-\(UUID().uuidString)", email: "me-\(UUID())@example.com")
        try await TestDatabase.withConnection(cleanup: cleanup(accountId: account.id)) { conn in
            try await seedAccount(
                Account(
                    id: account.id, provider: .qq, oauthUser: account.oauthUser,
                    email: account.email, credentials: Data([1, 2, 3]),
                    capabilities: MailCapabilities(
                        archiveFolder: true, idle: true, move: true, serverSnippet: true
                    ),
                    isActive: false
                ),
                db: conn
            )
            let provider = StubMailProvider()
            let router = makeMessageRouter(db: conn, makeProvider: { _ in provider })
            let (client, tokens) = makeGmailCollaborators(db: conn)
            ActionsRoutes.register(
                on: router, db: conn, client: client, tokens: tokens,
                logger: Self.testLogger, makeProvider: { _ in provider }
            )
            let app = Application(router: router)
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/api/messages/80/archive?accountId=\(account.id.uuidString)",
                    method: .post
                ) { response in
                    XCTAssertEqual(response.status, .ok)
                    let object = try JSONSerialization.jsonObject(with: Data(buffer: response.body))
                        as? [String: Any]
                    XCTAssertNotNil(object?["actionId"] as? Int64)
                }
            }
            let archived = await provider.archivedRemoteIds
            XCTAssertEqual(archived, ["80"])
        }
    }

    func test_postArchive_capabilityMissing_returns409() async throws {
        let account = makeAccount(oauthUser: "route-\(UUID().uuidString)", email: "me-\(UUID())@example.com")
        try await TestDatabase.withConnection(cleanup: cleanup(accountId: account.id)) { conn in
            try await seedAccount(
                Account(
                    id: account.id, provider: .qq, oauthUser: account.oauthUser,
                    email: account.email, credentials: Data([1, 2, 3]),
                    capabilities: MailCapabilities(
                        archiveFolder: false, idle: true, move: true, serverSnippet: true
                    ),
                    isActive: false
                ),
                db: conn
            )
            let provider = StubMailProvider()
            let router = makeMessageRouter(db: conn, makeProvider: { _ in provider })
            let (client, tokens) = makeGmailCollaborators(db: conn)
            ActionsRoutes.register(
                on: router, db: conn, client: client, tokens: tokens,
                logger: Self.testLogger, makeProvider: { _ in provider }
            )
            let app = Application(router: router)
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/api/messages/81/archive?accountId=\(account.id.uuidString)",
                    method: .post
                ) { response in
                    XCTAssertEqual(response.status, .conflict)
                    XCTAssertEqual(try Self.errorCode(from: response.body), "archive-unavailable")
                }
            }
            let archived = await provider.archivedRemoteIds
            XCTAssertTrue(archived.isEmpty, "a disabled capability must not reach the provider")
        }
    }

    // MARK: - T11: POST /api/messages/{remoteId}/send

    /// Registers message + action routes on one router with the same stub
    /// provider, so a send and its audit row can be exercised end to end.
    private func makeSendRouter(
        db: PostgresConnection,
        provider: any MailProvider
    ) -> Router<BasicRequestContext> {
        let router = makeMessageRouter(db: db, makeProvider: { _ in provider })
        let (client, tokens) = makeGmailCollaborators(db: db)
        ActionsRoutes.register(
            on: router, db: db, client: client, tokens: tokens,
            logger: Self.testLogger, makeProvider: { _ in provider }
        )
        return router
    }

    private func sendBody(_ json: String) -> ByteBuffer {
        ByteBuffer(data: Data(json.utf8))
    }

    func test_postCompose_sendsNewMessageIsIdempotentAndAudits() async throws {
        let account = makeAccount(
            oauthUser: "route-\(UUID().uuidString)",
            email: "me-\(UUID().uuidString)@example.com"
        )
        try await TestDatabase.withConnection(cleanup: cleanup(accountId: account.id)) { conn in
            try await seedAccount(account, db: conn)
            let provider = StubMailProvider()
            await provider.setSendResult("<compose-1@example.com>")
            let app = Application(router: makeSendRouter(db: conn, provider: provider))
            let requestId = UUID().uuidString
            let body = #"{"to":"alice@example.com","subject":"Project kickoff","body":"First note","requestId":"\#(requestId)"}"#

            for _ in 0..<2 {
                try await app.test(.router) { client in
                    try await client.execute(
                        uri: "/api/compose/send?accountId=\(account.id.uuidString)",
                        method: .post,
                        headers: [.contentType: "application/json"],
                        body: sendBody(body)
                    ) { response in
                        XCTAssertEqual(response.status, .ok)
                        let decoded = try Self.iso8601Decoder().decode(
                            SendResponse.self, from: response.body
                        )
                        XCTAssertEqual(decoded.providerMessageId, "<compose-1@example.com>")
                    }
                }
            }

            let sent = await provider.sentOutbounds
            XCTAssertEqual(sent.count, 1)
            let outbound = try XCTUnwrap(sent.first)
            XCTAssertEqual(outbound.to, "alice@example.com")
            XCTAssertEqual(outbound.subject, "Project kickoff")
            XCTAssertEqual(outbound.body, "First note")
            XCTAssertNil(outbound.inReplyTo)
            XCTAssertNil(outbound.references)
            XCTAssertFalse(outbound.isReply)

            let actions = try await AIActionStore.recent(accountId: account.id, db: conn)
            let auditRow = try XCTUnwrap(actions.first { $0.kind == .send })
            XCTAssertEqual(auditRow.payload["type"], "compose")
            XCTAssertEqual(auditRow.payload["to"], "alice@example.com")
            XCTAssertNil(auditRow.payload["remoteId"])
        }
    }

    func test_postCompose_rejectsHeaderInjectionBeforeProvider() async throws {
        let account = makeAccount(
            oauthUser: "route-\(UUID().uuidString)",
            email: "me-\(UUID().uuidString)@example.com"
        )
        try await TestDatabase.withConnection(cleanup: cleanup(accountId: account.id)) { conn in
            try await seedAccount(account, db: conn)
            let provider = StubMailProvider()
            let app = Application(router: makeSendRouter(db: conn, provider: provider))

            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/api/compose/send?accountId=\(account.id.uuidString)",
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: sendBody(#"{"to":"alice@example.com\r\nBcc:evil@example.com","subject":"Hi","body":"Hello"}"#)
                ) { response in
                    XCTAssertEqual(response.status, .badRequest)
                    XCTAssertEqual(try Self.errorCode(from: response.body), "malformed-compose")
                }
            }
            let sent = await provider.sentOutbounds
            XCTAssertTrue(sent.isEmpty)
        }
    }

    func test_postSend_usesStoredThreadingHeadersAndRecordsAuditRow() async throws {
        let account = makeAccount(
            oauthUser: "route-\(UUID().uuidString)",
            email: "me-\(UUID().uuidString)@example.com"
        )
        try await TestDatabase.withConnection(cleanup: cleanup(accountId: account.id)) { conn in
            try await seedAccount(account, db: conn)
            let message = makeHeader(
                accountId: account.id,
                remoteId: "send-\(UUID())",
                from: "alice@example.com",
                subject: "Q3 预算",
                messageIdHeader: "<orig@example.com>",
                references: "<root@example.com> <parent@example.com>"
            )
            try await MessageStore.upsert(message, db: conn)

            let provider = StubMailProvider()
            await provider.setSendResult("<smtp-1@qq.com>")
            let app = Application(router: makeSendRouter(db: conn, provider: provider))

            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/api/messages/\(message.remoteId)/send?accountId=\(account.id.uuidString)",
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: sendBody(#"{"body":"好的，我周五前给答复。"}"#)
                ) { response in
                    XCTAssertEqual(response.status, .ok)
                    let decoded = try Self.iso8601Decoder().decode(
                        SendResponse.self, from: response.body
                    )
                    XCTAssertTrue(decoded.ok)
                    XCTAssertEqual(decoded.providerMessageId, "<smtp-1@qq.com>")
                }
            }

            let sent = await provider.sentOutbounds
            XCTAssertEqual(sent.count, 1, "the provider must be asked exactly once")
            let outbound = try XCTUnwrap(sent.first)
            XCTAssertEqual(outbound.fromEmail, account.email)
            XCTAssertEqual(outbound.to, "alice@example.com")
            XCTAssertEqual(outbound.subject, "Q3 预算")
            XCTAssertEqual(outbound.body, "好的，我周五前给答复。")
            XCTAssertEqual(outbound.inReplyTo, "<orig@example.com>")
            XCTAssertEqual(
                outbound.references,
                "<root@example.com> <parent@example.com> <orig@example.com>",
                "References must extend the parent chain with the parent's own id"
            )

            let actions = try await AIActionStore.recent(accountId: account.id, db: conn)
            let auditRow = try XCTUnwrap(actions.first { $0.kind == .send })
            XCTAssertEqual(auditRow.payload["remoteId"], message.remoteId)
            XCTAssertEqual(auditRow.payload["to"], "alice@example.com")

            // Sending is final: the audit row exists, but undo must refuse it.
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/api/actions/\(auditRow.id)/undo?accountId=\(account.id.uuidString)",
                    method: .post
                ) { response in
                    XCTAssertEqual(response.status, .badRequest)
                    XCTAssertEqual(try Self.errorCode(from: response.body), "not-undoable")
                }
            }
        }
    }

    func test_postSend_withoutReferencesUsesOnlyTheParentMessageId() async throws {
        let account = makeAccount(
            oauthUser: "route-\(UUID().uuidString)",
            email: "me-\(UUID().uuidString)@example.com"
        )
        try await TestDatabase.withConnection(cleanup: cleanup(accountId: account.id)) { conn in
            try await seedAccount(account, db: conn)
            let message = makeHeader(
                accountId: account.id,
                remoteId: "send-\(UUID())",
                from: "alice@example.com",
                messageIdHeader: "<only@example.com>"
            )
            try await MessageStore.upsert(message, db: conn)

            let provider = StubMailProvider()
            let app = Application(router: makeSendRouter(db: conn, provider: provider))
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/api/messages/\(message.remoteId)/send?accountId=\(account.id.uuidString)",
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: sendBody(#"{"body":"ok"}"#)
                ) { response in
                    XCTAssertEqual(response.status, .ok)
                }
            }

            let sent = await provider.sentOutbounds
            let outbound = try XCTUnwrap(sent.first)
            XCTAssertEqual(outbound.inReplyTo, "<only@example.com>")
            XCTAssertEqual(outbound.references, "<only@example.com>")
        }
    }

    func test_postSend_sameRequestId_doesNotSendTwice() async throws {
        let account = makeAccount(
            oauthUser: "route-\(UUID().uuidString)",
            email: "me-\(UUID().uuidString)@example.com"
        )
        try await TestDatabase.withConnection(cleanup: cleanup(accountId: account.id)) { conn in
            try await seedAccount(account, db: conn)
            let message = makeHeader(
                accountId: account.id,
                remoteId: "send-idem-\(UUID())",
                from: "alice@example.com",
                messageIdHeader: "<idem@example.com>"
            )
            try await MessageStore.upsert(message, db: conn)

            let requestId = UUID().uuidString
            let body = #"{"body":"hello","requestId":"\#(requestId)"}"#
            let provider = StubMailProvider()
            await provider.setSendResult("<idem-1@example.com>")
            let app = Application(router: makeSendRouter(db: conn, provider: provider))

            for _ in 0..<2 {
                try await app.test(.router) { client in
                    try await client.execute(
                        uri: "/api/messages/\(message.remoteId)/send?accountId=\(account.id.uuidString)",
                        method: .post,
                        headers: [.contentType: "application/json"],
                        body: sendBody(body)
                    ) { response in
                        XCTAssertEqual(response.status, .ok)
                        let decoded = try Self.iso8601Decoder().decode(
                            SendResponse.self,
                            from: response.body
                        )
                        XCTAssertEqual(decoded.providerMessageId, "<idem-1@example.com>")
                    }
                }
            }

            let sent = await provider.sentOutbounds
            XCTAssertEqual(sent.count, 1)
        }
    }

    func test_postSend_malformedBody_returns400() async throws {
        let account = makeAccount(
            oauthUser: "route-\(UUID().uuidString)",
            email: "me-\(UUID().uuidString)@example.com"
        )
        try await TestDatabase.withConnection(cleanup: cleanup(accountId: account.id)) { conn in
            try await seedAccount(account, db: conn)
            let message = makeHeader(
                accountId: account.id,
                remoteId: "send-\(UUID())",
                from: "alice@example.com",
                messageIdHeader: "<orig@example.com>"
            )
            try await MessageStore.upsert(message, db: conn)

            let provider = StubMailProvider()
            let app = Application(router: makeSendRouter(db: conn, provider: provider))
            for body in [#"{}"#, #"{"body":""}"#, #"{"body":"   "}"#, "{not json"] {
                try await app.test(.router) { client in
                    try await client.execute(
                        uri: "/api/messages/\(message.remoteId)/send?accountId=\(account.id.uuidString)",
                        method: .post,
                        headers: [.contentType: "application/json"],
                        body: sendBody(body)
                    ) { response in
                        XCTAssertEqual(response.status, .badRequest, "body: \(body)")
                        XCTAssertEqual(try Self.errorCode(from: response.body), "malformed-body")
                    }
                }
            }
            let sent = await provider.sentOutbounds
            XCTAssertTrue(sent.isEmpty, "a malformed request must not reach the provider")
        }
    }

    func test_postSend_unknownMessage_returns404() async throws {
        let account = makeAccount(
            oauthUser: "route-\(UUID().uuidString)",
            email: "me-\(UUID().uuidString)@example.com"
        )
        try await TestDatabase.withConnection(cleanup: cleanup(accountId: account.id)) { conn in
            try await seedAccount(account, db: conn)
            let provider = StubMailProvider()
            let app = Application(router: makeSendRouter(db: conn, provider: provider))
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/api/messages/ghost/send?accountId=\(account.id.uuidString)",
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: sendBody(#"{"body":"hello"}"#)
                ) { response in
                    XCTAssertEqual(response.status, .notFound)
                    XCTAssertEqual(try Self.errorCode(from: response.body), "unknown-message")
                }
            }
            let sent = await provider.sentOutbounds
            XCTAssertTrue(sent.isEmpty)
        }
    }

    func test_postSend_providerNotConfigured_returns503() async throws {
        let account = makeAccount(
            oauthUser: "route-\(UUID().uuidString)",
            email: "me-\(UUID().uuidString)@example.com"
        )
        try await TestDatabase.withConnection(cleanup: cleanup(accountId: account.id)) { conn in
            try await seedAccount(account, db: conn)
            let message = makeHeader(
                accountId: account.id,
                remoteId: "send-\(UUID())",
                from: "alice@example.com",
                messageIdHeader: "<orig@example.com>"
            )
            try await MessageStore.upsert(message, db: conn)
            let app = Application(router: makeMessageRouter(db: conn, makeProvider: { _ in nil }))
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/api/messages/\(message.remoteId)/send?accountId=\(account.id.uuidString)",
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: sendBody(#"{"body":"hello"}"#)
                ) { response in
                    XCTAssertEqual(response.status, .serviceUnavailable)
                    XCTAssertEqual(try Self.errorCode(from: response.body), "provider-not-configured")
                }
            }
        }
    }

    func test_postSend_providerAuthFailed_returns401AndWritesNoAuditRow() async throws {
        let account = makeAccount(
            oauthUser: "route-\(UUID().uuidString)",
            email: "me-\(UUID().uuidString)@example.com"
        )
        try await TestDatabase.withConnection(cleanup: cleanup(accountId: account.id)) { conn in
            try await seedAccount(account, db: conn)
            let message = makeHeader(
                accountId: account.id,
                remoteId: "send-\(UUID())",
                from: "alice@example.com",
                messageIdHeader: "<orig@example.com>"
            )
            try await MessageStore.upsert(message, db: conn)

            let provider = StubMailProvider()
            await provider.setSendError(.authFailed)
            let app = Application(router: makeSendRouter(db: conn, provider: provider))
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/api/messages/\(message.remoteId)/send?accountId=\(account.id.uuidString)",
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: sendBody(#"{"body":"hello"}"#)
                ) { response in
                    XCTAssertEqual(response.status, .unauthorized)
                    XCTAssertEqual(try Self.errorCode(from: response.body), "smtp-auth-failed")
                }
            }
            let actions = try await AIActionStore.recent(accountId: account.id, db: conn)
            XCTAssertNil(actions.first { $0.kind == .send }, "a failed send is not audited")
        }
    }

    func test_postSend_providerUnreachable_returns502AndWritesNoAuditRow() async throws {
        let account = makeAccount(
            oauthUser: "route-\(UUID().uuidString)",
            email: "me-\(UUID().uuidString)@example.com"
        )
        try await TestDatabase.withConnection(cleanup: cleanup(accountId: account.id)) { conn in
            try await seedAccount(account, db: conn)
            let message = makeHeader(
                accountId: account.id,
                remoteId: "send-\(UUID())",
                from: "alice@example.com",
                messageIdHeader: "<orig@example.com>"
            )
            try await MessageStore.upsert(message, db: conn)

            let provider = StubMailProvider()
            await provider.setSendError(.unreachable("smtp-421"))
            let app = Application(router: makeSendRouter(db: conn, provider: provider))
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/api/messages/\(message.remoteId)/send?accountId=\(account.id.uuidString)",
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: sendBody(#"{"body":"hello"}"#)
                ) { response in
                    XCTAssertEqual(response.status, .badGateway)
                    XCTAssertEqual(try Self.errorCode(from: response.body), "smtp-send-failed")
                }
            }
            let actions = try await AIActionStore.recent(accountId: account.id, db: conn)
            XCTAssertNil(actions.first { $0.kind == .send })
        }
    }

    // MARK: - T12: undo regressions (archive / classify-override / terminal kinds)

    /// Account row with a usable archive folder — the archive route refuses to
    /// run without it (409).
    private func seedArchiveCapableAccount(
        _ account: Account, db: PostgresConnection
    ) async throws {
        try await seedAccount(
            Account(
                id: account.id, provider: .qq, oauthUser: account.oauthUser,
                email: account.email, credentials: Data([1, 2, 3]),
                capabilities: MailCapabilities(
                    archiveFolder: true, idle: true, move: true, serverSnippet: true
                ),
                isActive: false
            ),
            db: db
        )
    }

    /// Regression: the archive audit row stores the remote outcome under
    /// `remoteWrite`, and undo must read that same key — a mismatch left the
    /// local flag flipped while the message stayed in the archive folder.
    func test_undoArchive_restoresLocalStateAndUnarchivesRemotely() async throws {
        let account = makeAccount(
            oauthUser: "route-\(UUID().uuidString)",
            email: "me-\(UUID().uuidString)@example.com"
        )
        try await TestDatabase.withConnection(cleanup: cleanup(accountId: account.id)) { conn in
            try await seedArchiveCapableAccount(account, db: conn)
            let message = makeHeader(
                accountId: account.id, remoteId: "undo-\(UUID())", from: "alice@example.com"
            )
            try await MessageStore.upsert(message, db: conn)
            let provider = StubMailProvider()
            let app = Application(router: makeSendRouter(db: conn, provider: provider))

            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/api/messages/\(message.remoteId)/archive?accountId=\(account.id.uuidString)",
                    method: .post
                ) { response in
                    XCTAssertEqual(response.status, .ok)
                }
            }
            let archived = try await MessageStore.find(
                remoteId: message.remoteId, accountId: account.id, db: conn
            )
            XCTAssertEqual(archived?.isArchived, true)

            let actions = try await AIActionStore.recent(accountId: account.id, db: conn)
            let archiveRow = try XCTUnwrap(
                actions.first { $0.kind == .archive && $0.payload["remoteId"] == message.remoteId }
            )
            XCTAssertEqual(archiveRow.payload["remoteWrite"], "true")

            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/api/actions/\(archiveRow.id)/undo?accountId=\(account.id.uuidString)",
                    method: .post
                ) { response in
                    XCTAssertEqual(response.status, .ok)
                }
            }

            let restored = try await MessageStore.find(
                remoteId: message.remoteId, accountId: account.id, db: conn
            )
            XCTAssertEqual(restored?.isArchived, false)
            let unarchived = await provider.unarchivedRemoteIds
            XCTAssertEqual(
                unarchived, [message.remoteId],
                "a remotely archived message must be moved back remotely too"
            )
        }
    }

    /// Undoing an auto-archive retires its rule (V2 C2): otherwise the next
    /// sync round re-archives the same sender. Undoing a manual archive
    /// leaves rules alone.
    func test_undoAutoArchive_retiresTheRule_manualUndoKeepsRules() async throws {
        let account = makeAccount(
            oauthUser: "route-\(UUID().uuidString)",
            email: "me-\(UUID().uuidString)@example.com"
        )
        try await TestDatabase.withConnection(cleanup: cleanup(accountId: account.id)) { conn in
            try await seedArchiveCapableAccount(account, db: conn)
            let message = makeHeader(
                accountId: account.id, remoteId: "rule-\(UUID())", from: "noise@example.com"
            )
            try await MessageStore.upsert(message, db: conn)
            _ = try await AutoArchiveStore.create(
                accountId: account.id, senderAddress: "noise@example.com", db: conn
            )
            let provider = StubMailProvider()
            let app = Application(router: makeSendRouter(db: conn, provider: provider))

            // Manual archive + undo: the rule survives.
            var manualActionId: Int64 = 0
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/api/messages/\(message.remoteId)/archive?accountId=\(account.id.uuidString)",
                    method: .post
                ) { response in
                    XCTAssertEqual(response.status, .ok)
                }
            }
            let manual = try await AIActionStore.recent(accountId: account.id, db: conn)
            let manualRow = manual.first { $0.kind == .archive }
            manualActionId = try XCTUnwrap(manualRow?.id)
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/api/actions/\(manualActionId)/undo?accountId=\(account.id.uuidString)",
                    method: .post
                ) { response in
                    XCTAssertEqual(response.status, .ok)
                }
            }
            let rulesAfterManualUndo = try await AutoArchiveStore.senderAddresses(accountId: account.id, db: conn)
            XCTAssertEqual(rulesAfterManualUndo, ["noise@example.com"])

            // Auto-archive + undo: the rule is retired.
            _ = try await AIActionStore.record(
                accountId: account.id,
                kind: .archive,
                payload: [
                    "remoteId": message.remoteId,
                    "autoRule": "true",
                    "sender": "noise@example.com",
                ],
                db: conn
            )
            let auto = try await AIActionStore.recent(accountId: account.id, db: conn)
            let autoRow = auto.first { $0.kind == .archive && $0.payload["autoRule"] == "true" }
            let autoId = try XCTUnwrap(autoRow?.id)
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/api/actions/\(autoId)/undo?accountId=\(account.id.uuidString)",
                    method: .post
                ) { response in
                    XCTAssertEqual(response.status, .ok)
                }
            }
            let rulesAfterAutoUndo = try await AutoArchiveStore.senderAddresses(accountId: account.id, db: conn)
            XCTAssertTrue(
                rulesAfterAutoUndo.isEmpty,
                "undoing an auto-archive must retire its rule"
            )
            let restored = try await MessageStore.find(
                remoteId: message.remoteId, accountId: account.id, db: conn
            )
            XCTAssertEqual(restored?.isArchived, false)
        }
    }

    /// A remote archive failure is a failed operation: no local state and no
    /// audit row may claim success.
    func test_postArchive_whenRemoteWriteFails_changesNothing() async throws {
        let account = makeAccount(
            oauthUser: "route-\(UUID().uuidString)",
            email: "me-\(UUID().uuidString)@example.com"
        )
        try await TestDatabase.withConnection(cleanup: cleanup(accountId: account.id)) { conn in
            try await seedArchiveCapableAccount(account, db: conn)
            let message = makeHeader(
                accountId: account.id, remoteId: "undo-\(UUID())", from: "alice@example.com"
            )
            try await MessageStore.upsert(message, db: conn)
            let provider = StubMailProvider()
            await provider.setArchiveError(.protocolError("move-rejected"))
            let app = Application(router: makeSendRouter(db: conn, provider: provider))

            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/api/messages/\(message.remoteId)/archive?accountId=\(account.id.uuidString)",
                    method: .post
                ) { response in
                    XCTAssertEqual(response.status, .badGateway)
                }
            }
            let stored = try await MessageStore.find(
                remoteId: message.remoteId,
                accountId: account.id,
                db: conn
            )
            XCTAssertEqual(stored?.isArchived, false)
            let actions = try await AIActionStore.recent(accountId: account.id, db: conn)
            XCTAssertTrue(actions.allSatisfy {
                !($0.kind == .archive && $0.payload["remoteId"] == message.remoteId)
            })
        }
    }

    /// Regression: the classify audit row must store a valid `BriefingGroup`
    /// raw value, or undo cannot parse `fromGroup` and silently skips the
    /// counter-override.
    func test_undoClassifyOverride_flipsTheSenderBack() async throws {
        let account = makeAccount(
            oauthUser: "route-\(UUID().uuidString)",
            email: "me-\(UUID().uuidString)@example.com"
        )
        try await TestDatabase.withConnection(cleanup: cleanup(accountId: account.id)) { conn in
            try await seedAccount(account, db: conn)
            let message = makeHeader(
                accountId: account.id, remoteId: "co-\(UUID())", from: "alice@example.com"
            )
            try await MessageStore.upsert(message, db: conn)
            let provider = StubMailProvider()
            let app = Application(router: makeSendRouter(db: conn, provider: provider))

            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/api/messages/\(message.remoteId)/classify?accountId=\(account.id.uuidString)",
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: sendBody(#"{"toGroup":"safeToArchive"}"#)
                ) { response in
                    XCTAssertEqual(response.status, .ok)
                }
            }
            let afterOverride = try await AIActionStore.overridesBySender(
                accountId: account.id, db: conn
            )
            XCTAssertEqual(afterOverride["alice@example.com"], .safeToArchive)

            let actions = try await AIActionStore.recent(accountId: account.id, db: conn)
            let row = try XCTUnwrap(actions.first { $0.kind == .classifyOverride })
            XCTAssertEqual(row.payload["fromGroup"], BriefingGroup.needsReply.rawValue)

            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/api/actions/\(row.id)/undo?accountId=\(account.id.uuidString)",
                    method: .post
                ) { response in
                    XCTAssertEqual(response.status, .ok)
                }
            }
            let afterUndo = try await AIActionStore.overridesBySender(
                accountId: account.id, db: conn
            )
            XCTAssertEqual(
                afterUndo["alice@example.com"], .needsReply,
                "undo must write a counter-override back to the original group"
            )
        }
    }

    /// A saved override must affect the next Briefing request, not just the
    /// ai_overrides table.
    func test_classifyOverride_changesNextBriefingResponse() async throws {
        let account = makeAccount(
            oauthUser: "route-\(UUID().uuidString)",
            email: "me-\(UUID().uuidString)@example.com"
        )
        try await TestDatabase.withConnection(cleanup: cleanup(accountId: account.id)) { conn in
            try await seedAccount(account, db: conn)
            let message = makeHeader(
                accountId: account.id,
                remoteId: "co-brief-\(UUID())",
                from: "alice@example.com"
            )
            try await MessageStore.upsert(message, db: conn)

            let provider = StubMailProvider()
            let router = makeMessageRouter(db: conn, makeProvider: { _ in provider })
            let (client, tokens) = makeGmailCollaborators(db: conn)
            ActionsRoutes.register(
                on: router, db: conn, client: client, tokens: tokens,
                logger: Self.testLogger, makeProvider: { _ in provider }
            )
            BriefingRoutes.register(on: router, db: conn, logger: Self.testLogger)
            let app = Application(router: router)

            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/api/messages/\(message.remoteId)/classify?accountId=\(account.id.uuidString)",
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: sendBody(#"{"fromGroup":"needsReply","toGroup":"subscriptionNoise"}"#)
                ) { response in
                    XCTAssertEqual(response.status, .ok)
                }
            }
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
                    let item = try XCTUnwrap(decoded.items.first {
                        $0.message.remoteId == message.remoteId
                    })
                    XCTAssertEqual(item.group, .subscriptionNoise)
                    XCTAssertEqual(item.reason, .userOverride)
                }
            }
        }
    }

    func test_undoExpiredAction_returns410() async throws {
        let account = makeAccount(
            oauthUser: "route-\(UUID().uuidString)",
            email: "me-\(UUID().uuidString)@example.com"
        )
        try await TestDatabase.withConnection(cleanup: cleanup(accountId: account.id)) { conn in
            try await seedAccount(account, db: conn)
            let action = try await AIActionStore.record(
                accountId: account.id,
                kind: .archive,
                payload: ["remoteId": "expired-1", "remoteWrite": "false"],
                db: conn
            )
            try await conn.query(
                "UPDATE ai_actions SET expires_at = now() - interval '1 second' WHERE id = $1",
                [PostgresData(int64: action.id)]
            ).get()
            let provider = StubMailProvider()
            let app = Application(router: makeSendRouter(db: conn, provider: provider))

            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/api/actions/\(action.id)/undo?accountId=\(account.id.uuidString)",
                    method: .post
                ) { response in
                    XCTAssertEqual(response.status, .gone)
                    XCTAssertEqual(try Self.errorCode(from: response.body), "action-expired")
                }
            }
        }
    }

    func test_undoUnsubscribe_isNotUndoable() async throws {
        let account = makeAccount(
            oauthUser: "route-\(UUID().uuidString)",
            email: "me-\(UUID().uuidString)@example.com"
        )
        try await TestDatabase.withConnection(cleanup: cleanup(accountId: account.id)) { conn in
            try await seedAccount(account, db: conn)
            let row = try await AIActionStore.record(
                accountId: account.id,
                kind: .unsubscribe,
                payload: ["remoteId": "un-1", "publisher": "example.com", "remote": "true"],
                db: conn
            )
            let provider = StubMailProvider()
            let app = Application(router: makeSendRouter(db: conn, provider: provider))

            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/api/actions/\(row.id)/undo?accountId=\(account.id.uuidString)",
                    method: .post
                ) { response in
                    XCTAssertEqual(response.status, .badRequest)
                    XCTAssertEqual(try Self.errorCode(from: response.body), "not-undoable")
                }
            }
        }
    }

    /// Mirrors the audit row DraftRoutes writes; a stored draft cannot be
    /// un-created, so undo refuses instead of 500ing.
    func test_undoDraftCreate_isNotUndoable() async throws {
        let account = makeAccount(
            oauthUser: "route-\(UUID().uuidString)",
            email: "me-\(UUID().uuidString)@example.com"
        )
        try await TestDatabase.withConnection(cleanup: cleanup(accountId: account.id)) { conn in
            try await seedAccount(account, db: conn)
            let row = try await AIActionStore.record(
                accountId: account.id, kind: .draftCreate,
                payload: ["remoteId": "draft-1", "variantCount": "3"],
                db: conn
            )
            let provider = StubMailProvider()
            let app = Application(router: makeSendRouter(db: conn, provider: provider))

            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/api/actions/\(row.id)/undo?accountId=\(account.id.uuidString)",
                    method: .post
                ) { response in
                    XCTAssertEqual(response.status, .badRequest)
                    XCTAssertEqual(try Self.errorCode(from: response.body), "not-undoable")
                }
            }
        }
    }
}

/// Test-only rendezvous for the concurrent double-POST regression: both probes
/// park here until both requests have arrived, guaranteeing both passed `find`
/// (saw no row) before either `upsert`ed. `release()` is a safety valve so a
/// serialized harness fails an assertion instead of hanging the suite.
private actor ProbeGate {
    private var arrivals = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var released = false

    func arriveAndWait() async {
        if released { return }
        arrivals += 1
        if arrivals >= 2 {
            released = true
            let parked = waiters
            waiters.removeAll()
            for waiter in parked { waiter.resume() }
        } else {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if released {
                    continuation.resume()
                } else {
                    waiters.append(continuation)
                }
            }
        }
    }

    func release() {
        released = true
        let parked = waiters
        waiters.removeAll()
        for waiter in parked { waiter.resume() }
    }
}
