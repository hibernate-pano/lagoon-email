import XCTest
import Foundation
import Logging
import Hummingbird
import NIOCore
import GRDB
@testable import LagoonKit
@testable import LagoonServer

/// The 废纸篓 listing itself: `GET /api/messages?deleted=true`.
///
/// ## Why this test exists
///
/// Every other view in the product filters trashed mail out — correctly, since
/// deleted mail should not appear in the inbox or inflate unread counts. But
/// that left the Trash with **no way to list its contents at all**. A user who
/// deleted a mail by mistake had exactly two options: an 8-second undo toast, or
/// opening a different mail client.
///
/// Worse, the sidebar row for 废纸篓 existed and pointed at `.all`, so clicking it
/// showed the inbox. A button that lies about where it takes you is worse than
/// no button.
///
/// These tests pin the listing, and pin that the two axes stay independent: a
/// message can be archived, deleted, both, or neither, and each combination must
/// land in exactly one place.
final class TrashListingTests: XCTestCase {
    private let logger = Logger(label: "trash-listing-tests")

    private func makeAccount() -> Account {
        // Capabilities are explicit because a default-constructed `Account`
        // carries `MailCapabilities.unknown` (every flag false), which would make
        // an archive-related route 409 for reasons that have nothing to do with
        // what these tests are checking.
        Account(
            id: UUID(),
            provider: .qq,
            oauthUser: "trash-\(UUID().uuidString)",
            email: "trash-\(UUID().uuidString)@qq.com",
            credentials: nil,
            capabilities: MailCapabilities(
                archiveFolder: true, idle: true, move: true, serverSnippet: false
            )
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
        archived: Bool = false,
        deleted: Bool = false
    ) async throws {
        try await MessageStore.upsert(
            MessageHeader(
                id: UUID(),
                accountId: accountId,
                remoteId: remoteId,
                threadId: "t-\(remoteId)",
                fromAddress: "sender@example.com",
                fromName: nil,
                subject: "Subject \(remoteId)",
                snippet: nil,
                receivedAt: Date(),
                isRead: true,
                isArchived: archived
            ),
            db: db
        )
        // `upsert` deliberately never writes is_deleted; only `setDeleted` does.
        if deleted {
            try await MessageStore.setDeleted(
                remoteId: remoteId, accountId: accountId, deleted: true, db: db
            )
        }
    }

    private func list(
        _ accountId: UUID, _ db: LagoonDB, archived: Bool = false, deleted: Bool = false
    ) async throws -> (rows: [String], total: Int) {
        // SyncRoutes owns GET /api/messages — MessageRoutes is the per-message
        // body/attachment endpoints. Registering the wrong one produces a 404
        // that looks like a routing bug rather than a test-setup mistake.
        let router = Router<BasicRequestContext>()
        SyncRoutes.register(on: router, db: db, logger: self.logger)
        let app = Application(router: router)
        var rows: [String] = []
        var total = 0
        try await app.test(.router) { client in
            var uri = "/api/messages?accountId=\(accountId.uuidString)"
            uri += "&archived=\(archived ? "true" : "false")"
            uri += "&deleted=\(deleted ? "true" : "false")"
            try await client.execute(uri: uri, method: .get) { response in
                XCTAssertEqual(response.status, .ok)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let decoded = try decoder.decode(
                    SyncResponse.self, from: Data(response.body.readableBytesView)
                )
                rows = decoded.messages.map(\.remoteId).sorted()
                total = decoded.totalCount ?? decoded.messages.count
            }
        }
        return (rows, total)
    }

    /// The Trash lists exactly the deleted rows, and nothing else.
    func test_trashListsOnlyDeletedMail() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await seedMessage("live1", accountId: account.id, db: conn)
                try await seedMessage("live2", accountId: account.id, db: conn, archived: true)
                try await seedMessage("gone1", accountId: account.id, db: conn, deleted: true)
                try await seedMessage("gone2", accountId: account.id, db: conn, deleted: true)

                let trash = try await list(account.id, conn, deleted: true)
                XCTAssertEqual(trash.rows, ["gone1", "gone2"])
                XCTAssertEqual(trash.total, 2)
            }
        }
    }

    /// The two axes are independent, and a deleted+archived message belongs to
    /// the trash only.
    ///
    /// This is the case that produces a duplicate row if the axes are collapsed:
    /// a mail archived in March and deleted in April is in both folders on the
    /// server. The trash listing passes `archived=false` deliberately, so it
    /// shows up in exactly one place — and so does the 档案柜 listing, because
    /// that one filters deleted out.
    func test_archivedAndDeletedAreIndependentAxes() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await seedMessage(
                    "both", accountId: account.id, db: conn, archived: true, deleted: true
                )
                try await seedMessage("archOnly", accountId: account.id, db: conn, archived: true)
                try await seedMessage("delOnly", accountId: account.id, db: conn, deleted: true)

                // Trash: only the deleted ones, archived or not.
                let trash = try await list(account.id, conn, deleted: true)
                XCTAssertEqual(trash.rows, ["both", "delOnly"])

                // 档案柜: only the archived-and-not-deleted ones.
                let archive = try await list(account.id, conn, archived: true)
                XCTAssertEqual(
                    archive.rows, ["archOnly"],
                    "a deleted message must not linger in the archive cabinet"
                )

                // Inbox: neither axis.
                let inbox = try await list(account.id, conn)
                XCTAssertTrue(inbox.rows.isEmpty)

                // No message appears in two lists.
                let all = Set(trash.rows).union(archive.rows).union(inbox.rows)
                XCTAssertEqual(all, ["both", "archOnly", "delOnly"])
            }
        }
    }

    /// The count and the rows come from the same clause, so the sidebar badge
    /// cannot disagree with the list it labels.
    func test_trashCountMatchesItsRows() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                for i in 1...5 {
                    try await seedMessage(
                        "g\(i)", accountId: account.id, db: conn, deleted: true
                    )
                }
                let trash = try await list(account.id, conn, deleted: true)
                XCTAssertEqual(trash.rows.count, trash.total)
            }
        }
    }

    /// The inbox is unchanged by the new parameter.
    ///
    /// `deleted` defaults to false and every existing call site passes nothing,
    /// so the hottest path (the 30s poll) must behave exactly as before. A
    /// regression here would silently empty the user's inbox.
    func test_defaultListingIsUnchangedByTheNewParameter() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await seedMessage("i1", accountId: account.id, db: conn)
                try await seedMessage("i2", accountId: account.id, db: conn)
                try await seedMessage("i3", accountId: account.id, db: conn, deleted: true)

                let inbox = try await list(account.id, conn)
                XCTAssertEqual(inbox.rows, ["i1", "i2"])
                XCTAssertEqual(inbox.total, 2)
            }
        }
    }
}
