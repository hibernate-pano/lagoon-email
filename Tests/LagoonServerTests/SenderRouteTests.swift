import XCTest
import Foundation
import Logging
import Hummingbird
import NIOCore
import GRDB
@testable import LagoonKit
@testable import LagoonServer

/// End-to-end for `GET /api/senders` — the ranking behind the 发件人排行 panel.
///
/// The ranking's whole value is that its order and its numbers can be trusted:
/// a panel that says "340 from this sender, 0 unread" is making a claim about
/// the user's habits. These tests seed a known population and assert the exact
/// ranking, because a plausible-but-wrong order is the failure that matters.
final class SenderRouteTests: XCTestCase {
    private let logger = Logger(label: "senders-tests")

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
                .imap(username: account.email, authCode: "auth-code")
            ),
            db: db
        )
    }

    private func seedMessage(
        _ remoteId: String,
        accountId: UUID,
        db: LagoonDB,
        from: String,
        name: String? = nil,
        isRead: Bool = true,
        archived: Bool = false,
        deleted: Bool = false,
        sent: Bool = false,
        daysAgo: Int = 0
    ) async throws {
        try await MessageStore.upsert(
            MessageHeader(
                id: UUID(),
                accountId: accountId,
                remoteId: remoteId,
                threadId: "t-\(remoteId)",
                fromAddress: from,
                fromName: name,
                subject: "Subject \(remoteId)",
                snippet: "snippet",
                receivedAt: Date().addingTimeInterval(-Double(daysAgo) * 86_400),
                isRead: isRead,
                isArchived: archived
            ),
            db: db
        )
        // `upsert` never writes is_deleted — only the route that trashes mail
        // does, so the fixture has to go through it too.
        if deleted {
            try await MessageStore.setDeleted(
                remoteId: remoteId, accountId: accountId, deleted: true, db: db
            )
        }
        // Same for `is_sent`: it records which folder a row was synced from, so
        // only the sent route sets it.
        if sent {
            try db.write { raw in
                try MessageStore.markSent(
                    remoteId: remoteId, accountId: accountId, db: raw
                )
            }
        }
    }

    private func fetch(
        _ accountId: UUID,
        db: LagoonDB,
        limit: Int? = nil,
        q: String? = nil
    ) async throws -> [SenderSummary] {
        let router = Router<BasicRequestContext>()
        SenderRoutes.register(on: router, db: db, logger: self.logger)
        let app = Application(router: router)
        var result: [SenderSummary] = []
        var path = "/api/senders?accountId=\(accountId.uuidString)"
        if let limit { path += "&limit=\(limit)" }
        if let q { path += "&q=\(q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q)" }
        try await app.test(.router) { client in
            try await client.execute(uri: path, method: .get) { response in
                XCTAssertEqual(response.status, .ok)
                // The API's wire format for dates is ISO-8601 (RouteJSON's
                // encoder), not the stored SQLite format — the store parses one
                // and re-encodes the other.
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let decoded = try decoder.decode(
                    SenderListResponse.self,
                    from: Data(response.body.readableBytesView)
                )
                result = decoded.senders
            }
        }
        return result
    }

    /// 「谁在给我写信」must not answer with the user.
    ///
    /// The regression: `senderRanking` hand-rolled its WHERE clause and, when
    /// R1 added the `is_sent` axis, never learned about it. Sent rows are
    /// synced with `from_address` = the user's own address, so opening 已发送
    /// once was enough to make the user their own top sender — in a panel whose
    /// entire claim is "who is writing to me", ordered by volume.
    ///
    /// This is the third instance of the same drift (after `unreadCount` /
    /// `pinnedCount` in R1), which is why the fix is a predicate on the query
    /// and not a special case in the route.
    func test_senderRanking_excludesTheUsersOwnSentMail() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                let me = account.email
                // The user has sent 4 replies; a correspondent wrote 2.
                for i in 1...4 {
                    try await seedMessage(
                        "sent\(i)", accountId: account.id, db: conn, from: me, sent: true
                    )
                }
                for i in 1...2 {
                    try await seedMessage(
                        "in\(i)", accountId: account.id, db: conn, from: "friend@example.com"
                    )
                }

                let senders = try await fetch(account.id, db: conn)
                let addresses = senders.map(\.address)
                XCTAssertFalse(
                    addresses.contains(me),
                    "the user's own address must not appear as a sender — "
                        + "they did not write to themselves: \(addresses)"
                )
                XCTAssertEqual(
                    addresses, ["friend@example.com"],
                    "only real correspondents remain, with their true counts"
                )
                XCTAssertEqual(senders.first?.totalCount, 2)
            }
        }
    }

    /// Ranked by volume, most first. This is the panel's entire proposition, so
    /// it is asserted as an exact order rather than a set.
    func test_sendersAreRankedByVolume() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                // 3 from newsletter, 2 from a colleague, 1 from a bank.
                for i in 1...3 {
                    try await seedMessage(
                        "n\(i)", accountId: account.id, db: conn,
                        from: "news@shop.example", name: "Shop"
                    )
                }
                for i in 1...2 {
                    try await seedMessage(
                        "c\(i)", accountId: account.id, db: conn,
                        from: "colleague@work.example", name: "Colleague"
                    )
                }
                try await seedMessage(
                    "b1", accountId: account.id, db: conn, from: "bank@example"
                )

                let senders = try await fetch(account.id, db: conn)
                XCTAssertEqual(
                    senders.map(\.address),
                    ["news@shop.example", "colleague@work.example", "bank@example"]
                )
                XCTAssertEqual(senders[0].totalCount, 3)
                XCTAssertEqual(senders[1].totalCount, 2)
                XCTAssertEqual(senders[0].displayName, "Shop")
            }
        }
    }

    /// The mismatch cases are the interesting ones, and they need both numbers.
    /// A single count cannot say "340 and none unread", which is precisely the
    /// row that should be offered for filing.
    func test_totalAndUnreadAreReportedSeparately() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                // 12 read from the newsletter (the "you stopped reading" shape).
                for i in 1...12 {
                    try await seedMessage(
                        "r\(i)", accountId: account.id, db: conn, from: "news@example"
                    )
                }
                // 2 unread from a person (the "just arrived" shape).
                for i in 1...2 {
                    try await seedMessage(
                        "u\(i)", accountId: account.id, db: conn,
                        from: "friend@example", isRead: false
                    )
                }

                let senders = try await fetch(account.id, db: conn)
                let news = try XCTUnwrap(senders.first { $0.address == "news@example" })
                XCTAssertEqual(news.totalCount, 12)
                XCTAssertEqual(news.unreadCount, 0)
                XCTAssertFalse(news.looksUnread)
                // 12 messages is past the threshold for offering to file them.
                XCTAssertTrue(news.isWorthCollapsing)

                let friend = try XCTUnwrap(senders.first { $0.address == "friend@example" })
                XCTAssertEqual(friend.totalCount, 2)
                XCTAssertEqual(friend.unreadCount, 2)
                XCTAssertTrue(friend.looksUnread)
                // Two messages is just a correspondent — offering to file them
                // would be noise.
                XCTAssertFalse(friend.isWorthCollapsing)
            }
        }
    }

    /// Trashed mail does not keep a sender at the top of the list.
    ///
    /// This is the failure mode the ordering exists to prevent: a newsletter the
    /// user deleted last month would otherwise outrank every live correspondent
    /// forever, and the panel's advice ("file this sender") would be advice
    /// about mail that is already gone.
    func test_deletedMailIsExcludedFromTheRanking() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await seedMessage(
                    "live", accountId: account.id, db: conn, from: "alive@example"
                )
                for i in 1...20 {
                    try await seedMessage(
                        "d\(i)", accountId: account.id, db: conn,
                        from: "gone@example", deleted: true
                    )
                }

                let senders = try await fetch(account.id, db: conn)
                XCTAssertEqual(
                    senders.map(\.address), ["alive@example"],
                    "a sender whose mail is all in the Trash is not still writing to this mailbox"
                )
            }
        }
    }

    /// Archived mail counts. Archived is where triage puts mail that is finished
    /// with, not mail that does not exist — a newsletter archived every week is
    /// exactly the row this panel exists to surface.
    func test_archivedMailIsIncluded() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                for i in 1...5 {
                    try await seedMessage(
                        "a\(i)", accountId: account.id, db: conn,
                        from: "news@example", archived: true
                    )
                }
                let senders = try await fetch(account.id, db: conn)
                XCTAssertEqual(senders.count, 1)
                XCTAssertEqual(senders[0].totalCount, 5)
            }
        }
    }

    /// Two senders with the same volume are ordered by recency — when the user
    /// is deciding what to file, "who wrote most recently" is the tiebreak that
    /// tells them which one is still live.
    func test_equalVolumeIsBrokenByRecency() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await seedMessage(
                    "old", accountId: account.id, db: conn,
                    from: "stale@example", daysAgo: 30
                )
                try await seedMessage(
                    "new", accountId: account.id, db: conn,
                    from: "fresh@example", daysAgo: 1
                )
                let senders = try await fetch(account.id, db: conn)
                XCTAssertEqual(senders.map(\.address), ["fresh@example", "stale@example"])
            }
        }
    }

    /// The query narrows over both address and display name, because the user
    /// remembers "Shop" more reliably than "news@shop.example".
    func test_queryMatchesAddressOrDisplayName() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await seedMessage(
                    "s1", accountId: account.id, db: conn,
                    from: "news@shop.example", name: "Shop"
                )
                try await seedMessage(
                    "s2", accountId: account.id, db: conn,
                    from: "bank@example", name: "Bank"
                )
                let byShop = try await fetch(account.id, db: conn, q: "shop")
                XCTAssertEqual(byShop.map(\.address), ["news@shop.example"])
                let byName = try await fetch(account.id, db: conn, q: "Bank")
                XCTAssertEqual(byName.map(\.address), ["bank@example"])
                let noMatch = try await fetch(account.id, db: conn, q: "zzz")
                XCTAssertTrue(noMatch.isEmpty)
            }
        }
    }

    /// LIKE metacharacters in the query are data, not wildcards.
