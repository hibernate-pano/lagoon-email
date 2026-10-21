import XCTest
import Foundation
import Logging
import Hummingbird
import HummingbirdTesting
import NIOCore
import GRDB
@testable import LagoonServer
@testable import LagoonKit

/// Covers `GET /api/export/index?accountId=` — the listing the `.mbox` export
/// walks.
///
/// ## Why this route is worth its own tests
///
/// The export has to enumerate **every** message, and the obvious source —
/// `GET /api/messages` — cannot: it is capped at `maxListRows` (1000) with no
/// cursor, so an export built on it would stop at the cap and write a file
/// that looks complete. These tests pin the three properties that make the
/// index a correct replacement:
///
/// * it returns **every** row, past the list cap (that is the whole point);
/// * it is **scoped to one account** — a remote id is only unique within an
///   account, so leaking another mailbox's rows would export the wrong mail;
/// * it is **read-only** and orders oldest-first, which is the order an
///   importer lands messages in.
final class BackupRouteTests: XCTestCase {
    private let logger = Logger(label: "backup-route-tests")

    private func makeAccount(email: String = "backup@qq.com") -> Account {
        Account(
            id: UUID(),
            provider: .qq,
            oauthUser: "backup-\(UUID().uuidString)",
            email: email,
            credentials: nil
        )
    }

    private func seedAccount(_ account: Account, db: LagoonDB) async throws {
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
        receivedAt: Date = Date(),
        db: LagoonDB
    ) async throws {
        try await MessageStore.upsert(
            MessageHeader(
                id: UUID(),
                accountId: accountId,
                remoteId: remoteId,
                threadId: "t-\(remoteId)",
                fromAddress: "sender@example.com",
                fromName: "Sender",
                subject: "Subject \(remoteId)",
                snippet: nil,
                receivedAt: receivedAt,
                isRead: true,
                isArchived: false
            ),
            db: db
        )
    }

    private func get(
        _ uri: String, db: LagoonDB
    ) async throws -> (status: HTTPResponse.Status, body: Data) {
        let router = Router<BasicRequestContext>()
        BackupRoutes.register(on: router, db: db, logger: logger)
        let app = Application(router: router)
        var thrown: (HTTPResponse.Status, Data)?
        try await app.test(.router) { client in
            try await client.execute(uri: uri, method: .get) { response in
                thrown = (response.status, Data(buffer: response.body))
            }
        }
        return try XCTUnwrap(thrown, "the route answered nothing")
    }

    private struct Index: Decodable {
        let messages: [MessageHeader]
        let totalCount: Int
        let deletedCount: Int
        let sentCount: Int
    }

