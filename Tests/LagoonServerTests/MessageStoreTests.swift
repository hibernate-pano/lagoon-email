import XCTest
import GRDB
@testable import LagoonServer
@testable import LagoonKit

final class MessageStoreTests: XCTestCase {
    private func makeAccount(oauthUser: String) -> Account {
        Account(
            id: UUID(),
            provider: .qq,
            oauthUser: oauthUser,
            email: "m@example.com",
            credentials: nil,
            syncState: MailSyncState()
        )
    }

    private func makeMessage(
        account: Account,
        remoteId: String,
        isRead: Bool = false,
        isArchived: Bool = false,
        subject: String? = "Hi",
        snippet: String? = "Hello"
    ) -> MessageHeader {
        MessageHeader(
            id: UUID(),
            accountId: account.id,
            remoteId: remoteId,
            threadId: "t1",
            fromAddress: "alice@example.com",
            fromName: "Alice",
            subject: subject,
            snippet: snippet,
            receivedAt: Date(),
            isRead: isRead,
            isArchived: isArchived
        )
    }

    /// Deletes only this test's account (by `oauth_user`); `message_headers`
    /// rows are removed by the `ON DELETE CASCADE` FK.
    private func cleanup(_ oauthUser: String) -> @Sendable (LagoonDB) async -> Void {
        { conn in
            try? await TestDatabase.deleteAccount(oauthUser: oauthUser, provider: .qq, db: conn)
        }
    }

    func test_upsert_and_recent() async throws {
        let oauthUser = "msg-\(UUID().uuidString)"
        try await TestDatabase.withConnection(cleanup: cleanup(oauthUser)) { conn in
            let account = makeAccount(oauthUser: oauthUser)
            try await AccountStore.upsert(
                account,
                credentials: Data([1]),
                db: conn
            )
            let msg = makeMessage(account: account, remoteId: "g-\(UUID().uuidString)")
            try await MessageStore.upsert(msg, db: conn)

            let recent = try await MessageStore.recent(forAccount: account.id, limit: 10, db: conn)
            XCTAssertEqual(recent.count, 1)
            XCTAssertEqual(recent.first?.remoteId, msg.remoteId)
            XCTAssertEqual(recent.first?.isRead, false)
        }
    }

    func test_reUpsertAfterMarkRead_keepsReadState() async throws {
        let oauthUser = "msg-\(UUID().uuidString)"
        try await TestDatabase.withConnection(cleanup: cleanup(oauthUser)) { conn in
            let account = makeAccount(oauthUser: oauthUser)
            try await AccountStore.upsert(
                account,
                credentials: Data([1]),
                db: conn
            )
            let remoteId = "g-\(UUID().uuidString)"
            try await MessageStore.upsert(
                makeMessage(account: account, remoteId: remoteId, isRead: false),
                db: conn
            )
            try await MessageStore.markRead(remoteId: remoteId, accountId: account.id, db: conn)

            // Regression: the poller used to re-upsert and clobber is_read back
            // to false. The conflict update must not touch read state.
            try await MessageStore.upsert(
                makeMessage(account: account, remoteId: remoteId, isRead: false),
                db: conn
            )

            let recent = try await MessageStore.recent(forAccount: account.id, limit: 10, db: conn)
            XCTAssertEqual(recent.count, 1)
            XCTAssertEqual(recent.first?.isRead, true, "re-upsert must not clobber is_read")
            let unread = try await MessageStore.unreadCount(forAccount: account.id, db: conn)
            XCTAssertEqual(unread, 0)
        }
    }

