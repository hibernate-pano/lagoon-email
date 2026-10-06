import XCTest
import Foundation
import Logging
import GRDB
@testable import LagoonKit
@testable import LagoonServer

/// The invariant behind every count badge in the sidebar: **a badge must equal
/// the number of rows in the list it labels.**
///
/// ## Why this file exists
///
/// `StackStore.messageCount` used to hand-write its own WHERE clause
/// (`is_deleted = FALSE AND <match>`) while the rule *listing* went through the
/// shared `filterSQL`. Those two disagree: `filterSQL` also excludes
/// `is_archived` and `is_sent`, so the badge counted archived and sent mail the
/// list never showed — and 清扫 (`archive-bulk` / `delete-bulk` with
/// `allMatching`) resolves through `filterSQL` too, so the number promised a
/// larger set than the sweep would move.
///
/// This is not a hypothetical. It is the third instance of the same drift:
/// `unreadCount` and `pinnedCount` were caught skipping the `is_sent` axis in
/// R1, and `senderRanking` was caught doing the same during the health check.
/// The fix is structural — `messageCount` now routes through
/// `MessageStore.count` — and this file is what keeps it routed.
final class StackCountConsistencyTests: XCTestCase {
    private let logger = Logger(label: "stack-count-tests")

    private func makeAccount() -> Account {
        Account(
            id: UUID(),
            provider: .qq,
            oauthUser: "sc-\(UUID().uuidString)",
            email: "sc-\(UUID().uuidString)@qq.com",
            credentials: nil
        )
    }

    private func seed(_ account: Account, db: LagoonDB) async throws {
        try await AccountStore.upsert(
            account,
            credentials: try CredentialVault.seal(
                .imap(username: account.email, authCode: "code")
            ),
            db: db
        )
    }

    private func seedMessage(
        _ remoteId: String,
        accountId: UUID,
        db: LagoonDB,
        from: String = "sender@example.com",
        subject: String = "Subject",
        archived: Bool = false,
        sent: Bool = false,
        deleted: Bool = false
    ) async throws {
        try await MessageStore.upsert(
            MessageHeader(
                id: UUID(),
                accountId: accountId,
                remoteId: remoteId,
                threadId: "t-\(remoteId)",
                fromAddress: from,
                fromName: nil,
                subject: subject,
                snippet: nil,
                receivedAt: Date(),
                isRead: true,
                isArchived: archived
            ),
            db: db
        )
        if deleted {
            try await MessageStore.setDeleted(
                remoteId: remoteId, accountId: accountId, deleted: true, db: db
            )
        }
        if sent {
            try db.write { raw in
                try MessageStore.markSent(
                    remoteId: remoteId, accountId: accountId, db: raw
                )
            }
        }
    }

    private func makeSenderRule(
        _ account: Account, value: String, db: LagoonDB
    ) async throws -> StackRule {
        try await StackStore.create(
            accountId: account.id, name: "R", kind: .sender, value: value, db: db
        )
    }

    // MARK: - 徽章 vs 列表

    /// The badge equals the list, for a sender rule and a keyword rule alike.
    ///
    /// Asserted as an equality between the two numbers rather than as a literal,
    /// so it holds for whatever the list's filter is — that is the property
    /// being protected. The old count included archived and sent rows; both
    /// arms below would have been 3 where the list showed 1.
    func test_ruleCount_equalsTheRowsItsListReturns() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await seedMessage("live", accountId: account.id, db: conn, from: "a@x.com")
                try await seedMessage("arch", accountId: account.id, db: conn, from: "a@x.com", archived: true)
                try await seedMessage("sent", accountId: account.id, db: conn, from: "a@x.com", sent: true)
                try await seedMessage("gone", accountId: account.id, db: conn, from: "a@x.com", deleted: true)
                try await seedMessage("other", accountId: account.id, db: conn, from: "b@x.com")

                let rule = try await makeSenderRule(account, value: "a@x.com", db: conn)
                let badge = try await StackStore.messageCount(rule: rule, db: conn)
                let list = try await MessageStore.recent(
                    forAccount: account.id, limit: 500, sender: nil,
                    archived: false, deleted: false, sent: false,
                    stackMatch: .sender("a@x.com"), db: conn
                )
                XCTAssertEqual(
                    badge, list.count,
                    "the badge beside a rule must count exactly what the rule's list shows"
                )
                XCTAssertEqual(
                    list.map(\.remoteId), ["live"],
                    "only the live inbox row belongs to this rule's lens"
                )
            }
        }
    }

    /// The same for a keyword rule — the two arms used to be separate SQL, so
    /// one could agree with the list while the other did not.
    func test_keywordRuleCount_equalsTheRowsItsListReturns() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await seedMessage("k1", accountId: account.id, db: conn, subject: "发票 已开")
                try await seedMessage("k2", accountId: account.id, db: conn, subject: "发票 缺失", archived: true)
                try await seedMessage("k3", accountId: account.id, db: conn, subject: "unrelated")

                let rule = try await StackStore.create(
                    accountId: account.id, name: "K", kind: .keyword, value: "发票", db: conn
                )
                let badge = try await StackStore.messageCount(rule: rule, db: conn)
                let list = try await MessageStore.recent(
                    forAccount: account.id, limit: 500, sender: nil,
                    archived: false, deleted: false, sent: false,
                    stackMatch: .keyword("发票"), db: conn
                )
                XCTAssertEqual(badge, list.count)
                XCTAssertEqual(list.map(\.remoteId), ["k1"])
            }
        }
    }

    /// An empty rule is 0 on both sides — the trivially-missed case, where a
    /// badge that defaulted to "all mail" would look plausible.
    func test_ruleCount_isZeroWhenNothingMatches() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await seedMessage("x", accountId: account.id, db: conn, from: "a@x.com")
                let rule = try await makeSenderRule(account, value: "nobody@x.com", db: conn)
                let count = try await StackStore.messageCount(rule: rule, db: conn)
                XCTAssertEqual(count, 0)
            }
        }
    }

    // MARK: - 单条读取

    /// `find()` must report the `is_sent` flag, not default it to false.
    ///
    /// `decode` tolerates a missing `is_sent` column (queries that predate the
    /// R1 column legitimately lack it) — and that tolerance is precisely why the
    /// omission went unnoticed: a single-message read reported sent mail as
    /// received, with no error and no test failure. `recent()` always selected
    /// it; `find()` did not.
    func test_find_preservesTheSentFlag() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await seedMessage("s", accountId: account.id, db: conn, sent: true)
                try await seedMessage("r", accountId: account.id, db: conn)

                let sent = try await MessageStore.find(
                    remoteId: "s", accountId: account.id, db: conn
                )
                XCTAssertEqual(
                    sent?.isSent, true,
                    "a single read must not report a sent reply as received mail"
                )
                let received = try await MessageStore.find(
                    remoteId: "r", accountId: account.id, db: conn
                )
                XCTAssertEqual(received?.isSent, false)
            }
        }
    }
}