    private func decode(_ body: Data) throws -> Index {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Index.self, from: body)
    }

    /// The index must return every row, **past** the 1000-row list cap.
    ///
    /// This is the reason the route exists. If it were built on the list
    /// route, a 1,200-message mailbox would export 1,000 and the file would
    /// look complete — a silent partial backup, the exact class of failure
    /// this product refuses to ship.
    func test_theIndexReturnsEveryMessageBeyondTheListCap() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seedAccount(account, db: conn)
                // One more than the list route's ceiling.
                let count = SyncRoutes.maxListRows + 20
                for index in 0..<count {
                    try await seedMessage(
                        "m\(index)",
                        accountId: account.id,
                        receivedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                        db: conn
                    )
                }
                let response = try await get(
                    "/api/export/index?accountId=\(account.id.uuidString)", db: conn
                )
                XCTAssertEqual(response.status, .ok)
                let index = try decode(response.body)
                XCTAssertEqual(
                    index.messages.count, count,
                    "the export index must not inherit the list route's cap"
                )
                XCTAssertEqual(index.totalCount, count)
            }
        }
    }

    /// Another account's mail must not appear.
    ///
    /// Remote ids are only unique per account, so an export that ignored the
    /// scope would write the wrong message under the right id — the user's
    /// import would contain mail from a mailbox they did not select.
    func test_theIndexIsScopedToOneAccount() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let mine = makeAccount(email: "mine@qq.com")
            let other = makeAccount(email: "other@qq.com")
            try await TestDatabase.withConnection { conn in
                try await seedAccount(mine, db: conn)
                try await seedAccount(other, db: conn)
                try await seedMessage("mine-1", accountId: mine.id, db: conn)
                try await seedMessage("other-1", accountId: other.id, db: conn)

                let response = try await get(
                    "/api/export/index?accountId=\(mine.id.uuidString)", db: conn
                )
                let index = try decode(response.body)
                XCTAssertEqual(index.messages.map(\.remoteId), ["mine-1"])
            }
        }
    }

    /// Oldest first — the order every mail client writes and imports.
    func test_theIndexIsOrderedOldestFirst() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seedAccount(account, db: conn)
                try await seedMessage(
                    "newest", accountId: account.id,
                    receivedAt: Date(timeIntervalSince1970: 300), db: conn
                )
                try await seedMessage(
                    "oldest", accountId: account.id,
                    receivedAt: Date(timeIntervalSince1970: 100), db: conn
                )
                try await seedMessage(
                    "middle", accountId: account.id,
                    receivedAt: Date(timeIntervalSince1970: 200), db: conn
                )
                let response = try await get(
                    "/api/export/index?accountId=\(account.id.uuidString)", db: conn
                )
                let index = try decode(response.body)
                XCTAssertEqual(
                    index.messages.map(\.remoteId), ["oldest", "middle", "newest"]
                )
            }
        }
    }

    /// Archived and trashed mail is part of "all my mail".
    ///
    /// A user migrating to another client expects the whole mailbox, not
    /// just the inbox. Leaving the archive out would silently lose the mail
    /// they filed — and the Trash count in the response is how the UI can
    /// say so out loud.
    func test_theIndexIncludesArchivedAndTrashedMail() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seedAccount(account, db: conn)
                try await seedMessage("inbox", accountId: account.id, db: conn)
                try await seedMessage("archived", accountId: account.id, db: conn)
                try await MessageStore.setArchived(
                    true, remoteId: "archived", accountId: account.id, db: conn
                )
                try await seedMessage("trashed", accountId: account.id, db: conn)
                try await MessageStore.setDeleted(
                    remoteId: "trashed", accountId: account.id,
                    deleted: true, db: conn
                )

                let response = try await get(
                    "/api/export/index?accountId=\(account.id.uuidString)", db: conn
                )
                let index = try decode(response.body)
                XCTAssertEqual(
                    index.messages.map(\.remoteId).sorted(),
                    ["archived", "inbox", "trashed"],
                    "an export must cover the whole mailbox, not just the inbox"
                )
                XCTAssertEqual(
                    index.deletedCount, 1,
                    "the trashed rows must be counted so the UI can say so"
                )
            }
        }
    }

    /// A malformed or unknown account is a typed error, not an empty list.
    ///
    /// An empty `200` would make a broken export look like "this mailbox has
    /// no mail", which is a different and wrong statement.
    func test_aMalformedOrUnknownAccountIsRejected() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            try await TestDatabase.withConnection { conn in
                let malformed = try await get("/api/export/index?accountId=nope", db: conn)
                XCTAssertEqual(malformed.status, .badRequest)

                let unknown = try await get(
                    "/api/export/index?accountId=\(UUID().uuidString)", db: conn
                )
                XCTAssertEqual(unknown.status, .notFound)

                let missing = try await get("/api/export/index", db: conn)
                XCTAssertEqual(missing.status, .badRequest)
            }
        }
    }

    /// The route must be read-only: running it must not change the mailbox.
    ///
    /// An export is a read. If it wrote anything — a "last exported" stamp,
    /// a row-mutation — it would be a second source of truth about the
    /// mailbox and a reason for a sync round to disagree with itself.
    func test_theIndexDoesNotModifyAnything() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seedAccount(account, db: conn)
                try await seedMessage("m1", accountId: account.id, db: conn)
                let before = try await MessageStore.count(
                    forAccount: account.id, db: conn
                )
                _ = try await get(
                    "/api/export/index?accountId=\(account.id.uuidString)", db: conn
                )
                let after = try await MessageStore.count(
                    forAccount: account.id, db: conn
                )
                XCTAssertEqual(before, after)
            }
        }
    }
}
