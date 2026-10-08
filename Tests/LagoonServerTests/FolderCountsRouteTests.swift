import XCTest
import Foundation
import Logging
import Hummingbird
import NIOCore
import GRDB
@testable import LagoonKit
@testable import LagoonServer

/// End-to-end for `GET /api/folder-counts` — the numbers the navigation column
/// shows next to every destination.
///
/// These matter more than a typical read route's tests because the whole point
/// of the sidebar is that a count is *trustworthy*: a wrong number is worse than
/// no number, because the user makes a decision with it ("only 3 unread, fine"
/// when there are 30). Every test here therefore seeds a known mix and asserts
/// the exact figures rather than "greater than zero".
final class FolderCountsRouteTests: XCTestCase {
    private let logger = Logger(label: "folder-counts-tests")

    private func makeAccount() -> Account {
        Account(
            id: UUID(),
            provider: .qq,
            oauthUser: "fc-\(UUID().uuidString)",
            email: "fc-\(UUID().uuidString)@qq.com",
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
        isRead: Bool = false,
        archived: Bool = false,
        deleted: Bool = false,
        pinned: Bool = false,
        fromAddress: String = "sender@example.com"
    ) async throws {
        try await MessageStore.upsert(
            MessageHeader(
                id: UUID(),
                accountId: accountId,
                remoteId: remoteId,
                threadId: "t-\(remoteId)",
                fromAddress: fromAddress,
                fromName: "Sender",
                subject: "Subject \(remoteId)",
                snippet: "snippet",
                receivedAt: Date(),
                isRead: isRead,
                isArchived: archived
            ),
            db: db
        )
        // `upsert` deliberately never writes is_deleted: a header arriving from
        // the provider is by definition not deleted, and letting a sync
        // resurrect the flag would undo a user's delete. The flag is only ever
        // set through `setDeleted`, so the fixture must use it too.
        if deleted {
            try await MessageStore.setDeleted(
                remoteId: remoteId, accountId: accountId, deleted: true, db: db
            )
        }
        if pinned {
            try await MessageStore.setPinned(true, remoteId: remoteId, accountId: accountId, db: db)
        }
    }

    private func router(_ db: LagoonDB) -> Router<BasicRequestContext> {
        let router = Router()
        FolderCountsRoutes.register(on: router, db: db, logger: self.logger)
        return router
    }

    private func fetch(_ accountId: UUID, db: LagoonDB) async throws -> [String: Int] {
        let app = Application(router: router(db))
        var result: [String: Int] = [:]
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/folder-counts?accountId=\(accountId.uuidString)",
                method: .get
            ) { response in
                XCTAssertEqual(response.status, .ok)
                let decoded = try JSONDecoder().decode(
                    FolderCountsResponse.self,
                    from: Data(response.body.readableBytesView)
                )
                result = Dictionary(uniqueKeysWithValues: decoded.counts.map { ($0.id, $0.count) })
            }
        }
        return result
    }

    /// Every fixed key is present on every response, even at zero.
    ///
    /// A missing key and a zero are different facts — "we have not checked" vs
    /// "there is nothing here" — and the sidebar renders them differently. If
    /// the route ever omits a bucket, the client must not silently treat it as
    /// zero, so this asserts presence rather than value.
    func test_everyFixedKey_isAlwaysPresent() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                let counts = try await fetch(account.id, db: conn)
                XCTAssertEqual(
                    Set(counts.keys), Set(FolderCountKey.all),
                    "the sidebar reads fixed keys; a missing one would render as 'not checked'"
                )
                for key in FolderCountKey.all {
                    XCTAssertEqual(counts[key], 0, "\(key) should be zero on an empty mailbox")
                }
            }
        }
    }

    /// The figures separate the destinations that used to be indistinguishable.
    func test_counts_separateLiveUnreadArchivedPinnedAndDeleted() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                // 3 live (one unread, one pinned), 2 archived, 1 deleted.
                try await seedMessage("live-unread", accountId: account.id, db: conn)
                try await seedMessage("live-read", accountId: account.id, db: conn, isRead: true)
                try await seedMessage(
                    "live-pinned", accountId: account.id, db: conn, isRead: true, pinned: true
                )
                try await seedMessage("arch-1", accountId: account.id, db: conn, archived: true)
                try await seedMessage("arch-2", accountId: account.id, db: conn, archived: true)
                try await seedMessage("del-1", accountId: account.id, db: conn, deleted: true)

                let counts = try await fetch(account.id, db: conn)
                // Live excludes archived and deleted: it is the same query the
                // All Messages surface lists, so badge and list cannot disagree.
                XCTAssertEqual(counts[FolderCountKey.live], 3)
                XCTAssertEqual(counts[FolderCountKey.unread], 1)
                XCTAssertEqual(counts[FolderCountKey.archived], 2)
                XCTAssertEqual(counts[FolderCountKey.pinned], 1)
                XCTAssertEqual(counts[FolderCountKey.deleted], 1)
            }
        }
    }

    /// A pin on a message the user also deleted still counts as a pin.
    ///
    /// Deliberate, and pinned here so it cannot be "fixed" by accident: the pin
    /// list is where a user looks for what they deliberately kept, and a pin that
    /// vanished because the message was trashed would be a worse answer than a
    /// count that is not obviously comparable to its neighbours.
    func test_pinnedCount_includesPinsOnDeletedMessages() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await seedMessage(
                    "gone", accountId: account.id, db: conn, deleted: true, pinned: true
                )
                let counts = try await fetch(account.id, db: conn)
                XCTAssertEqual(counts[FolderCountKey.pinned], 1)
                XCTAssertEqual(
                    counts[FolderCountKey.deleted], 1,
                    "and the deleted bucket still reports it as recoverable"
                )
            }
        }
    }

    /// Counts are per-account. A second mailbox's mail must not inflate the
    /// first one's sidebar — the multi-account case is already supported
    /// elsewhere, and a shared count would silently mis-report both.
    func test_counts_areScopedToOneAccount() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let first = makeAccount()
            let second = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(first, db: conn)
                try await seed(second, db: conn)
                try await seedMessage("a1", accountId: first.id, db: conn)
                try await seedMessage("b1", accountId: second.id, db: conn)
                try await seedMessage("b2", accountId: second.id, db: conn)

                let counts = try await fetch(first.id, db: conn)
                XCTAssertEqual(counts[FolderCountKey.live], 1, "must not include the other mailbox")
                XCTAssertEqual(counts[FolderCountKey.unread], 1)
            }
        }
    }

    /// An unknown account is404 rather than a row of zeros.
    ///
    /// Zeros would be a plausible-looking lie: the sidebar would render an
    /// empty mailbox instead of saying the account is gone.
    func test_unknownAccount_isNotFound() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            try await TestDatabase.withConnection { conn in
                let app = Application(router: router(conn))
                try await app.test(.router) { client in
                    try await client.execute(
                        uri: "/api/folder-counts?accountId=\(UUID().uuidString)",
                        method: .get
                    ) { response in
                        XCTAssertEqual(response.status, .notFound)
                    }
                }
            }
        }
    }

    /// A malformed id is rejected at the door, not coerced to zero.
    func test_malformedAccountId_isBadRequest() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            try await TestDatabase.withConnection { conn in
                let app = Application(router: router(conn))
                try await app.test(.router) { client in
                    try await client.execute(
                        uri: "/api/folder-counts?accountId=not-a-uuid",
                        method: .get
                    ) { response in
                        XCTAssertEqual(response.status, .badRequest)
                    }
                }
            }
        }
    }

    /// The route reads only. It must not create, modify or remove a single row,
    /// so calling it twice on the same mailbox is indistinguishable from calling
    /// it once.
    func test_route_isReadOnly_acrossRepeatedCalls() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await seedMessage("m1", accountId: account.id, db: conn)
                let first = try await fetch(account.id, db: conn)
                let second = try await fetch(account.id, db: conn)
                XCTAssertEqual(first, second, "counting must not be cumulative")
                // And the message is still there, untouched.
                let stillThere = try await MessageStore.count(forAccount: account.id, db: conn)
                XCTAssertEqual(stillThere, 1)
            }
        }
    }
}