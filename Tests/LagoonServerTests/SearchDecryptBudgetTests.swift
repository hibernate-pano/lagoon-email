import XCTest
import Foundation
import Crypto
import Logging
import Hummingbird
import HummingbirdTesting
import GRDB
@testable import LagoonKit
@testable import LagoonServer

/// What a search is allowed to spend on decryption.
///
/// The search predicate used to carry two `lagoon_cipher_contains(...)`
/// arms, and that function is a **complete AES-GCM open**. SQLite evaluates
/// an `OR` chain per row, so a query whose word only appears inside a body
/// opened every cached body in the account — and the count query, which ran
/// over the same predicate without the `LIMIT`, opened them all again.
///
/// These pin the budget that replaced it:
///
/// * every envelope is opened at most once per request,
/// * the body scan has a ceiling, and the response says how much of the
///   mailbox was left out,
/// * the count still describes exactly the rows that were searched.
final class SearchDecryptBudgetTests: XCTestCase {
    private let logger = Logger(label: "search-decrypt-budget-tests")

    // MARK: - Fixtures

    private func makeAccount() -> Account {
        Account(
            id: UUID(),
            provider: .qq,
            oauthUser: "sb-\(UUID().uuidString)",
            email: "sb-\(UUID().uuidString)@qq.com",
            credentials: nil
        )
    }

    private func seedAccount(_ account: Account, db: LagoonDB) async throws {
        try await AccountStore.upsert(
            account,
            credentials: try CredentialVault.seal(
                .imap(username: account.email, authCode: "code")
            ),
            db: db
        )
    }

    /// A mailbox of `count` messages, each with a sealed body and **no**
    /// preview.
    ///
    /// The bodies are the only sealed values in the store, so every envelope
    /// the search opens is one of them: the number of opens is the number of
    /// bodies, with nothing else in the way.
    ///
    /// `word` goes into every body, so a search for it matches every row —
    /// which is what makes "the scan opened N bodies" and "the scan found N
    /// matches" the same number.
    ///
    /// The oldest message also carries `oldestWord`, so the tests can ask
    /// what a bounded scan does *not* reach.
    private func seedBodies(
        count: Int,
        accountId: UUID,
        word: String,
        oldestWord: String? = nil,
        db: LagoonDB
    ) async throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<count {
            let remoteId = "body-\(index)"
            let extra = index == 0 ? (oldestWord.map { " \($0)" } ?? "") : ""
            try await MessageStore.upsert(
                MessageHeader(
                    id: UUID(),
                    accountId: accountId,
                    remoteId: remoteId,
                    threadId: "t-\(remoteId)",
                    fromAddress: "sender@example.com",
                    fromName: "Sender",
                    subject: "无关标题 \(index)",
                    snippet: nil,
                    receivedAt: base.addingTimeInterval(Double(index)),
                    isRead: true,
                    isArchived: false
                ),
                db: db
            )
            try await BodyStore.put(
                accountId: accountId,
                remoteId: remoteId,
                body: FetchedBody(
                    text: "正文包含 \(word)\(extra) 第 \(index) 段",
                    html: nil, attachments: [], hasMore: false
                ),
                db: db
            )
        }
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

    /// Counts the envelopes the cipher opened while `body` ran.
    ///
    /// The body key is injected as a closure and `BodyCipher.open` asks for
    /// it exactly once per envelope, so wrapping the provider counts the
    /// decryptions rather than an approximation of them. Nothing else on the
    /// search path asks for the key, so the number means what it says.
    private func countingOpens<T>(
        _ body: @escaping () async throws -> T
    ) async throws -> (T, Int) {
        let previous = BodyCipher.keyProvider
        let counter = OpenCounter()
        if let previous {
            BodyCipher.keyProvider = { try counter.record(previous) }
        }
        defer { BodyCipher.keyProvider = previous }
        let value = try await body()
        return (value, counter.opens)
    }

    // MARK: - Tests

    /// Every body is opened **once** — not once for the rows and once again
    /// for the count.
    ///
    /// The old search ran the same predicate twice: once for the rows and
    /// once for the count, and each run opened every body it walked past.
    /// This is the assertion that says "the two runs are one run now".
    func test_eachBodyIsOpenedOncePerSearch() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seedAccount(account, db: conn)
                try await seedBodies(
                    count: 12, accountId: account.id, word: "penguin", db: conn
                )

                let (response, opens) = try await countingOpens {
                    try await self.searchResponse(account.id, q: "penguin", db: conn)
                }

