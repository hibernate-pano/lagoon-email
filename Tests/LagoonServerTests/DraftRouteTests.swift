import XCTest
import Foundation
import Hummingbird
import HummingbirdTesting
import Logging
import PostgresNIO
import LagoonKit
@testable import LagoonServer

/// Contract tests for POST /api/messages/:remoteId/draft.
///
/// The generate endpoint used to answer with a server-local `{"drafts":[…]}`
/// envelope while the client decoded a bare `DraftReply` — generation
/// succeeded server-side but every click showed "未能读取数据，因为数据丢失".
/// The route MUST answer with the bare object the client decodes; this suite
/// pins that shape from the server side (APIClientTests pins the client side).
final class DraftRouteTests: XCTestCase {
    private static let logger = Logger(label: "draft-route-tests")

    /// Minimal `MessageDrafting` — no LLM, deterministic variants.
    private struct FakeDrafting: MessageDrafting {
        func draftReplies(
            _ body: MessageBody,
            language: String?,
            accountEmail: String,
            count: Int
        ) async throws -> [String] {
            ["variant one", "variant two", "variant three"]
        }
    }

    override func tearDown() {
        super.tearDown()
    }

    private func makeAccount() -> Account {
        Account(
            id: UUID(),
            provider: .qq,
            oauthUser: "draft-\(UUID().uuidString)",
            email: "draft-\(UUID().uuidString)@qq.com",
            credentials: nil
        )
    }

    private func header(accountId: UUID, remoteId: String) -> MessageHeader {
        MessageHeader(
            id: UUID(),
            accountId: accountId,
            remoteId: remoteId,
            threadId: "t-\(remoteId)",
            fromAddress: "bob@example.com",
            fromName: nil,
            subject: "thread",
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
        DraftRoutes.register(
            on: router, db: db, client: client, tokens: tokens,
            draftGenerator: FakeDrafting(), logger: logger,
            makeProvider: { _ in provider }
        )
        return router
    }

    /// The 200 body must decode as a bare `DraftReply` — top-level `id`,
    /// `variants`, `createdAt` — NOT wrapped in `{"drafts":[…]}`. Decoding it
    /// with the same iso8601 decoder the client uses is the contract check.
    func test_generate_returnsBareDraftReplyDecodableByClient() async throws {
        let account = makeAccount()
        let provider = StubMailProvider()
        let remoteId = "draft-contract-1"

        try await TestDatabase.withConnection(cleanup: { conn in
            try? await TestDatabase.deleteMessages(accountId: account.id, db: conn)
            try? await TestDatabase.deleteAccount(id: account.id, db: conn)
        }) { conn in
            try await AccountStore.upsert(account, credentials: Data([1, 2, 3]), db: conn)
            try await MessageStore.upsert(
                self.header(accountId: account.id, remoteId: remoteId), db: conn
            )
            let app = Application(router: Self.makeRouter(provider: provider, db: conn))
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/api/messages/\(remoteId)/draft?accountId=\(account.id.uuidString)",
                    method: .post
                ) { response in
                    XCTAssertEqual(response.status, .ok, String(buffer: response.body))
                    let data = Data(buffer: response.body)

                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    let draft = try decoder.decode(DraftReply.self, from: data)
                    XCTAssertEqual(draft.variants, ["variant one", "variant two", "variant three"])
                    XCTAssertEqual(draft.remoteId, remoteId)
                    XCTAssertEqual(draft.accountId, account.id)
                    XCTAssertNil(draft.chosenVariant)

                    // The old envelope shape must be gone.
                    let top = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                    XCTAssertNil(top?["drafts"], "POST /draft must not wrap in a drafts envelope")
                }
            }

            // The audit row still records the generation.
            let actions = try await conn.query(
                "SELECT count(*) AS n FROM ai_actions WHERE account_id = $1 AND kind = 'draft_create'",
                [PostgresData(uuid: account.id)]
            ).get()
            let n = try actions.rows.first?.makeRandomAccess()["n"].decode(Int.self)
            XCTAssertEqual(n, 1)
        }
    }
}
