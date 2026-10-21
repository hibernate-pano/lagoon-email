import XCTest
import GRDB
import Logging
import Hummingbird
import HummingbirdTesting
@testable import LagoonKit
@testable import LagoonServer

/// The search used to stop at its cap and say nothing.
///
/// `GET /api/search` had a hard `LIMIT 100` and the response carried only
/// the rows. A user who searched "发票" and got 100 results had no way to
/// know whether that was all of them or the first hundred — and "the first
/// hundred" reads as "all of them" every time, because the two look
/// identical.
///
/// These pin the count: the server says how many matched, and the client
/// says it too.
final class SearchResultCountTests: XCTestCase {
    private let logger = Logger(label: "search-count-tests")

    private func makeAccount() -> Account {
        Account(
            id: UUID(),
            provider: .qq,
            oauthUser: "sc-\(UUID().uuidString)",
            email: "sc-\(UUID().uuidString)@qq.com",
            credentials: nil
        )
    }

    private func seedMessage(
        _ remoteId: String,
        accountId: UUID,
        db: LagoonDB,
        subject: String
    ) async throws {
        try await MessageStore.upsert(
            MessageHeader(
                id: UUID(),
                accountId: accountId,
                remoteId: remoteId,
                threadId: "t-\(remoteId)",
                fromAddress: "sender@example.com",
                fromName: "Sender",
                subject: subject,
                snippet: nil,
                receivedAt: Date(),
                isRead: true,
                isArchived: false
            ),
            db: db
        )
    }

    private func searchResponse(
        _ accountId: UUID, q: String, db: LagoonDB
    ) async throws -> SearchResponse {
        let router = Router<BasicRequestContext>()
        SearchRoutes.register(on: router, db: db, logger: self.logger)
        let app = Application(router: router)
        var out: SearchResponse?
        try await app.test(.router) { client in
            let escaped = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
            try await client.execute(
                uri: "/api/search?accountId=\(accountId.uuidString)&q=\(escaped)",
                method: .get
            ) { response in
                XCTAssertEqual(response.status, .ok)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                out = try decoder.decode(
                    SearchResponse.self,
                    from: Data(response.body.readableBytesView)
                )
            }
        }
        return try XCTUnwrap(out)
    }

    /// The count is right, and it agrees with the rows.
    func test_theResponseCarriesTheNumberOfMatches() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await AccountStore.upsert(
                    account,
                    credentials: try CredentialVault.seal(
                        .imap(username: account.email, authCode: "code")
                    ),
                    db: conn
                )
                for index in 0..<7 {
                    try await seedMessage(
                        "hit-\(index)", accountId: account.id, db: conn, subject: "共同关键词 \(index)"
                    )
                }
                try await seedMessage(
                    "miss", accountId: account.id, db: conn, subject: "别的内容"
                )

                let response = try await searchResponse(account.id, q: "共同关键词", db: conn)
                XCTAssertEqual(response.results.count, 7)
                XCTAssertEqual(response.totalCount, 7)
                XCTAssertEqual(response.truncated, false)
            }
        }
    }

    /// A search that matched nothing says zero, not nil.
    ///
    /// Nil would mean "the server did not say", and the client would then
    /// show no count at all — which is exactly the silence this change is
    /// meant to end.
    func test_aSearchThatMatchedNothingSaysZero() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await AccountStore.upsert(
                    account,
                    credentials: try CredentialVault.seal(
                        .imap(username: account.email, authCode: "code")
                    ),
                    db: conn
                )
                let response = try await searchResponse(account.id, q: "不存在的词", db: conn)
                XCTAssertTrue(response.results.isEmpty)
                XCTAssertEqual(response.totalCount, 0)
                XCTAssertEqual(response.truncated, false)
            }
        }
    }

    /// The count does not multiply rows that have both a body and an advice
    /// row. The count query joins the same two tables the row query does,
    /// so a double-join would double the count.
    func test_theCountDoesNotDoubleCountJoinedRows() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await AccountStore.upsert(
                    account,
                    credentials: try CredentialVault.seal(
                        .imap(username: account.email, authCode: "code")
                    ),
                    db: conn
                )
                try await seedMessage(
                    "one", accountId: account.id, db: conn, subject: "共同关键词"
                )
                try await BodyStore.put(
                    accountId: account.id,
                    remoteId: "one",
                    body: FetchedBody(
                        text: "正文", html: nil, attachments: [], hasMore: false
                    ),
                    db: conn
                )
                _ = try await AdviceStore.upsert(
                    accountId: account.id,
                    remoteId: "one",
                    advice: Advice(action: .archive, category: .marketing),
                    source: .heuristic,
                    model: nil,
                    db: conn
                )
                let response = try await searchResponse(account.id, q: "共同关键词", db: conn)
                XCTAssertEqual(response.results.count, 1)
                XCTAssertEqual(response.totalCount, 1, "the joins multiplied the count")
            }
        }
    }
}