                XCTAssertEqual(response.results.count, 12)
                XCTAssertEqual(
                    opens, 12,
                    "each body was opened more than once — the rows and the count are still scanning separately"
                )
            }
        }
    }

    /// The body scan has a ceiling, and the response says what it did not
    /// reach.
    ///
    /// The skipped number is the whole point: a search that quietly stopped
    /// at its budget reads as a complete search, and "this word is not in my
    /// mail" is the answer a user is least able to check.
    func test_theBodyScanIsBoundedAndReportsWhatItSkipped() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seedAccount(account, db: conn)
                let limit = SearchRoutes.bodyScanLimit
                let extra = 5
                try await seedBodies(
                    count: limit + extra, accountId: account.id,
                    word: "penguin", db: conn
                )

                let (response, opens) = try await countingOpens {
                    try await self.searchResponse(account.id, q: "penguin", db: conn)
                }

                XCTAssertEqual(response.bodyScanLimit, limit)
                XCTAssertEqual(
                    response.bodyScanSkipped, extra,
                    "the response must say how much of the mailbox was not searched"
                )
                XCTAssertEqual(
                    response.totalCount, limit,
                    "the count must describe the rows that were actually searched"
                )
                XCTAssertEqual(
                    opens, limit,
                    "the scan opened more bodies than its budget — the work still scales with the mailbox"
                )
                XCTAssertEqual(response.results.count, SearchRoutes.resultLimit)
                XCTAssertEqual(response.truncated, true)
            }
        }
    }

    /// The budget covers the **newest** bodies, and a word that only exists
    /// in the oldest message is not found.
    ///
    /// This is the honest version of a bounded search: the cap is visible,
    /// not silent. The word is in a message the scan never opened, so the
    /// search misses it — and says how many messages it did not reach.
    func test_theBudgetCoversTheNewestBodiesAndSaysWhatItMissed() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seedAccount(account, db: conn)
                let limit = SearchRoutes.bodyScanLimit
                let extra = 5
                try await seedBodies(
                    count: limit + extra, accountId: account.id,
                    word: "penguin", oldestWord: "anoldexif", db: conn
                )

                let response = try await searchResponse(
                    account.id, q: "anoldexif", db: conn
                )

                XCTAssertTrue(
                    response.results.isEmpty,
                    "the word lives in the oldest message, which the budget did not reach"
                )
                XCTAssertEqual(response.totalCount, 0)
                XCTAssertEqual(response.bodyScanSkipped, extra)
            }
        }
    }

    /// The count agrees with the rows when nothing was skipped.
    ///
    /// A count that does not describe the rows it counts is worse than no
    /// count at all: the user is told "3,140 matched" and shown a different
    /// set.
    func test_theCountAgreesWithTheRowsWhenNothingIsSkipped() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seedAccount(account, db: conn)
                try await seedBodies(
                    count: 5, accountId: account.id, word: "penguin", db: conn
                )

                let response = try await searchResponse(account.id, q: "penguin", db: conn)

                XCTAssertEqual(response.results.count, 5)
                XCTAssertEqual(response.totalCount, 5)
                XCTAssertEqual(response.truncated, false)
                XCTAssertEqual(response.bodyScanSkipped, 0)
            }
        }
    }

    /// The body arm matches case-insensitively.
    ///
    /// The old predicate matched sealed bodies with `lagoon_cipher_contains`,
    /// which folds case. The Swift side has to fold it the same way — a
    /// search that found "Invoice" through one path and not the other would
    /// return a different set depending on which arm reached the row first.
    func test_theBodyArmMatchesCaseInsensitively() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seedAccount(account, db: conn)
                try await MessageStore.upsert(
                    MessageHeader(
                        id: UUID(),
                        accountId: account.id,
                        remoteId: "case",
                        threadId: "t-case",
                        fromAddress: "sender@example.com",
                        fromName: "Sender",
                        subject: "无关标题",
                        snippet: nil,
                        receivedAt: Date(timeIntervalSince1970: 1_700_000_000),
                        isRead: true,
                        isArchived: false
                    ),
                    db: conn
                )
                try await BodyStore.put(
                    accountId: account.id,
                    remoteId: "case",
                    body: FetchedBody(
                        text: "Invoice ATTACHED in the attachment",
                        html: nil, attachments: [], hasMore: false
                    ),
                    db: conn
                )

                let hits = try await searchResponse(account.id, q: "invoice", db: conn)
                XCTAssertEqual(hits.results.map(\.remoteId), ["case"])

                let upper = try await searchResponse(account.id, q: "ATTACHED", db: conn)
                XCTAssertEqual(upper.results.map(\.remoteId), ["case"])
            }
        }
    }
}

/// A thread-safe tally of key requests.
private final class OpenCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    /// The wrapped provider, with the tally in front of it.
    func record(_ inner: () throws -> SymmetricKey) throws -> SymmetricKey {
        lock.lock()
        count += 1
        lock.unlock()
        return try inner()
    }

    var opens: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
