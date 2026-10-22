import XCTest
import Foundation
import Logging
import Hummingbird
import HummingbirdTesting
import NIOCore
import GRDB
@testable import LagoonServer
@testable import LagoonKit

/// A sender-level rule must outlive the mail it was written on.
///
/// ## The bug
///
/// An override row was keyed by the mail the user acted on, and the sender
/// it applied to was recovered by joining `message_headers`. That join is an
/// inner join, so the rule stopped existing the moment its sample mail was
/// deleted — silently, with nothing said anywhere. The user had taught the
/// app 「这个发件人的邮件归到 X 组」, and one deleted mail took the lesson
/// with it: the row was still in the table, it simply stopped applying to
/// anything.
///
/// ## What these tests pin
///
/// * the rule still applies after the sample mail is gone;
/// * the undo still flips the sender back, even after the sample is gone;
/// * a message-scoped rule still never reaches the sender-level map;
/// * the sender-level lookup is an index seek, not a table scan.
final class OverrideSenderRuleTests: XCTestCase {
    private let logger = Logger(label: "override-sender-tests")

    // MARK: - The rule outlives its sample

    /// The promise the product makes: 「这个发件人的邮件归到 X 组」 keeps
    /// meaning that after the mail the user acted on is gone.
    func test_senderRule_survivesTheSampleMailBeingDeleted() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                let sample = header("m-1", accountId: account.id, from: "alice@example.com")
                try await MessageStore.upsert(sample, db: conn)

                let app = Application(router: router(conn))
                let status = try await classify(
                    app, remoteId: sample.remoteId, accountId: account.id,
                    toGroup: "subscriptionNoise", scope: "sender"
                )
                XCTAssertEqual(status, 200)

                // The sample is confirmed gone by the server. This is the
                // path that used to take the rule with it.
                try await MessageStore.reconcileInbox(
                    accountId: account.id,
                    keeping: [],
                    removing: [sample.remoteId],
                    db: conn
                )

                let bySender = try await AIActionStore.overridesBySender(
                    accountId: account.id, db: conn
                )
                XCTAssertEqual(
                    bySender["alice@example.com"], .subscriptionNoise,
                    "the rule is about the sender, so it must not die with the sample mail"
                )

