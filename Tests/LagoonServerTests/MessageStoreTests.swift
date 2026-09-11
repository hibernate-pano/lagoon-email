import XCTest
import PostgresNIO
@testable import LagoonServer
@testable import LagoonKit

final class MessageStoreTests: XCTestCase {
    private func makeAccount(oauthUser: String) -> Account {
        Account(
            id: UUID(),
            provider: .gmail,
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
        isArchived: Bool = false
    ) -> MessageHeader {
        MessageHeader(
            id: UUID(),
            accountId: account.id,
            remoteId: remoteId,
            threadId: "t1",
            fromAddress: "alice@example.com",
            fromName: "Alice",
            subject: "Hi",
            snippet: "Hello",
            receivedAt: Date(),
            isRead: isRead,
            isArchived: isArchived
        )
    }

    /// Deletes only this test's account (by `oauth_user`); `message_headers`
    /// rows are removed by the `ON DELETE CASCADE` FK.
    private func cleanup(_ oauthUser: String) -> @Sendable (PostgresConnection) async -> Void {
        { conn in
            try? await TestDatabase.deleteAccount(oauthUser: oauthUser, provider: .gmail, db: conn)
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
}