///
/// Without the escaping, `_` would match any single character and `%` would
/// match anything — so searching for `a_a` would return `aaa@example` too,
/// which is the kind of wrong-but-plausible result that makes a user stop
/// trusting a search box.
func test_queryTreatsWildcardsAsLiterals() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await seedMessage(
                    "a", accountId: account.id, db: conn, from: "aaa@example"
                )
                try await seedMessage(
                    "b", accountId: account.id, db: conn, from: "aXa@example"
                )
                // `_` is a single-character wildcard, so an unescaped `a_a`
                // would match both rows. Escaped, it matches neither.
                let wildcard = try await fetch(account.id, db: conn, q: "a_a")
                XCTAssertTrue(
                    wildcard.isEmpty,
                    "`_` must be a literal, not a wildcard: it matched \(wildcard.map(\.address))"
                )
                // And a real substring still matches, so the escaping is not
                // simply breaking the query.
                let plain = try await fetch(account.id, db: conn, q: "aaa")
                XCTAssertEqual(plain.map(\.address), ["aaa@example"])
            }
        }
    }

    /// The limit is honoured, and it is a real cap rather than a hint.
    func test_limitCapsTheRanking() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                for i in 1...10 {
                    try await seedMessage(
                        "m\(i)", accountId: account.id, db: conn,
                        from: "s\(i)@example"
                    )
                }
                let capped = try await fetch(account.id, db: conn, limit: 3)
                XCTAssertEqual(capped.count, 3)
            }
        }
    }

    /// Counts are per-account.
    func test_rankingIsScopedToOneAccount() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let first = makeAccount()
            let second = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(first, db: conn)
                try await seed(second, db: conn)
                try await seedMessage("a", accountId: first.id, db: conn, from: "mine@example")
                try await seedMessage("b", accountId: second.id, db: conn, from: "theirs@example")

                let senders = try await fetch(first.id, db: conn)
                XCTAssertEqual(senders.map(\.address), ["mine@example"])
            }
        }
    }

    /// An unknown account is 404, not an empty ranking.
    func test_unknownAccount_isNotFound() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            try await TestDatabase.withConnection { conn in
                let router = Router<BasicRequestContext>()
                SenderRoutes.register(on: router, db: conn, logger: self.logger)
                let app = Application(router: router)
                try await app.test(.router) { client in
                    try await client.execute(
                        uri: "/api/senders?accountId=\(UUID().uuidString)", method: .get
                    ) { response in
                        XCTAssertEqual(response.status, .notFound)
                    }
                }
            }
        }
    }

    /// Reading the ranking never changes it. This endpoint is what the panel
    /// calls every time it opens, so a write hidden in it would fire on open.
    func test_routeIsReadOnly_acrossRepeatedCalls() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                for i in 1...3 {
                    try await seedMessage(
                        "m\(i)", accountId: account.id, db: conn, from: "s@example"
                    )
                }
                let first = try await fetch(account.id, db: conn)
                let second = try await fetch(account.id, db: conn)
                XCTAssertEqual(first, second)
                // Nothing was filed, archived or trashed by looking.
                let live = try await MessageStore.count(forAccount: account.id, db: conn)
                XCTAssertEqual(live, 3)
                let rules = try await StackStore.list(accountId: account.id, db: conn)
                XCTAssertTrue(rules.isEmpty)
            }
        }
    }
}