    /// Regression: `IMAPProvider.readStateFlips` re-delivers a header for
    /// every message whose `\Seen` flag changed, and that re-fetch carries no
    /// snippet. The conflict clause used to write `EXCLUDED.snippet`
    /// unconditionally, so opening a single message blanked its preview in the
    /// list — and it never came back, because that UID is never re-fetched
    /// with a body peek.
    func test_reUpsert_withoutSnippet_keepsStoredSnippetAndSubject() async throws {
        let oauthUser = "msg-\(UUID().uuidString)"
        try await TestDatabase.withConnection(cleanup: cleanup(oauthUser)) { conn in
            let account = makeAccount(oauthUser: oauthUser)
            try await AccountStore.upsert(account, credentials: Data([1]), db: conn)
            let remoteId = "g-\(UUID().uuidString)"
            try await MessageStore.upsert(
                makeMessage(account: account, remoteId: remoteId), db: conn
            )

            // Exactly what readStateFlips delivers: same identity, no snippet.
            try await MessageStore.upsert(
                makeMessage(
                    account: account, remoteId: remoteId,
                    isRead: true, subject: nil, snippet: nil
                ),
                db: conn
            )

            let recent = try await MessageStore.recent(forAccount: account.id, limit: 10, db: conn)
            XCTAssertEqual(recent.count, 1)
            XCTAssertEqual(recent.first?.snippet, "Hello", "a snippet-less re-upsert must not blank the preview")
            XCTAssertEqual(recent.first?.subject, "Hi", "a subject-less re-upsert must not blank the title")
            XCTAssertEqual(recent.first?.isRead, true, "the read flip itself must still land")
        }
    }

    /// Regression: `upsert` computed the merged link set and then bound the
    /// *pre-merge* value, so every sync round replaced the stored
    /// `unsubscribe_links` with only that round's header links. Links
    /// harvested from the message body by `mergeUnsubscribeLinks` therefore
    /// survived until the next sync and were then gone — silently killing the
    /// one-click unsubscribe path the product is built around.
    func test_reUpsert_preservesUnsubscribeLinksHarvestedFromTheBody() async throws {
        let oauthUser = "msg-\(UUID().uuidString)"
        try await TestDatabase.withConnection(cleanup: cleanup(oauthUser)) { conn in
            let account = makeAccount(oauthUser: oauthUser)
            try await AccountStore.upsert(account, credentials: Data([1]), db: conn)
            let remoteId = "g-\(UUID().uuidString)"

            // Round 1: the sync engine only ever sees the List-Unsubscribe header.
            try await MessageStore.upsert(
                makeMessage(account: account, remoteId: remoteId),
                listUnsubscribe: true,
                unsubscribeLinks: ["https://news.example/header"],
                db: conn
            )
            // Later, opening the message scrapes a link out of the HTML body.
            try await MessageStore.mergeUnsubscribeLinks(
                remoteId: remoteId,
                accountId: account.id,
                links: ["https://news.example/from-body"],
                db: conn
            )
            // Round 2: the same header link arrives again.
            try await MessageStore.upsert(
                makeMessage(account: account, remoteId: remoteId),
                listUnsubscribe: true,
                unsubscribeLinks: ["https://news.example/header"],
                db: conn
            )

            let links = try await MessageStore.unsubscribeLinks(
                remoteId: remoteId, accountId: account.id, db: conn
            )
            XCTAssertEqual(
                Set(links),
                ["https://news.example/header", "https://news.example/from-body"],
                "a re-sync must not wipe body-harvested unsubscribe links"
            )
        }
    }

    func test_unreadCount_onlyUnreadNonArchived() async throws {
        let oauthUser = "msg-\(UUID().uuidString)"
        try await TestDatabase.withConnection(cleanup: cleanup(oauthUser)) { conn in
            let account = makeAccount(oauthUser: oauthUser)
            try await AccountStore.upsert(
                account,
                credentials: Data([1]),
                db: conn
            )

            // Counted: unread + not archived.
            try await MessageStore.upsert(
                makeMessage(account: account, remoteId: "unread-\(UUID().uuidString)", isRead: false, isArchived: false),
                db: conn
            )
            // Not counted: read.
            try await MessageStore.upsert(
                makeMessage(account: account, remoteId: "read-\(UUID().uuidString)", isRead: true, isArchived: false),
                db: conn
            )
            // Not counted: archived (even though unread).
            try await MessageStore.upsert(
                makeMessage(account: account, remoteId: "archived-\(UUID().uuidString)", isRead: false, isArchived: true),
                db: conn
            )

            let unread = try await MessageStore.unreadCount(forAccount: account.id, db: conn)
            XCTAssertEqual(unread, 1)
        }
    }

