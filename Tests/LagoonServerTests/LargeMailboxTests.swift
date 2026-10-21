import XCTest
import Foundation
import Logging
import Hummingbird
import NIOCore
import GRDB
@testable import LagoonKit
@testable import LagoonServer

/// The 5000-message scale case (Q-03 in docs/全方位审查报告-2026-10-16.md).
///
/// ## Why this file exists
///
/// Every historical window/count bug in this project surfaced at a seed size
/// far below what the product promises: the largest existing fixture was 505
/// messages, while the list window, the sidebar badges and the "empty the
/// trash" sweep all behave differently once the row count passes the response
/// cap. This file seeds 5000 rows — three axes distributed, a slice unread —
/// and asserts the two contracts that must hold at any size:
///
/// * the default window is the documented 500 rows, and `totalCount` reports
///   the whole filter rather than the window (the client's truncated notice
///   is only honest if these two numbers are);
/// * every axis count equals the list it labels, at scale.
///
/// Deliberately **no performance assertions** — wall-clock budgets are the
/// definition of a flaky test, and nothing in this suite gates on timing.
final class LargeMailboxTests: XCTestCase {
    private let logger = Logger(label: "large-mailbox-tests")

    private func makeAccount() -> Account {
        Account(
            id: UUID(),
            provider: .qq,
            oauthUser: "bulk-\(UUID().uuidString)",
            email: "bulk-\(UUID().uuidString)@qq.com",
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

    /// 5000 rows in one write transaction, distributed over the axes:
    /// 3600 inbox (1200 unread), 300 archived (50 unread), 300 deleted
    /// (40 unread), 800 sent (60 unread). `received_at` decreases with the
    /// index, so "newest" is `bulk-0` and windows are deterministic.
    ///
    /// One static, fully parameterized INSERT executed per row — never
    /// `MessageStore.upsert` per row, which would be 5000 transactions and
    /// measure the writer instead of the query paths this file is about.
    /// (`ci-guardrails.sh` scans this directory: the SQL stays a literal with
    /// `?` placeholders, values come in as bound arguments.)
    private func seedBulk(_ account: Account, db: LagoonDB) async throws {
        try db.write { raw in
            let base = Date(timeIntervalSince1970: 1_700_000_000)
            for index in 0..<5000 {
                let inboxUnread = index >= 2400 && index < 3600
                let archived = index >= 3600 && index < 3900
                let deleted = index >= 3900 && index < 4200
                let sent = index >= 4200
                let unread = inboxUnread
                    || (archived && index < 3650)
                    || (deleted && index < 3940)
                    || (sent && index < 4260)
                try raw.execute(
                    sql: """
                        INSERT INTO message_headers (
                            id, account_id, remote_id, thread_id, from_address,
                            subject, snippet_cipher, received_at, is_read, is_archived,
                            is_deleted, is_sent
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        UUID(), account.id, "bulk-\(index)", "t-\(index)",
                        "bulk@example.com", "Subject \(index)",
                        // The preview is sealed at rest, so the fixture has to
                        // seal it too — otherwise it would be writing a shape
                        // the app itself can never write, and the test would
                        // be measuring a store that cannot exist.
                        try BodyCipher.seal("snippet \(index)"),
                        base.addingTimeInterval(-Double(index)), !unread,
                        archived, deleted, sent,
                    ]
                )
            }
        }
    }

    /// `GET /api/messages` with no `limit`, in response order (newest first —
    /// the assertion below depends on that, so this helper deliberately does
    /// not sort).
    private func window(
        _ accountId: UUID, _ db: LagoonDB
    ) async throws -> (rows: [String], total: Int) {
        let router = Router<BasicRequestContext>()
        SyncRoutes.register(on: router, db: db, logger: self.logger)
        let app = Application(router: router)
        var rows: [String] = []
        var total = -1
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/messages?accountId=\(accountId.uuidString)", method: .get
            ) { response in
                XCTAssertEqual(response.status, .ok)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let decoded = try decoder.decode(
                    SyncResponse.self, from: Data(response.body.readableBytesView)
                )
                rows = decoded.messages.map(\.remoteId)
                total = decoded.totalCount ?? decoded.messages.count
            }
        }
        return (rows, total)
    }

    /// The default window is 500 rows; `totalCount` is the whole inbox.
    ///
    /// These two numbers are the client's truncation notice, verbatim:
    /// "已显示最新 500 封，共 3600 封" is only true if the window is capped and
    /// the total is not.
    func test_defaultWindowIsFiveHundredRowsAndTotalCountCoversTheWholeInbox() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await seedBulk(account, db: conn)

                let result = try await window(account.id, conn)
                XCTAssertEqual(result.rows.count, 500, "the default window is the documented 500")
                XCTAssertEqual(
                    result.total, 3600,
                    "totalCount must report the whole inbox filter, not the window"
                )
                XCTAssertEqual(result.rows.first, "bulk-0", "the window is the newest rows")
                XCTAssertTrue(result.rows.contains("bulk-499"))
                XCTAssertFalse(
                    result.rows.contains("bulk-500"),
                    "the window is capped while the total stays whole — truncation must be visible, not silent"
                )
            }
        }
    }

    /// Every axis count equals the list it labels, at 5000 rows.
    func test_axisCountsAgreeWithTheirListsAtScale() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await seedBulk(account, db: conn)

                // Inbox: 3600 rows, 1200 of them unread — the 150 unread rows
                // on the archived/deleted/sent axes must not leak into the
                // badge.
                let inbox = try await MessageStore.recent(
                    forAccount: account.id, limit: 10_000, sender: nil,
                    archived: false, deleted: false, sent: false,
                    stackMatch: nil, db: conn
                )
                XCTAssertEqual(inbox.count, 3600)
                let unread = try await MessageStore.unreadCount(
                    forAccount: account.id, db: conn
                )
                XCTAssertEqual(unread, 1200)
                XCTAssertEqual(
                    unread, inbox.filter { !$0.isRead }.count,
                    "the unread badge and the inbox list must agree at scale"
                )

                let sentList = try await MessageStore.recent(
                    forAccount: account.id, limit: 10_000, sender: nil,
                    archived: false, deleted: false, sent: true,
                    stackMatch: nil, db: conn
                )
                XCTAssertEqual(sentList.count, 800)
                let sent = try await MessageStore.sentCount(forAccount: account.id, db: conn)
                XCTAssertEqual(sent, 800)

                let trashList = try await MessageStore.recent(
                    forAccount: account.id, limit: 10_000, sender: nil,
                    archived: false, deleted: true, sent: false,
                    stackMatch: nil, db: conn
                )
                XCTAssertEqual(trashList.count, 300)
                let deleted = try await MessageStore.deletedCount(
                    forAccount: account.id, db: conn
                )
                XCTAssertEqual(deleted, 300)
                let trashedIds = try await MessageStore.trashedRemoteIds(
                    forAccount: account.id, db: conn
                )
                XCTAssertEqual(
                    trashedIds.count, trashList.count,
                    "清空废纸篓 must resolve exactly the rows the trash lists"
                )
            }
        }
    }
}