                // And the end of the promise: the sender's *next* mail is
                // still filed by the rule.
                let next = header("m-2", accountId: account.id, from: "alice@example.com")
                try await MessageStore.upsert(next, db: conn)
                let groups = try await groupsOf(
                    app, accountId: account.id, remoteIds: [next.remoteId]
                )
                XCTAssertEqual(
                    groups[next.remoteId], .subscriptionNoise,
                    "the rule must still file the sender's new mail"
                )
            }
        }
    }

    /// The undo has to name the sender too — a counter-row nobody can
    /// attribute flips nothing, and the sender stays re-filed.
    func test_undo_flipsTheSenderBack_afterTheSampleIsGone() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                let sample = header("m-1", accountId: account.id, from: "alice@example.com")
                try await MessageStore.upsert(sample, db: conn)

                let app = Application(router: router(conn))
                _ = try await classify(
                    app, remoteId: sample.remoteId, accountId: account.id,
                    toGroup: "subscriptionNoise", scope: "sender"
                )

                // The sample goes away before the undo.
                try await MessageStore.reconcileInbox(
                    accountId: account.id,
                    keeping: [],
                    removing: [sample.remoteId],
                    db: conn
                )

                _ = try await undoLatestOverride(app, accountId: account.id, db: conn)

                let bySender = try await AIActionStore.overridesBySender(
                    accountId: account.id, db: conn
                )
                XCTAssertNotEqual(
                    bySender["alice@example.com"], .subscriptionNoise,
                    "the undo must flip the sender back even when the sample is gone"
                )
            }
        }
    }

    /// The narrow rule still belongs to one mail, and it still never reaches
    /// the sender-level map.
    func test_messageScope_neverReachesTheSenderMap() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                let first = header("n-1", accountId: account.id, from: "alice@example.com")
                let second = header("n-2", accountId: account.id, from: "alice@example.com")
                try await MessageStore.upsert(first, db: conn)
                try await MessageStore.upsert(second, db: conn)

                let app = Application(router: router(conn))
                _ = try await classify(
                    app, remoteId: first.remoteId, accountId: account.id,
                    toGroup: "subscriptionNoise", scope: "message"
                )

                let bySender = try await AIActionStore.overridesBySender(
                    accountId: account.id, db: conn
                )
                XCTAssertNil(
                    bySender["alice@example.com"],
                    "a message-scoped rule must never appear in the sender-level map"
                )
                let byMessage = try await AIActionStore.overridesByMessage(
                    accountId: account.id, db: conn
                )
                XCTAssertEqual(byMessage[first.remoteId], .subscriptionNoise)
                XCTAssertNil(byMessage[second.remoteId])
            }
        }
    }

    // MARK: - The lookup is an index seek

    /// The two override lookups run on the briefing's hot path, every 30
    /// seconds, and the table has no index on `(account_id, scope)` — so
    /// both of them scanned the whole table and sorted what they found.
    func test_senderLookup_usesTheAccountScopeIndex() async throws {
        try await TestDatabase.withConnection { conn in
            let plan = try await conn.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                        EXPLAIN QUERY PLAN
                        WITH ranked AS (
                            SELECT o.to_group, o.from_address, o.created_at,
                                row_number() OVER (PARTITION BY o.from_address ORDER BY o.created_at DESC, o.rowid DESC) AS rn
                            FROM ai_overrides o
                            WHERE o.account_id = ? AND o.scope = 'sender' AND o.from_address IS NOT NULL
                        )
                        SELECT from_address, to_group FROM ranked WHERE rn = 1
                        """,
                    arguments: [UUID()]
                ).compactMap { $0["detail"] as String? }
            }
            let text = plan.joined(separator: " | ")
            XCTAssertTrue(
                text.contains("ai_overrides_account_scope_idx"),
                "the override lookup must be an index seek, not a table scan — got: \(text)"
            )
            XCTAssertFalse(
                text.contains("SCAN o"),
                "the override lookup must not scan the table — got: \(text)"
            )
        }
    }

    // MARK: - The migration

    /// An install that already had rules keeps them working.
    ///
    /// The migration recovers the sender from the sample mail the rule was
    /// written from. A rule whose sample is already gone cannot be
    /// recovered — the address was never stored anywhere else — but a rule
    /// whose sample is still there must come through the upgrade intact.
    func test_migration_recoversTheSenderOfExistingRules() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("lagoon-ovr-sender-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        // Stand up the pre-migration shape: the `ai_overrides` table as it
        // was, with no `from_address` column, and one rule in it.
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
                    INSERT INTO accounts (id, provider, oauth_user, email, credentials, sync_state,
                                          capabilities, is_active, sync_status, created_at, updated_at)
                    VALUES (?, 'qq', 'legacy@example.com', 'legacy@example.com', X'00', '{}', '{}', 1, 'ok',
                            strftime('%Y-%m-%d %H:%M:%f','now'), strftime('%Y-%m-%d %H:%M:%f','now'))
                    """,
                arguments: [accountId]
            )
            try db.execute(
                sql: """
                    INSERT INTO message_headers (id, account_id, remote_id, thread_id, from_address,
                                                from_name, subject, snippet, received_at, is_read,
                                                is_archived, is_deleted, fetched_at)
                    VALUES (?, ?, 'legacy-1', 't-legacy-1', 'boss@example.com', '', 'Subject', '',
                            strftime('%Y-%m-%d %H:%M:%f','now'), 0, 0, 0,
                            strftime('%Y-%m-%d %H:%M:%f','now'))
                    """,
                arguments: [UUID(), accountId]
            )
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
        let address = try after.read { db in
            try String.fetchOne(
                db, sql: "SELECT from_address FROM ai_overrides WHERE remote_id = ?",
                arguments: ["legacy-1"]
            )
        }
        XCTAssertEqual(
            address, "boss@example.com",
            "an existing rule must find its sender again on upgrade"
        )
    }

    /// A fresh install gets the column too — the migration runs on both
    /// paths, and a fresh install that skipped it would fail every
    /// override write with "no such column: from_address".
    func test_freshInstall_hasTheSenderColumn() throws {
        let pool = try LagoonDatabase.open(
            path: FileManager.default.temporaryDirectory
                .appendingPathComponent("lagoon-ovr-sender-fresh-\(UUID().uuidString).sqlite").path
        )
        defer { try? pool.close() }
        let columns = try pool.read { db in
            try String.fetchAll(
                db, sql: "SELECT name FROM pragma_table_info('ai_overrides')"
            )
        }
        XCTAssertTrue(
            columns.contains("from_address"),
            "a fresh install must have the from_address column, or every override write fails"
        )
    }

    // MARK: - Harness

    private func makeAccount() -> Account {
        Account(
            id: UUID(),
            provider: .qq,
            oauthUser: "ovr-sender-\(UUID().uuidString)",
            email: "ovr-sender-\(UUID().uuidString)@qq.com",
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
        from: String
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
            receivedAt: Date(),
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

    @discardableResult
    private func classify(
        _ app: Application<RouterResponder<BasicRequestContext>>,
        remoteId: String,
        accountId: UUID,
        toGroup: String,
        scope: String?
    ) async throws -> Int {
        var payload: [String: Any] = ["toGroup": toGroup]
        if let scope { payload["scope"] = scope }
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

    private func undoLatestOverride(
        _ app: Application<RouterResponder<BasicRequestContext>>,
        accountId: UUID,
        db: LagoonDB
    ) async throws {
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
    }

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
}

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
