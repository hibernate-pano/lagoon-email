import XCTest
import Foundation
import Logging
import Hummingbird
import HummingbirdTesting
import NIOCore
import GRDB
@testable import LagoonKit
@testable import LagoonServer

/// The reminder store and the routes over it.
///
/// ## Why this file exists
///
/// The AI's action vocabulary included "remind", the row carried a bell
/// icon and the copy read "建议提醒" — and nothing was stored, nothing was
/// scheduled, nothing ever happened. The user was shown a promise the
/// product could not keep, which is worse than not making it: it teaches
/// the user to distrust every other suggestion.
///
/// These tests pin the three things that make the promise real: a reminder
/// is stored, it survives the process, and the routes can set, list,
/// dismiss and delete it.
final class ReminderStoreTests: XCTestCase {
    private let logger = Logger(label: "reminder-tests")

    private func makeAccount() -> Account {
        Account(
            id: UUID(),
            provider: .qq,
            oauthUser: "rem-\(UUID().uuidString)",
            email: "rem-\(UUID().uuidString)@qq.com",
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

    private func header(_ remoteId: String, accountId: UUID) -> MessageHeader {
        MessageHeader(
            id: UUID(),
            accountId: accountId,
            remoteId: remoteId,
            threadId: "t-\(remoteId)",
            fromAddress: "person@example.com",
            fromName: "Person",
            subject: "Subject \(remoteId)",
            snippet: nil,
            receivedAt: Date(),
            isRead: false,
            isArchived: false
        )
    }

    private func router(_ db: LagoonDB) -> Router<BasicRequestContext> {
        let router = Router()
        ReminderRoutes.register(on: router, db: db, logger: self.logger)
        return router
    }

    /// The body the set route expects.
    ///
    /// A struct rather than a dictionary literal: the payload carries a
    /// `Date` next to a `String`, and a `[String: Any]`-shaped literal
    /// cannot be encoded (the compiler has no way to pick a value type for
    /// the heterogeneous map, and a `Date` in an untyped map would not be
    /// ISO-8601 on the wire anyway).
    private struct SetBody: Encodable {
        let remoteId: String
        let dueAt: Date
    }

    private func setBody(remoteId: String, dueAt: Date) throws -> ByteBuffer {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return ByteBuffer(data: try encoder.encode(SetBody(remoteId: remoteId, dueAt: dueAt)))
    }

    // MARK: - The store

    /// A reminder is stored and comes back.
    func test_aReminderIsStoredAndComesBack() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await MessageStore.upsert(header("m1", accountId: account.id), db: conn)

                let due = Date().addingTimeInterval(3600)
                let stored = try await ReminderStore.set(
                    accountId: account.id, remoteId: "m1", dueAt: due, note: "call back", db: conn
                )
                XCTAssertNotNil(stored, "the reminder was not stored")

                let pending = try await ReminderStore.pending(forAccount: account.id, db: conn)
                XCTAssertEqual(pending.count, 1)
                XCTAssertEqual(pending.first?.remoteId, "m1")
                XCTAssertEqual(pending.first?.note, "call back")
                // The due time survives the round trip to the second.
                XCTAssertEqual(
                    pending.first?.dueAt.timeIntervalSince1970 ?? 0,
                    due.timeIntervalSince1970,
                    accuracy: 1.0
                )
            }
        }
    }

    /// The list carries the mail's subject.
    ///
    /// A reminder list that showed only a time and an id would be a list
    /// the user has to decode: "10月8日 09:00 提醒" next to *what*? The
    /// subject is joined in the same query, so the list costs one round
    /// trip and not one per row.
    func test_theListCarriesTheMailsSubject() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await MessageStore.upsert(header("m1", accountId: account.id), db: conn)
                try await ReminderStore.set(
                    accountId: account.id, remoteId: "m1",
                    dueAt: Date().addingTimeInterval(3600), note: nil, db: conn
                )

                let pending = try await ReminderStore.pending(forAccount: account.id, db: conn)
                XCTAssertEqual(
                    pending.first?.subject,
                    "Subject m1",
                    "the reminder does not say which mail it is about"
                )
            }
        }
    }

    /// A reminder on a message that is not there is refused.
    ///
    /// A reminder points at a mail. Without the foreign key, a typo'd id
    /// would create a reminder the user can never open.
    func test_aReminderOnAMissingMessageIsRefused() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                let stored = try await ReminderStore.set(
                    accountId: account.id,
                    remoteId: "no-such-message",
                    dueAt: Date().addingTimeInterval(3600),
                    note: nil,
                    db: conn
                )
                XCTAssertNil(stored, "a reminder was created for a message that does not exist")
            }
        }
    }

    /// Setting a second reminder on the same mail replaces the first.
    ///
    /// Two reminders on one mail would mean two notifications for one
    /// thing.
    func test_settingAReminderTwiceReplacesTheFirst() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await MessageStore.upsert(header("m1", accountId: account.id), db: conn)

                try await ReminderStore.set(
                    accountId: account.id, remoteId: "m1",
                    dueAt: Date().addingTimeInterval(3600), note: "first", db: conn
                )
                try await ReminderStore.set(
                    accountId: account.id, remoteId: "m1",
                    dueAt: Date().addingTimeInterval(7200), note: "second", db: conn
                )

                let pending = try await ReminderStore.pending(forAccount: account.id, db: conn)
                XCTAssertEqual(pending.count, 1, "two reminders on one mail")
                XCTAssertEqual(pending.first?.note, "second")
            }
        }
    }

    /// A dismissed reminder leaves the pending list but is still there.
    func test_aDismissedReminderLeavesThePendingList() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await MessageStore.upsert(header("m1", accountId: account.id), db: conn)
                let stored = try await ReminderStore.set(
                    accountId: account.id, remoteId: "m1",
                    dueAt: Date().addingTimeInterval(3600), note: nil, db: conn
                )
                let id = try XCTUnwrap(stored?.id)

                let dismissed = try await ReminderStore.setDismissed(
                    reminderId: id, accountId: account.id, dismissed: true, db: conn
                )
                XCTAssertNotNil(dismissed?.dismissedAt)

                let pending = try await ReminderStore.pending(forAccount: account.id, db: conn)
                XCTAssertTrue(pending.isEmpty, "a dismissed reminder is still waiting")

                // And it can come back.
                let restored = try await ReminderStore.setDismissed(
                    reminderId: id, accountId: account.id, dismissed: false, db: conn
                )
                XCTAssertNil(restored?.dismissedAt)
                let pendingAgain = try await ReminderStore.pending(forAccount: account.id, db: conn)
                XCTAssertEqual(pendingAgain.count, 1, "the reminder did not come back")
            }
        }
    }

    /// One account's reminders never show up in another's list.
    func test_remindersDoNotLeakAcrossAccounts() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let mine = makeAccount()
            let theirs = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(mine, db: conn)
                try await seed(theirs, db: conn)
                try await MessageStore.upsert(header("m1", accountId: theirs.id), db: conn)
                try await ReminderStore.set(
                    accountId: theirs.id, remoteId: "m1",
                    dueAt: Date().addingTimeInterval(3600), note: nil, db: conn
                )

                let pending = try await ReminderStore.pending(forAccount: mine.id, db: conn)
                XCTAssertTrue(pending.isEmpty, "another mailbox's reminder leaked in")
            }
        }
    }

    // MARK: - The routes

    /// The list route returns the reminders.
    func test_theListRouteReturnsTheReminders() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await MessageStore.upsert(header("m1", accountId: account.id), db: conn)
                try await ReminderStore.set(
                    accountId: account.id, remoteId: "m1",
                    dueAt: Date().addingTimeInterval(3600), note: "ring", db: conn
                )

                let app = Application(router: router(conn))
                try await app.test(.router) { client in
                    try await client.execute(
                        uri: "/api/reminders?accountId=\(account.id.uuidString)",
                        method: .get
                    ) { response in
                        XCTAssertEqual(response.status, .ok)
                        let decoder = JSONDecoder()
                        decoder.dateDecodingStrategy = .iso8601
                        let body = try decoder.decode(
                            ReminderListResponse.self,
                            from: Data(buffer: response.body)
                        )
                        XCTAssertEqual(body.reminders.count, 1)
                        XCTAssertEqual(body.reminders.first?.note, "ring")
                    }
                }
            }
        }
    }

    /// The set route stores one.
    func test_theSetRouteStoresAReminder() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await MessageStore.upsert(header("m1", accountId: account.id), db: conn)

                let due = Date().addingTimeInterval(3600)
                let payload = try setBody(remoteId: "m1", dueAt: due)

                let app = Application(router: router(conn))
                try await app.test(.router) { client in
                    try await client.execute(
                        uri: "/api/reminders?accountId=\(account.id.uuidString)",
                        method: .post,
                        body: payload
                    ) { response in
                        XCTAssertEqual(response.status, .ok)
                    }
                }

                let pending = try await ReminderStore.pending(forAccount: account.id, db: conn)
                XCTAssertEqual(pending.count, 1, "the reminder did not go through the route")
            }
        }
    }

    /// A reminder due in the past is refused.
    ///
    /// The user meant "later"; the clock disagrees. Storing a row that is
    /// already overdue on creation is a reminder that can never fire —
    /// which is the failure this whole feature exists to remove.
    func test_aReminderDueInThePastIsRefused() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await MessageStore.upsert(header("m1", accountId: account.id), db: conn)

                let payload = try setBody(
                    remoteId: "m1",
                    dueAt: Date().addingTimeInterval(-3600)
                )

                let app = Application(router: router(conn))
                try await app.test(.router) { client in
                    try await client.execute(
                        uri: "/api/reminders?accountId=\(account.id.uuidString)",
                        method: .post,
                        body: payload
                    ) { response in
                        XCTAssertEqual(response.status, .badRequest)
                        let body = String(decoding: response.body.readableBytesView, as: UTF8.self)
                        XCTAssertTrue(
                            body.contains("reminder-due-in-past"),
                            "the client cannot tell a past due date from a bad request: \(body)"
                        )
                    }
                }
            }
        }
    }

    /// A reminder on a message that is not there is a 404.
    func test_aReminderOnAMissingMessageIs404() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)

                let payload = try setBody(
                    remoteId: "no-such-message",
                    dueAt: Date().addingTimeInterval(3600)
                )

                let app = Application(router: router(conn))
                try await app.test(.router) { client in
                    try await client.execute(
                        uri: "/api/reminders?accountId=\(account.id.uuidString)",
                        method: .post,
                        body: payload
                    ) { response in
                        XCTAssertEqual(response.status, .notFound)
                    }
                }
            }
        }
    }

    /// Another account's reminder cannot be dismissed through this account.
    func test_dismissingAnotherAccountsReminderIs404() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let mine = makeAccount()
            let theirs = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(mine, db: conn)
                try await seed(theirs, db: conn)
                try await MessageStore.upsert(header("m1", accountId: theirs.id), db: conn)
                let stored = try await ReminderStore.set(
                    accountId: theirs.id, remoteId: "m1",
                    dueAt: Date().addingTimeInterval(3600), note: nil, db: conn
                )
                let id = try XCTUnwrap(stored?.id)

                let app = Application(router: router(conn))
                try await app.test(.router) { client in
                    try await client.execute(
                        uri: "/api/reminders/\(id)/dismiss?accountId=\(mine.id.uuidString)",
                        method: .post
                    ) { response in
                        XCTAssertEqual(response.status, .notFound)
                    }
                }

                let stillPending = try await ReminderStore.pending(forAccount: theirs.id, db: conn)
                XCTAssertEqual(stillPending.count, 1, "another account's reminder was dismissed")
            }
        }
    }

    /// The dismissed ones are hidden by default and shown on request.
    ///
    /// The list exists to answer "what is still waiting", and a finished
    /// thing has no business in it. But "done" and "mis-clicked" are
    /// indistinguishable after the fact, so the finished ones must still
    /// be findable.
    func test_theDismissedOnesAreHiddenUnlessAskedFor() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await MessageStore.upsert(header("m1", accountId: account.id), db: conn)
                let stored = try await ReminderStore.set(
                    accountId: account.id, remoteId: "m1",
                    dueAt: Date().addingTimeInterval(3600), note: nil, db: conn
                )
                let id = try XCTUnwrap(stored?.id)
                _ = try await ReminderStore.setDismissed(
                    reminderId: id, accountId: account.id, dismissed: true, db: conn
                )

                let app = Application(router: router(conn))
                try await app.test(.router) { client in
                    // The default: the waiting list, which is now empty.
                    try await client.execute(
                        uri: "/api/reminders?accountId=\(account.id.uuidString)",
                        method: .get
                    ) { response in
                        XCTAssertEqual(response.status, .ok)
                        let decoder = JSONDecoder()
                        decoder.dateDecodingStrategy = .iso8601
                        let body = try decoder.decode(
                            ReminderListResponse.self,
                            from: Data(buffer: response.body)
                        )
                        XCTAssertTrue(
                            body.reminders.isEmpty,
                            "a finished reminder is still in the waiting list"
                        )
                    }
                    // And the dismissed one is still there, findable.
                    try await client.execute(
                        uri: "/api/reminders?accountId=\(account.id.uuidString)&includeDismissed=true",
                        method: .get
                    ) { response in
                        XCTAssertEqual(response.status, .ok)
                        let decoder = JSONDecoder()
                        decoder.dateDecodingStrategy = .iso8601
                        let body = try decoder.decode(
                            ReminderListResponse.self,
                            from: Data(buffer: response.body)
                        )
                        XCTAssertEqual(
                            body.reminders.count, 1,
                            "the dismissed reminder cannot be found again — a mis-click would be permanent"
                        )
                        XCTAssertNotNil(body.reminders.first?.dismissedAt)
                    }
                }
            }
        }
    }

    /// The delete route removes one.
    func test_theDeleteRouteRemovesTheReminder() async throws {        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await MessageStore.upsert(header("m1", accountId: account.id), db: conn)
                let stored = try await ReminderStore.set(
                    accountId: account.id, remoteId: "m1",
                    dueAt: Date().addingTimeInterval(3600), note: nil, db: conn
                )
                let id = try XCTUnwrap(stored?.id)

                let app = Application(router: router(conn))
                try await app.test(.router) { client in
                    try await client.execute(
                        uri: "/api/reminders/\(id)?accountId=\(account.id.uuidString)",
                        method: .delete
                    ) { response in
                        XCTAssertEqual(response.status, .noContent)
                    }
                }

                let pending = try await ReminderStore.pending(forAccount: account.id, db: conn)
                XCTAssertTrue(pending.isEmpty, "the reminder was not deleted")
            }
        }
    }

    /// A reminder on a mail in the Trash stops being "waiting".
    ///
    /// Moving a mail to the Trash is a **soft** delete: the header row
    /// survives, so the foreign key does not fire, so the reminder row
    /// survives with it. That is deliberate — restoring the mail brings
    /// the reminder back, and the user does not lose a reminder by
    /// tidying up their inbox.
    ///
    /// But the reminder must not keep *firing* about mail the user
    /// discarded, so it leaves the waiting list.
    func test_aReminderOnATrashedMailStopsWaiting() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await MessageStore.upsert(header("m1", accountId: account.id), db: conn)
                try await ReminderStore.set(
                    accountId: account.id, remoteId: "m1",
                    dueAt: Date().addingTimeInterval(3600), note: nil, db: conn
                )

                try await MessageStore.setDeleted(
                    remoteId: "m1", accountId: account.id, deleted: true, db: conn
                )

                let pending = try await ReminderStore.pending(forAccount: account.id, db: conn)
                XCTAssertTrue(
                    pending.isEmpty,
                    "a reminder kept firing about a mail the user threw away"
                )
                // And it comes back with the mail.
                try await MessageStore.setDeleted(
                    remoteId: "m1", accountId: account.id, deleted: false, db: conn
                )
                let restored = try await ReminderStore.pending(forAccount: account.id, db: conn)
                XCTAssertEqual(
                    restored.count, 1,
                    "restoring the mail lost the reminder — the user set it for a reason"
                )
            }
        }
    }

    /// A permanently deleted mail takes the reminder with it.
    ///
    /// 彻底删除 is the one irreversible operation in the product, and it
    /// really removes the header row — so the foreign key fires and the
    /// reminder row goes with it. A reminder pointing at a message that no
    /// longer exists is a reminder the user can never act on.
    func test_puragingTheMessageTakesTheReminderWithIt() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await MessageStore.upsert(header("m1", accountId: account.id), db: conn)
                try await ReminderStore.set(
                    accountId: account.id, remoteId: "m1",
                    dueAt: Date().addingTimeInterval(3600), note: nil, db: conn
                )

                // The header row is really removed — this is what 彻底删除
                // does, and it is the only place the foreign key fires.
                try conn.write { db in
                    try MessageStore.hardDeleteSync(
                        remoteId: "m1", accountId: account.id, db: db
                    )
                }

                let pending = try await ReminderStore.pending(forAccount: account.id, db: conn)
                XCTAssertTrue(
                    pending.isEmpty,
                    "a reminder survived the mail it pointed at"
                )
            }
        }
    }

    /// A new reminder on a mail in the Trash is refused.
    ///
    /// The list hides reminders on trashed mail, so storing one would
    /// create a row the user can never see or clear.
    func test_aNewReminderOnATrashedMailIsRefused() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await MessageStore.upsert(header("m1", accountId: account.id), db: conn)
                try await MessageStore.setDeleted(
                    remoteId: "m1", accountId: account.id, deleted: true, db: conn
                )

                let stored = try await ReminderStore.set(
                    accountId: account.id, remoteId: "m1",
                    dueAt: Date().addingTimeInterval(3600), note: nil, db: conn
                )
                XCTAssertNil(
                    stored,
                    "a reminder was set on a mail in the Trash — the user could never see or clear it"
                )
            }
        }
    }
}