    /// Pins live in their own table, so a plain `message_headers` read
    /// cannot answer "is this pinned?". Without the join the client had no
    /// pin state at all and every detail view opened with the button reading
    /// "置顶" — including for mail the user had already pinned.
    func test_recent_reportsPinState() async throws {
        let oauthUser = "msg-\(UUID().uuidString)"
        try await TestDatabase.withConnection(cleanup: cleanup(oauthUser)) { conn in
            let account = makeAccount(oauthUser: oauthUser)
            try await AccountStore.upsert(account, credentials: Data([1]), db: conn)
            let pinned = makeMessage(account: account, remoteId: "pinned-\(UUID().uuidString)")
            let plain = makeMessage(account: account, remoteId: "plain-\(UUID().uuidString)")
            try await MessageStore.upsert(pinned, db: conn)
            try await MessageStore.upsert(plain, db: conn)
            try await MessageStore.setPinned(
                true, remoteId: pinned.remoteId, accountId: account.id, db: conn
            )

            let byRemoteId = Dictionary(
                uniqueKeysWithValues: try await MessageStore
                    .recent(forAccount: account.id, limit: 50, db: conn)
                    .map { ($0.remoteId, $0) }
            )
            XCTAssertEqual(byRemoteId[pinned.remoteId]?.isPinned, true)
            XCTAssertEqual(byRemoteId[plain.remoteId]?.isPinned, false)

            // Unpinning has to travel back out through the same join.
            try await MessageStore.setPinned(
                false, remoteId: pinned.remoteId, accountId: account.id, db: conn
            )
            let after = try await MessageStore.recent(forAccount: account.id, limit: 50, db: conn)
            XCTAssertEqual(after.first { $0.remoteId == pinned.remoteId }?.isPinned, false)
        }
    }

    /// The join must not change what the list returns: same rows, same
    /// order, same filters (archived / sender / stack) as before.
    func test_recent_pinJoin_preservesFilteringAndOrder() async throws {
        let oauthUser = "msg-\(UUID().uuidString)"
        try await TestDatabase.withConnection(cleanup: cleanup(oauthUser)) { conn in
            let account = makeAccount(oauthUser: oauthUser)
            try await AccountStore.upsert(account, credentials: Data([1]), db: conn)
            let now = Date()
            for index in 0..<5 {
                let header = makeMessage(
                    account: account,
                    remoteId: "row-\(index)",
                    subject: "report row \(index)"
                )
                try await MessageStore.upsert(
                    MessageHeader(
                        id: header.id, accountId: account.id, remoteId: header.remoteId,
                        threadId: header.threadId, fromAddress: "alice@example.com",
                        fromName: header.fromName, subject: header.subject, snippet: header.snippet,
                        receivedAt: now.addingTimeInterval(TimeInterval(index)),
                        isRead: false, isArchived: false
                    ),
                    db: conn
                )
            }
            // Pin the oldest row: a LEFT JOIN that changed the ordering
            // would show up here.
            try await MessageStore.setPinned(
                true, remoteId: "row-0", accountId: account.id, db: conn
            )

            let rows = try await MessageStore.recent(forAccount: account.id, limit: 5, db: conn)
            XCTAssertEqual(rows.map(\.remoteId), ["row-4", "row-3", "row-2", "row-1", "row-0"])

            let bySender = try await MessageStore.recent(
                forAccount: account.id, limit: 5, sender: "alice@example.com", db: conn
            )
            XCTAssertEqual(bySender.count, 5)
            let byOther = try await MessageStore.recent(
                forAccount: account.id, limit: 5, sender: "nobody@example.com", db: conn
            )
            XCTAssertTrue(byOther.isEmpty)

            let byStack = try await MessageStore.recent(
                forAccount: account.id, limit: 5,
                stackMatch: .keyword("row 3"), db: conn
            )
            XCTAssertEqual(byStack.map(\.remoteId), ["row-3"])
        }
    }
}
