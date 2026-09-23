import XCTest
import Foundation
import Logging
import Hummingbird
import PostgresNIO
@testable import LagoonServer
@testable import LagoonKit

/// Covers `BodyStore` (durable write-through bodies, V2 A3) and the search
/// route's body recall: put/get roundtrip, overwrite, header-cascade delete,
/// route write-through, and body-text search with LIKE-special escaping.
final class BodyStoreTests: XCTestCase {
    private static let logger = Logger(label: "body-store-tests")

    private func makeAccount() -> Account {
        Account(
            id: UUID(),
            provider: .qq,
            oauthUser: "body-\(UUID().uuidString)",
            email: "body-\(UUID().uuidString)@qq.com",
            credentials: nil
        )
    }

    private func seed(_ account: Account, db: PostgresConnection) async throws {
        try await AccountStore.upsert(account, credentials: Data([1, 2, 3]), db: db)
    }

    private func header(accountId: UUID, remoteId: String, subject: String) -> MessageHeader {
        MessageHeader(
            id: UUID(),
            accountId: accountId,
            remoteId: remoteId,
            threadId: "t-\(remoteId)",
            fromAddress: "alice@example.com",
            fromName: nil,
            subject: subject,
            snippet: nil,
            receivedAt: Date(),
            isRead: false,
            isArchived: false
        )
    }

    private func body(text: String) -> FetchedBody {
        FetchedBody(text: text, html: "<p>\(text)</p>", attachments: [], hasMore: false)
    }

    private func cleanup(_ account: Account) -> @Sendable (PostgresConnection) async -> Void {
        { conn in
            try? await TestDatabase.deleteMessages(accountId: account.id, db: conn)
            try? await TestDatabase.deleteAccount(id: account.id, db: conn)
        }
    }

    func test_put_get_roundTripsTextHtmlAndFlags() async throws {
        let account = makeAccount()
        try await TestDatabase.withConnection(cleanup: cleanup(account)) { conn in
            try await seed(account, db: conn)
            try await MessageStore.upsert(header(accountId: account.id, remoteId: "b1", subject: "s"), db: conn)

            let missing = try await BodyStore.get(accountId: account.id, remoteId: "b1", db: conn)
            XCTAssertNil(missing, "no row before the first open")

            try await BodyStore.put(
                accountId: account.id, remoteId: "b1",
                body: FetchedBody(text: "hello body", html: "<p>hi</p>", attachments: [], hasMore: true),
                db: conn
            )
            let fetched = try await BodyStore.get(accountId: account.id, remoteId: "b1", db: conn)
            let stored = try XCTUnwrap(fetched)
            XCTAssertEqual(stored.text, "hello body")
            XCTAssertEqual(stored.html, "<p>hi</p>")
            XCTAssertTrue(stored.hasMore)

            // Re-put overwrites rather than duplicating.
            try await BodyStore.put(
                accountId: account.id, remoteId: "b1", body: body(text: "v2"), db: conn
            )
            let refetched = try await BodyStore.get(accountId: account.id, remoteId: "b1", db: conn)
            let updated = try XCTUnwrap(refetched)
            XCTAssertEqual(updated.text, "v2")
        }
    }

    func test_headerDelete_cascadesBody() async throws {
        let account = makeAccount()
        try await TestDatabase.withConnection(cleanup: cleanup(account)) { conn in
            try await seed(account, db: conn)
            try await MessageStore.upsert(header(accountId: account.id, remoteId: "b2", subject: "s"), db: conn)
            try await BodyStore.put(
                accountId: account.id, remoteId: "b2", body: body(text: "x"), db: conn
            )

            try await MessageStore.deleteAll(accountId: account.id, db: conn)

            let gone = try await BodyStore.get(accountId: account.id, remoteId: "b2", db: conn)
            XCTAssertNil(gone, "reconciliation expunge must take the body with it")
        }
    }

