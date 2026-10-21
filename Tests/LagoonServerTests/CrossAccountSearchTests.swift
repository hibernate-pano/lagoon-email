import XCTest
import GRDB
import Logging
import Hummingbird
import HummingbirdTesting
@testable import LagoonKit
@testable import LagoonServer

/// Search used to be a half-feature for anyone with more than one mailbox.
///
/// `/api/search` demanded an `accountId`, and the client always sent the
/// *active* account. Multi-account is a thing the product advertises — add a
/// mailbox, switch between them, sync them concurrently — so "search only
/// sees the mailbox you happen to be looking at" broke a promise the app
/// makes elsewhere.
///
/// The account is now optional, and `all` means every connected mailbox.
///
/// ## What these pin
///
/// The account predicate is the easy half. The **count** is the hard half:
/// the row query and the count query were two hand-written statements, and
/// they had already drifted — the count still pinned `m.account_id = ?`
/// while the rows had made the account optional, and the account value was
/// bound to the *subject* placeholder while the account predicate was handed
/// the last pattern in the list. A count that does not describe the rows it
/// counts is worse than no count: the user is told "3,140 matched" and shown
/// a different set.
///
/// So the tests below check the count against the rows, in both scopes.
final class CrossAccountSearchTests: XCTestCase {
    private let logger = Logger(label: "cross-account-search-tests")

