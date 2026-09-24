import XCTest
import Foundation
import Hummingbird
import HummingbirdTesting
import Logging
import PostgresNIO
import LagoonKit
@testable import LagoonServer

/// Route-level tests for the one-click unsubscribe resolution chain:
/// live header → stored candidates → body scan → 422, plus both P1 fixes
/// (header-read failure must not mask stored links; bare unbracketed header
/// URLs must resolve). The outbound HTTP hit is stubbed through
/// `ActionsRoutes.hitUnsubscribeProbe`, so the suite stays offline.
final class UnsubscribeRouteTests: XCTestCase {
    private static let logger = Logger(label: "unsubscribe-route-tests")

    override func tearDown() {
        ActionsRoutes.hitUnsubscribeProbe = nil
        super.tearDown()
    }

    // MARK: - Harness

    private func makeAccount() -> Account {
        Account(
            id: UUID(),
            provider: .qq,
            oauthUser: "unsub-\(UUID().uuidString)",
            email: "unsub-\(UUID().uuidString)@qq.com",
            credentials: nil
        )
    }

    private func cleanup(_ account: Account) -> @Sendable (PostgresConnection) async -> Void {
        { conn in
            try? await TestDatabase.deleteMessages(accountId: account.id, db: conn)
            try? await TestDatabase.deleteAccount(id: account.id, db: conn)
        }
    }

    private func header(accountId: UUID, remoteId: String) -> MessageHeader {
        MessageHeader(
            id: UUID(),
            accountId: accountId,
            remoteId: remoteId,
            threadId: "t-\(remoteId)",
            fromAddress: "alice@example.com",
            fromName: nil,
            subject: "news",
            snippet: nil,
            receivedAt: Date(),
            isRead: false,
            isArchived: false
        )
    }

    private static func makeRouter(
        provider: StubMailProvider, db: PostgresConnection
    ) -> Router<BasicRequestContext> {
        let router = Router<BasicRequestContext>()
        let session = URLSession(configuration: .ephemeral)
        let client = GmailClient(session: session)
        let tokens = GmailTokenService(
            db: db,
            oauth: GoogleOAuthClient(
                clientID: "t", clientSecret: "s",
                redirectURI: "http://127.0.0.1:9/cb", session: session
            ),
            logger: logger
        )
        ActionsRoutes.register(
            on: router, db: db, client: client, tokens: tokens,
            logger: logger, makeProvider: { _ in provider }
        )
        return router
    }

    /// Records every URL the endpoint actually tried to hit.
    private final class URLRecorder: @unchecked Sendable {
        private(set) var urls: [URL] = []
        func append(_ url: URL) { urls.append(url) }
    }

    private static func body(of response: TestResponse) -> String {
        String(decoding: Data(buffer: response.body), as: UTF8.self)
    }

    // MARK: - Tests