    /// The body route serves the stored parse on the second GET even when the
    /// provider is gone — the write-through lock.
    func test_bodyRoute_servesStoredParseWhenProviderGone() async throws {
        let account = makeAccount()
        try await TestDatabase.withConnection(cleanup: cleanup(account)) { conn in
            try await seed(account, db: conn)
            try await MessageStore.upsert(header(accountId: account.id, remoteId: "b3", subject: "s"), db: conn)

            let provider = FlakyBodyProvider()
            let router = Router<BasicRequestContext>()
            let session = URLSession(configuration: .ephemeral)
            let client = GmailClient(session: session)
            let tokens = GmailTokenService(
                db: conn,
                oauth: GoogleOAuthClient(
                    clientID: "t", clientSecret: "s",
                    redirectURI: "http://127.0.0.1:9/cb", session: session
                ),
                logger: Self.logger
            )
            MessageRoutes.register(
                on: router, db: conn, client: client, tokens: tokens,
                logger: Self.logger, makeProvider: { _ in provider }
            )
            let app = Application(router: router)
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/api/messages/b3/body?accountId=\(account.id.uuidString)",
                    method: .get
                ) { response in
                    XCTAssertEqual(response.status, .ok)
                }
                let fetchesAfterFirst = await provider.fetchCount
                await provider.setBodyError(.messageGone)
                try await client.execute(
                    uri: "/api/messages/b3/body?accountId=\(account.id.uuidString)",
                    method: .get
                ) { response in
                    XCTAssertEqual(response.status, .ok, "stored parse survives provider loss")
                }
                let fetchesAfterSecond = await provider.fetchCount
                XCTAssertEqual(
                    fetchesAfterSecond, fetchesAfterFirst,
                    "the second GET must not touch the provider"
                )
            }
        }
    }

    /// Provider double for the write-through test: serves one body, then
    /// fails on demand.
    private actor FlakyBodyProvider: MailProvider {
        nonisolated let kind: MailProviderKind = .qq
        private(set) var fetchCount = 0
        private var bodyError: MailError?

        func setBodyError(_ error: MailError?) { bodyError = error }

        func capabilities() async -> MailCapabilities {
            MailCapabilities(archiveFolder: true, idle: true, move: true, serverSnippet: true)
        }

        func pullChanges(after cursor: MailSyncState, waitUpTo: Duration) async throws -> MailChangeSet {
            MailChangeSet(upserts: [], resetRequired: false, cursor: cursor)
        }

        func fetchBody(remoteId: String) async throws -> FetchedBody {
            fetchCount += 1
            if let bodyError { throw bodyError }
            return FetchedBody(text: "stored text", html: nil, attachments: [], hasMore: false)
        }

        func fetchAttachment(remoteId: String, attachmentId: String) async throws -> FetchedAttachmentBytes {
            throw AttachmentError.notFound
        }

        func fetchRawMessage(remoteId: String) async throws -> Data { Data() }

        func fetchRawHeaderValues(remoteId: String) async throws -> [String: String] { [:] }

        func setRead(remoteId: String, isRead: Bool) async throws {}

        func archive(remoteId: String) async throws {}

        func unarchive(remoteId: String) async throws {}

        func send(_ outbound: OutboundMessage) async throws -> String? { nil }

        func probe() async throws {}
    }

    /// Search recalls body text, and LIKE specials (`%`, `_`) in the query
    /// are data, not wildcards.
    func test_search_findsBodyText_andEscapesWildcards() async throws {
        let account = makeAccount()
        try await TestDatabase.withConnection(cleanup: cleanup(account)) { conn in
            try await seed(account, db: conn)
            try await MessageStore.upsert(
                header(accountId: account.id, remoteId: "s1", subject: "quarterly"), db: conn
            )
            try await BodyStore.put(
                accountId: account.id, remoteId: "s1",
                body: body(text: "the penguin migration budget is approved"), db: conn
            )
            try await MessageStore.upsert(
                header(accountId: account.id, remoteId: "s2", subject: "100% coverage_monday"), db: conn
            )

            let router = Router<BasicRequestContext>()
            SearchRoutes.register(on: router, db: conn)
            let app = Application(router: router)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            try await app.test(.router) { client in
                // Body-only term: not in subject, snippet, or sender.
                try await client.execute(
                    uri: "/api/search?accountId=\(account.id.uuidString)&q=penguin",
                    method: .get
                ) { response in
                    XCTAssertEqual(response.status, .ok)
                    let decoded = try decoder.decode(
                        SearchResponse.self, from: Data(buffer: response.body)
                    )
                    XCTAssertEqual(decoded.results.map(\.remoteId), ["s1"])
                }
                // A literal `%` must not become a wildcard matching everything.
                try await client.execute(
                    uri: "/api/search?accountId=\(account.id.uuidString)&q=100%25",
                    method: .get
                ) { response in
                    XCTAssertEqual(response.status, .ok)
                    let decoded = try decoder.decode(
                        SearchResponse.self, from: Data(buffer: response.body)
                    )
                    XCTAssertEqual(decoded.results.map(\.remoteId), ["s2"])
                }
            }
        }
    }
}
