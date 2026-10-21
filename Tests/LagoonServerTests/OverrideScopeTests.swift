import XCTest
import Foundation
import Logging
import Hummingbird
import HummingbirdTesting
import NIOCore
import GRDB
@testable import LagoonServer
@testable import LagoonKit

/// A value carried out of a Hummingbird test closure.
///
/// The closure runs in a concurrent context, so a plain captured `var`
/// would be a data race the compiler rightly warns about. The box is
/// `@unchecked Sendable` because the write happens inside the response
/// handler and the read happens after `app.test(.router)` returns — i.e.
/// strictly ordered, with no concurrent access.
private final class Captured<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}

/// P2-13: 「改分组」 must mean what it says.
///
/// ## The bug
///
/// The detail view offered "change group" on **one mail**. The server
/// stored the override keyed by that mail and the briefing resolved it **by
/// sender** — so every mail from that sender moved too, silently. The
/// interface never said so.
///
/// ## What these tests pin
///
/// * a message-scoped override moves **only** that mail;
/// * a sender-scoped override still moves the whole sender's mail (the
///   old behaviour, now reachable *on purpose* and announced);
/// * the narrow scope wins over the broad one for the mail it names;
/// * undo puts the mail back **at the scope it was applied** — undoing a
///   narrow override must not re-file the sender's mailbox;
/// * an unknown scope is treated as the **narrow** one;
/// * the schema migration gives every existing override the sender scope,
///   so an upgraded install behaves exactly as it did before.
final class OverrideScopeTests: XCTestCase {
    private let logger = Logger(label: "override-scope-tests")