    /// Nothing anywhere → 422 with the exact code the client renders as
    /// "未检测到退订链接"; the body scan must have been attempted and no
    /// HTTP hit may fire.
    func test_nothingFound_returnsUnavailable() async throws {
        let account = makeAccount()
        let provider = StubMailProvider()
        await provider.configureUnsubscribe(rawHeaders: [:], bodyHTML: "<p>hello reader</p>")
        let recorder = URLRecorder()
        ActionsRoutes.hitUnsubscribeProbe = { url in
            recorder.append(url)
            return false
        }

        try await TestDatabase.withConnection(cleanup: cleanup(account)) { conn in
            try await AccountStore.upsert(account, credentials: Data([1, 2, 3]), db: conn)
            try await MessageStore.upsert(
                self.header(accountId: account.id, remoteId: "u-none"), db: conn
            )
            let app = Application(router: Self.makeRouter(provider: provider, db: conn))
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/api/messages/u-none/unsubscribe?accountId=\(account.id.uuidString)",
                    method: .post
                ) { response in
                    XCTAssertEqual(response.status, .unprocessableContent)
                    XCTAssertTrue(Self.body(of: response).contains("unsubscribe-unavailable"))
                }
            }
            let bodyFetches = await provider.bodyFetchCount
            XCTAssertEqual(bodyFetches, 1, "the body scan is the last resort and must run")
            XCTAssertEqual(recorder.urls.count, 0, "no candidate → nothing may be fetched")
        }
    }

    /// Stored candidates resolve WITHOUT touching the body, hit exactly the
    /// stored URL, and apply the local effects (read + archived + action row).
    func test_storedLink_resolvesWithoutBodyFetch() async throws {
        let account = makeAccount()
        let provider = StubMailProvider()
        await provider.configureUnsubscribe(rawHeaders: [:])
        let recorder = URLRecorder()
        ActionsRoutes.hitUnsubscribeProbe = { url in
            recorder.append(url)
            return true
        }

        try await TestDatabase.withConnection(cleanup: cleanup(account)) { conn in
            try await AccountStore.upsert(account, credentials: Data([1, 2, 3]), db: conn)
            try await MessageStore.upsert(
                self.header(accountId: account.id, remoteId: "u-stored"), db: conn
            )
            try await MessageStore.mergeUnsubscribeLinks(
                remoteId: "u-stored", accountId: account.id,
                // Literal public IP: the SSRF guard resolves hostnames, and
                // test fixtures must stay offline-deterministic (a bare
                // example.com subdomain does not resolve → rejected).
                links: ["https://8.8.8.8/unsubscribe?u=1"], db: conn
            )
            let app = Application(router: Self.makeRouter(provider: provider, db: conn))
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/api/messages/u-stored/unsubscribe?accountId=\(account.id.uuidString)",
                    method: .post
                ) { response in
                    XCTAssertEqual(response.status, .ok, Self.body(of: response))
                    XCTAssertTrue(Self.body(of: response).contains("\"unsubscribed\":true"))
                }
            }
            let bodyFetches = await provider.bodyFetchCount
            XCTAssertEqual(bodyFetches, 0, "stored candidates must short-circuit the body fetch")
            XCTAssertEqual(
                recorder.urls.map(\.absoluteString),
                ["https://8.8.8.8/unsubscribe?u=1"]
            )

            let row = try await MessageStore.find(
                remoteId: "u-stored", accountId: account.id, db: conn
            )
            XCTAssertEqual(row?.isRead, true, "success marks the message read")
            XCTAssertEqual(row?.isArchived, true, "success archives locally")
            let actions = try await conn.query(
                "SELECT count(*) AS n FROM ai_actions WHERE account_id = $1 AND kind = 'unsubscribe'",
                [PostgresData(uuid: account.id)]
            ).get()
            let n = try actions.rows.first?.makeRandomAccess()["n"].decode(Int.self)
            XCTAssertEqual(n, 1, "the action must be recorded for undo history")
        }
    }

    /// A bare (unbracketed) List-Unsubscribe header URL — the pre-fix
    /// angle-bracket-only parser dropped these.
    func test_bareHeaderURL_resolves() async throws {
        let account = makeAccount()
        let provider = StubMailProvider()
        await provider.configureUnsubscribe(
            rawHeaders: ["list-unsubscribe": "https://1.1.1.1/unsubscribe"]
        )
        let recorder = URLRecorder()
        ActionsRoutes.hitUnsubscribeProbe = { url in
            recorder.append(url)
            return true
        }

        try await TestDatabase.withConnection(cleanup: cleanup(account)) { conn in
            try await AccountStore.upsert(account, credentials: Data([1, 2, 3]), db: conn)
            try await MessageStore.upsert(
                self.header(accountId: account.id, remoteId: "u-bare"), db: conn
            )
            let app = Application(router: Self.makeRouter(provider: provider, db: conn))
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/api/messages/u-bare/unsubscribe?accountId=\(account.id.uuidString)",
                    method: .post
                ) { response in
                    XCTAssertEqual(response.status, .ok, Self.body(of: response))
                }
            }
            XCTAssertEqual(
                recorder.urls.map(\.absoluteString),
                ["https://1.1.1.1/unsubscribe"]
            )
        }
    }

    /// mailto-only header stays "manual required" (pre-existing contract).
    func test_mailtoHeader_requiresManual() async throws {
        let account = makeAccount()
        let provider = StubMailProvider()
        await provider.configureUnsubscribe(
            rawHeaders: ["list-unsubscribe": "<mailto:bye@example.com>"]
        )
        ActionsRoutes.hitUnsubscribeProbe = { _ in
            XCTFail("mailto must never be fetched")
            return false
        }

        try await TestDatabase.withConnection(cleanup: cleanup(account)) { conn in
            try await AccountStore.upsert(account, credentials: Data([1, 2, 3]), db: conn)
            try await MessageStore.upsert(
                self.header(accountId: account.id, remoteId: "u-mailto"), db: conn
            )
            let app = Application(router: Self.makeRouter(provider: provider, db: conn))
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/api/messages/u-mailto/unsubscribe?accountId=\(account.id.uuidString)",
                    method: .post
                ) { response in
                    XCTAssertEqual(response.status, .unprocessableContent)
                    XCTAssertTrue(Self.body(of: response).contains("unsubscribe-manual-required"))
                }
            }
        }
    }

    /// Header read fails but stored links exist → still resolves (the P1
    /// fix: a provider hiccup must not mask harvestable candidates).
    func test_headerReadFails_storedStillResolves() async throws {
        let account = makeAccount()
        let provider = StubMailProvider()
        await provider.configureUnsubscribe(rawHeaders: [:], headerError: .messageGone)
        let recorder = URLRecorder()
        ActionsRoutes.hitUnsubscribeProbe = { url in
            recorder.append(url)
            return true
        }

        try await TestDatabase.withConnection(cleanup: cleanup(account)) { conn in
            try await AccountStore.upsert(account, credentials: Data([1, 2, 3]), db: conn)
            try await MessageStore.upsert(
                self.header(accountId: account.id, remoteId: "u-hdrfail"), db: conn
            )
            try await MessageStore.mergeUnsubscribeLinks(
                remoteId: "u-hdrfail", accountId: account.id,
                links: ["https://9.9.9.9/optout"], db: conn
            )
            let app = Application(router: Self.makeRouter(provider: provider, db: conn))
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/api/messages/u-hdrfail/unsubscribe?accountId=\(account.id.uuidString)",
                    method: .post
                ) { response in
                    XCTAssertEqual(response.status, .ok, Self.body(of: response))
                }
            }
            XCTAssertEqual(recorder.urls.map(\.absoluteString), ["https://9.9.9.9/optout"])
        }
    }

    /// Header read fails and nothing is stored → the provider error must
    /// surface; a 422 "未检测到退订链接" would be a lie (we could not check).
    func test_headerReadFails_nothingStored_returnsProviderError() async throws {
        let account = makeAccount()
        let provider = StubMailProvider()
        await provider.configureUnsubscribe(rawHeaders: [:], headerError: .messageGone)
        ActionsRoutes.hitUnsubscribeProbe = { _ in
            XCTFail("no candidate may be fetched")
            return false
        }

        try await TestDatabase.withConnection(cleanup: cleanup(account)) { conn in
            try await AccountStore.upsert(account, credentials: Data([1, 2, 3]), db: conn)
            try await MessageStore.upsert(
                self.header(accountId: account.id, remoteId: "u-hdrfail2"), db: conn
            )
            let app = Application(router: Self.makeRouter(provider: provider, db: conn))
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/api/messages/u-hdrfail2/unsubscribe?accountId=\(account.id.uuidString)",
                    method: .post
                ) { response in
                    XCTAssertNotEqual(response.status, .unprocessableContent)
                    XCTAssertFalse(
                        Self.body(of: response).contains("unsubscribe-unavailable"),
                        "could-not-check must not be reported as no-link"
                    )
                }
            }
        }
    }
}