    private func makeAccount(_ label: String) -> Account {
        Account(
            id: UUID(),
            provider: .qq,
            oauthUser: "\(label)-\(UUID().uuidString)",
            email: "\(label)@example.com",
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

    private func search(
        accountId: String, q: String, db: LagoonDB
    ) async throws -> SearchResponse {
        let router = Router<BasicRequestContext>()
        SearchRoutes.register(on: router, db: db, logger: self.logger)
        let app = Application(router: router)
        var out: SearchResponse?
        try await app.test(.router) { client in
            let escaped = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
            try await client.execute(
                uri: "/api/search?accountId=\(accountId)&q=\(escaped)",
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

    /// The two mailboxes hold the same subject, so a hit is only
    /// distinguishable by the account it came from.
    private func seedTwoAccounts(
        db: LagoonDB
    ) async throws -> (work: Account, personal: Account) {
        let work = makeAccount("work")
        let personal = makeAccount("personal")
        for account in [work, personal] {
            try await AccountStore.upsert(
                account,
                credentials: try CredentialVault.seal(
                    .imap(username: account.email, authCode: "code")
                ),
                db: db
            )
        }
        try await seedMessage(
            "uid:42", accountId: work.id, db: db, subject: "共同关键词"
        )
        try await seedMessage(
            "uid:42", accountId: personal.id, db: db, subject: "共同关键词"
        )
        return (work, personal)
    }

    /// `all` reaches both mailboxes, and every result says which one it is.
    ///
    /// The two messages share a `remoteId` on purpose: a message with no
    /// `Message-ID` header gets the provider's fallback id `uid:<n>`, and
    /// each account's IMAP UIDs count up independently — so account A's
    /// `uid:42` and account B's `uid:42` are the same string and different
    /// mail. A search that cannot tell them apart returns one of them
    /// twice, or the wrong one.
    func test_searchingAllAccountsReachesBothMailboxes() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            try await TestDatabase.withConnection { conn in
                let (work, personal) = try await seedTwoAccounts(db: conn)

                let response = try await search(
                    accountId: SearchScope.allKeyword,
                    q: "共同关键词",
                    db: conn
                )

                XCTAssertEqual(response.results.count, 2)
                XCTAssertEqual(response.totalCount, 2)
                let owners = Set(response.results.map(\.accountId))
                XCTAssertEqual(owners, [work.id, personal.id])
                // The two hits must be distinguishable — same remote id,
                // different mailbox.
                XCTAssertEqual(Set(response.results.map(\.remoteId)), ["uid:42"])
            }
        }
    }

    /// The count describes the rows it counts, in the wide scope.
    ///
    /// This is the drift the single-account case could not see: the count
    /// query used to pin `m.account_id = ?` while the rows did not, so a
    /// cross-account search counted one mailbox and listed another.
    func test_theCountMatchesTheRowsInTheWideScope() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            try await TestDatabase.withConnection { conn in
                let (work, personal) = try await seedTwoAccounts(db: conn)
                // A third message in one mailbox only.
                try await seedMessage(
                    "uid:43", accountId: work.id, db: conn, subject: "共同关键词 第三个"
                )

                let response = try await search(
                    accountId: SearchScope.allKeyword,
                    q: "共同关键词",
                    db: conn
                )
                XCTAssertEqual(response.results.count, 3)
                XCTAssertEqual(response.totalCount, 3)
                XCTAssertEqual(response.truncated, false)
                XCTAssertEqual(
                    response.results.filter { $0.accountId == work.id }.count, 2
                )
                XCTAssertEqual(
                    response.results.filter { $0.accountId == personal.id }.count, 1
                )
            }
        }
    }

    /// A single-account search still reaches only that mailbox.
    ///
    /// The scope widened; it must not have *leaked*. A search that returns
    /// another mailbox's mail when the user asked for one mailbox is the
    /// opposite failure of the one this fixes.
    func test_searchingOneAccountReachesOnlyThatMailbox() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            try await TestDatabase.withConnection { conn in
                let (work, personal) = try await seedTwoAccounts(db: conn)

                let response = try await search(
                    accountId: work.id.uuidString,
                    q: "共同关键词",
                    db: conn
                )
                XCTAssertEqual(response.results.count, 1)
                XCTAssertEqual(response.totalCount, 1)
                XCTAssertEqual(response.results.first?.accountId, work.id)
                XCTAssertNotEqual(response.results.first?.accountId, personal.id)
            }
        }
    }

    /// The single-account count matches its rows too — the account value has
    /// to reach the *account* placeholder, not the subject one.
    func test_theCountMatchesTheRowsInTheSingleAccountScope() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            try await TestDatabase.withConnection { conn in
                let (work, _) = try await seedTwoAccounts(db: conn)

                let response = try await search(
                    accountId: work.id.uuidString,
                    q: "共同关键词",
                    db: conn
                )
                XCTAssertEqual(response.results.count, 1)
                XCTAssertEqual(response.totalCount, 1)
            }
        }
    }

    /// A malformed scope is a bad request, not a wide search.
    ///
    /// Answering garbage with "everything" would hide a client bug behind a
    /// plausible-looking result list.
    func test_aMalformedScopeIsABadRequest() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            try await TestDatabase.withConnection { conn in
                let router = Router<BasicRequestContext>()
                SearchRoutes.register(on: router, db: conn, logger: self.logger)
                let app = Application(router: router)
                try await app.test(.router) { client in
                    try await client.execute(
                        uri: "/api/search?accountId=not-a-uuid&q=x",
                        method: .get
                    ) { response in
                        XCTAssertEqual(response.status, .badRequest)
                    }
                }
            }
        }
    }

    /// The scope is parsed by a shared type, so the client's keyword and the
    /// server's keyword cannot drift apart.
    func test_theScopeKeywordIsSharedBetweenClientAndServer() {
        XCTAssertEqual(SearchScope.allAccounts.queryValue, "all")
        XCTAssertEqual(SearchScope.parse("all"), .allAccounts)
        XCTAssertNil(SearchScope.parse("not-a-uuid"))
        XCTAssertNil(SearchScope.parse(""))
        XCTAssertNil(SearchScope.parse(nil))
        let id = UUID()
        XCTAssertEqual(SearchScope.parse(id.uuidString), .account(id))
        // The round trip: what the client sends is what the server reads.
        XCTAssertEqual(SearchScope.parse(SearchScope.account(id).queryValue), .account(id))
        XCTAssertEqual(
            SearchScope.parse(SearchScope.allAccounts.queryValue),
            .allAccounts
        )
    }
}