    private func makeAccount() -> Account {
        Account(
            id: UUID(),
            provider: .qq,
            oauthUser: "ovr-\(UUID().uuidString)",
            email: "ovr-\(UUID().uuidString)@qq.com",
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

    private func header(
        _ remoteId: String,
        accountId: UUID,
        from: String,
        daysAgo: Double = 1
    ) -> MessageHeader {
        MessageHeader(
            id: UUID(),
            accountId: accountId,
            remoteId: remoteId,
            threadId: "t-\(remoteId)",
            fromAddress: from,
            fromName: nil,
            subject: "Subject \(remoteId)",
            snippet: nil,
            receivedAt: Date().addingTimeInterval(-daysAgo * 24 * 60 * 60),
            isRead: false,
            isArchived: false
        )
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func router(_ db: LagoonDB) -> Router<BasicRequestContext> {
        let router = Router()
        ActionsRoutes.register(on: router, db: db, logger: self.logger)
        BriefingRoutes.register(on: router, db: db, logger: self.logger)
        return router
    }

    /// POSTs a classify request and returns the HTTP status.
    @discardableResult
    private func classify(
        _ app: Application<RouterResponder<BasicRequestContext>>,
        remoteId: String,
        accountId: UUID,
        toGroup: String,
        scope: String?,
        fromGroup: String? = nil
    ) async throws -> Int {
        var payload: [String: Any] = ["toGroup": toGroup]
        if let scope { payload["scope"] = scope }
        if let fromGroup { payload["fromGroup"] = fromGroup }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let captured = Captured<Int>(0)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/messages/\(remoteId)/classify?accountId=\(accountId.uuidString)",
                method: .post,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(bytes: body)
            ) { response in
                captured.value = Int(response.status.code)
            }
        }
        return captured.value
    }

    /// The groups of several mails, read in one briefing request.
    ///
    /// One request rather than one per mail: the assertions below compare
    /// two or three mails against each other, and reading them from a
    /// single response is the only way those comparisons describe the same
    /// snapshot of the feed.
    private func groupsOf(
        _ app: Application<RouterResponder<BasicRequestContext>>,
        accountId: UUID,
        remoteIds: [String]
    ) async throws -> [String: BriefingGroup] {
        let captured = Captured<[String: BriefingGroup]>([:])
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/briefing?accountId=\(accountId.uuidString)",
                method: .get
            ) { response in
                XCTAssertEqual(response.status, .ok)
                let decoded = try Self.decoder().decode(
                    BriefingResponse.self, from: Data(buffer: response.body)
                )
                captured.value = Dictionary(
                    uniqueKeysWithValues: decoded.items.map { ($0.message.remoteId, $0.group) }
                )
            }
        }
        return captured.value
    }

    /// Undoes the newest `classifyOverride` action.
    private func undoLatestOverride(
        _ app: Application<RouterResponder<BasicRequestContext>>,
        accountId: UUID,
        db: LagoonDB
    ) async throws -> AIAction {
        let actions = try await AIActionStore.recent(accountId: accountId, db: db)
        let row = try XCTUnwrap(actions.first { $0.kind == .classifyOverride })
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/actions/\(row.id)/undo?accountId=\(accountId.uuidString)",
                method: .post
            ) { response in
                XCTAssertEqual(response.status, .ok)
            }
        }
        return row
    }

    // MARK: - The narrow scope moves one mail

    /// The core promise: 「只改这一封」 moves **one** mail.
    ///
    /// Two mails from the same sender, one message-scoped override — the
    /// other mail must not move. This is the exact surprise audit P2-13
    /// reported, and it is the assertion that fails if the scope is dropped
    /// anywhere between the route and the briefing.
    func test_messageScope_movesOnlyThatMail() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                let first = header("m-1", accountId: account.id, from: "alice@example.com")
                let second = header("m-2", accountId: account.id, from: "alice@example.com")
                try await MessageStore.upsert(first, db: conn)
                try await MessageStore.upsert(second, db: conn)

                let app = Application(router: router(conn))
                let status = try await classify(
                    app, remoteId: first.remoteId, accountId: account.id,
                    toGroup: "subscriptionNoise", scope: "message"
                )
                XCTAssertEqual(status, 200)

                let groups = try await groupsOf(
                    app, accountId: account.id,
                    remoteIds: [first.remoteId, second.remoteId]
                )
                XCTAssertEqual(
                    groups[first.remoteId], .subscriptionNoise,
                    "the mail the user acted on must move"
                )
                XCTAssertNotEqual(
                    groups[second.remoteId], .subscriptionNoise,
                    "a message-scoped override must not move the sender's other mail"
                )

                // The store must agree: the sender-level map is unchanged.
                let bySender = try await AIActionStore.overridesBySender(
                    accountId: account.id, db: conn
                )
                XCTAssertNil(
                    bySender["alice@example.com"],
                    "a message-scoped override must never appear in the sender-level map"
                )
                let byMessage = try await AIActionStore.overridesByMessage(
                    accountId: account.id, db: conn
                )
                XCTAssertEqual(byMessage[first.remoteId], .subscriptionNoise)
                XCTAssertNil(byMessage[second.remoteId])
            }
        }
    }

    // MARK: - The broad scope still moves the sender's mail

    /// The old behaviour, now reachable **on purpose**.
    ///
    /// The broad scope is not deprecated — it is the "every mail from this
    /// sender" promise, and the UI now says so before the user commits. So
    /// it must keep working exactly as it did.
    func test_senderScope_movesEveryMailFromThatSender() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                let first = header("s-1", accountId: account.id, from: "alice@example.com")
                let second = header("s-2", accountId: account.id, from: "alice@example.com")
                let other = header("s-3", accountId: account.id, from: "bob@example.com")
                try await MessageStore.upsert(first, db: conn)
                try await MessageStore.upsert(second, db: conn)
                try await MessageStore.upsert(other, db: conn)

                let app = Application(router: router(conn))
                let status = try await classify(
                    app, remoteId: first.remoteId, accountId: account.id,
                    toGroup: "subscriptionNoise", scope: "sender"
                )
                XCTAssertEqual(status, 200)

                let groups = try await groupsOf(
                    app, accountId: account.id,
                    remoteIds: [first.remoteId, second.remoteId, other.remoteId]
                )
                XCTAssertEqual(groups[first.remoteId], .subscriptionNoise)
                XCTAssertEqual(
                    groups[second.remoteId], .subscriptionNoise,
                    "a sender-scoped override must reach the sender's other mail"
                )
                XCTAssertNotEqual(
                    groups[other.remoteId], .subscriptionNoise,
                    "a sender-scoped override must not reach a different sender's mail"
                )
            }
        }
    }

    /// The narrow scope is the more specific statement, so it wins.
    ///
    /// Order matters: if the sender-level rule were checked first, the
    /// narrow option would be unreachable for any sender who already had a
    /// broad rule — the choice would be a lie.
    func test_messageScope_winsOverSenderScope_forThatMail() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                let first = header("w-1", accountId: account.id, from: "alice@example.com")
                let second = header("w-2", accountId: account.id, from: "alice@example.com")
                try await MessageStore.upsert(first, db: conn)
                try await MessageStore.upsert(second, db: conn)

                let app = Application(router: router(conn))
                _ = try await classify(
                    app, remoteId: first.remoteId, accountId: account.id,
                    toGroup: "subscriptionNoise", scope: "sender"
                )
                _ = try await classify(
                    app, remoteId: second.remoteId, accountId: account.id,
                    toGroup: "awaitingReply", scope: "message"
                )

                let groups = try await groupsOf(
                    app, accountId: account.id,
                    remoteIds: [first.remoteId, second.remoteId]
                )
                XCTAssertEqual(
                    groups[first.remoteId], .subscriptionNoise,
                    "the sender-level rule still applies to the mail it names"
                )
                XCTAssertEqual(
                    groups[second.remoteId], .awaitingReply,
                    "the message-scoped rule is the more specific statement and must win"
                )
            }
        }
    }

    // MARK: - Undo

    /// Undo puts the mail back **at the scope it was applied**.
    ///
    /// This is the assertion that catches the worst version of the bug: an
    /// undo that wrote a *sender*-scoped counter-override would re-file the
    /// whole mailbox, turning "undo my one-mail change" into "re-file every
    /// mail from this sender".
    func test_undoOfMessageScope_doesNotRefileTheSender() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                let first = header("u-1", accountId: account.id, from: "alice@example.com")
                let second = header("u-2", accountId: account.id, from: "alice@example.com")
                try await MessageStore.upsert(first, db: conn)
                try await MessageStore.upsert(second, db: conn)

                let app = Application(router: router(conn))
                _ = try await classify(
                    app, remoteId: first.remoteId, accountId: account.id,
                    toGroup: "subscriptionNoise", scope: "message"
                )
                let before = try await groupsOf(
                    app, accountId: account.id,
                    remoteIds: [first.remoteId, second.remoteId]
                )
                XCTAssertEqual(before[first.remoteId], .subscriptionNoise)

                // Undo it.
                let row = try await undoLatestOverride(app, accountId: account.id, db: conn)
                XCTAssertEqual(
                    row.payload["scope"], "message",
                    "the audit row must record the scope, or the undo cannot restore it"
                )

                let after = try await groupsOf(
                    app, accountId: account.id,
                    remoteIds: [first.remoteId, second.remoteId]
                )
                XCTAssertNotEqual(
                    after[first.remoteId], .subscriptionNoise,
                    "undo must take the mail back out of the group"
                )
                XCTAssertNotEqual(
                    after[second.remoteId], .subscriptionNoise,
                    "undoing a one-mail change must not re-file the sender's other mail"
                )

                // And the sender-level map must be untouched by the whole
                // narrow-scope cycle.
                let bySender = try await AIActionStore.overridesBySender(
                    accountId: account.id, db: conn
                )
                XCTAssertNil(
                    bySender["alice@example.com"],
                    "the narrow cycle must never write a sender-level rule"
                )
            }
        }
    }

    /// Undo of a **sender**-scoped override keeps the old behaviour: the
    /// sender flips back.
    func test_undoOfSenderScope_flipsTheSenderBack() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                let first = header("us-1", accountId: account.id, from: "alice@example.com")
                let second = header("us-2", accountId: account.id, from: "alice@example.com")
                try await MessageStore.upsert(first, db: conn)
                try await MessageStore.upsert(second, db: conn)

                let app = Application(router: router(conn))
                _ = try await classify(
                    app, remoteId: first.remoteId, accountId: account.id,
                    toGroup: "subscriptionNoise", scope: "sender"
                )
                _ = try await undoLatestOverride(app, accountId: account.id, db: conn)

                let bySender = try await AIActionStore.overridesBySender(
                    accountId: account.id, db: conn
                )
                XCTAssertNotEqual(
                    bySender["alice@example.com"], .subscriptionNoise,
                    "undo must flip the sender back to its previous group"
                )
                let groups = try await groupsOf(
                    app, accountId: account.id,
                    remoteIds: [first.remoteId, second.remoteId]
                )
                XCTAssertNotEqual(groups[second.remoteId], .subscriptionNoise)
            }
        }
    }

    // MARK: - The unknown scope is the narrow one

    /// A scope the server does not understand must never become the broad
    /// one.
    ///
    /// The whole point of the scope is that "this one mail" and "every mail
    /// from this sender" are different promises. A request naming a scope
    /// from a newer client must not be read as the broad promise.
    func test_unknownScope_isTreatedAsTheNarrowOne() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                let first = header("x-1", accountId: account.id, from: "alice@example.com")
                let second = header("x-2", accountId: account.id, from: "alice@example.com")
                try await MessageStore.upsert(first, db: conn)
                try await MessageStore.upsert(second, db: conn)

                let app = Application(router: router(conn))
                let status = try await classify(
                    app, remoteId: first.remoteId, accountId: account.id,
                    toGroup: "subscriptionNoise", scope: "some-future-scope"
                )
                XCTAssertEqual(status, 200)
                let groups = try await groupsOf(
                    app, accountId: account.id,
                    remoteIds: [first.remoteId, second.remoteId]
                )
                XCTAssertEqual(groups[first.remoteId], .subscriptionNoise)
                XCTAssertNotEqual(
                    groups[second.remoteId], .subscriptionNoise,
                    "an unknown scope must not be read as the broad one"
                )
            }
        }
    }

    // MARK: - The migration

    /// An install that already had overrides keeps them as sender-scoped.
    ///
    /// The migration's default is `sender` precisely so an upgrade does not
    /// silently re-file a mailbox: the rows that exist today all meant
    /// "this sender", and they must keep meaning it.
    func test_migration_givesExistingOverridesTheSenderScope() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("lagoon-ovr-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        // Stand up the pre-migration shape: the `ai_overrides` table as it
        // was, with no `scope` column, and one row in it.
        let legacy = try DatabasePool(path: path)
        var legacyMigrator = DatabaseMigrator()
        legacyMigrator.registerMigration("lagoon-v1") { db in
            try db.execute(sql: LagoonDatabase.schema)
            try db.execute(sql: """
                DROP TABLE ai_overrides;
                CREATE TABLE ai_overrides (
                    id         INTEGER PRIMARY KEY AUTOINCREMENT,
                    account_id BLOB NOT NULL,
                    remote_id  TEXT NOT NULL,
                    from_group TEXT NOT NULL,
                    to_group   TEXT NOT NULL,
                    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%f','now'))
                );
                """)
        }
        try legacyMigrator.migrate(legacy)
        let accountId = UUID()
        try legacy.write { db in
            try db.execute(
                sql: """
                    INSERT INTO ai_overrides (account_id, remote_id, from_group, to_group)
                    VALUES (?, 'legacy-1', 'needsReply', 'subscriptionNoise')
                    """,
                arguments: [accountId]
            )
        }
        try legacy.close()

        let after = try LagoonDatabase.open(path: path)
        defer { try? after.close() }
        let scope = try after.read { db in
            try String.fetchOne(
                db, sql: "SELECT scope FROM ai_overrides WHERE remote_id = ?",
                arguments: ["legacy-1"]
            )
        }
        XCTAssertEqual(
            scope, "sender",
            "an existing override must keep the meaning it had before the migration"
        )
    }

    /// A fresh install gets the column too — the migration runs on both
    /// paths, and a fresh install that skipped it would fail every override
    /// write with "no such column: scope".
    func test_freshInstall_hasTheScopeColumn() throws {
        let pool = try LagoonDatabase.open(
            path: FileManager.default.temporaryDirectory
                .appendingPathComponent("lagoon-ovr-fresh-\(UUID().uuidString).sqlite").path
        )
        defer { try? pool.close() }
        let columns = try pool.read { db in
            try String.fetchAll(
                db, sql: "SELECT name FROM pragma_table_info('ai_overrides')"
            )
        }
        XCTAssertTrue(
            columns.contains("scope"),
            "a fresh install must have the scope column, or every override write fails"
        )
    }
}
