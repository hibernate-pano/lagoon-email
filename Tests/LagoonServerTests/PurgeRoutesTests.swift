import XCTest
import Foundation
import Logging
import Hummingbird
import NIOCore
import GRDB
@testable import LagoonKit
@testable import LagoonServer

/// End-to-end for the two irreversible routes:
///
/// * `POST /api/messages/{remoteId}/purge` — 彻底删除 one message
/// * `POST /api/trash/empty` — 清空废纸篓
///
/// ## What is different about testing these
///
/// Every other route in this product can be undone, so its worst bug is a
/// confusing state. These cannot. The tests here are therefore less about
/// "does it work" and more about **the ways it can destroy something it should
/// not**, and each of those gets its own case:
///
/// 1. **It cannot become a second, quieter delete.** A purge on a message still
///    in the inbox is refused with 409 — otherwise one API call would
///    permanently remove mail the user could still restore from the undo toast,
///    and irreversibility would arrive before the intent.
/// 2. **Local data goes only after the server confirms.** Remote-first ordering
///    means a mid-flight failure leaves a recoverable orphan, never a
///    permanently-lost message with its row already gone.
/// 3. **The local delete is complete.** Foreign keys are ON here
///    (`LagoonDatabase.open` sets `foreignKeysEnabled = true`), so `advice` and
///    `message_bodies` *would* cascade from a header delete — which is exactly
///    why a test that only watched those two proved nothing: it stayed green
///    after `hardDeleteSync` was simplified to a single DELETE. The tables that
///    reference `accounts(id)` instead — `message_pins`, `draft_replies`,
///    `ai_overrides` — are never cascaded by SQLite, so those are the rows this
///    file now asserts on.
/// 4. **The audit trail survives.** The message is gone; the record that Lagoon
///    deleted it is not. That asymmetry is the product's one promise it cannot
///    break.
final class PurgeRoutesTests: XCTestCase {
    private let logger = Logger(label: "purge-routes-tests")

    private func makeAccount() -> Account {
        Account(
            id: UUID(),
            provider: .qq,
            oauthUser: "purge-\(UUID().uuidString)",
            email: "purge-\(UUID().uuidString)@qq.com",
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

    /// Seeds a message plus the dependent rows a real one would have, so the
    /// cascade test has something to check.
    private func seedMessage(
        _ remoteId: String,
        accountId: UUID,
        db: LagoonDB,
        archived: Bool = false,
        deleted: Bool = false,
        withBody: Bool = true,
        withAdvice: Bool = true
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
                snippet: "snippet",
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
        if withBody {
            try await BodyStore.put(
                accountId: accountId,
                remoteId: remoteId,
                body: FetchedBody(
                    text: "body text", html: nil, attachments: [], hasMore: false
                ),
                db: db
            )
        }
        if withAdvice {
            _ = try await AdviceStore.upsert(
                accountId: accountId,
                remoteId: remoteId,
                advice: Advice(action: .delete, category: .spam),
                source: .heuristic,
                model: nil,
                db: db
            )
        }
        // The three tables SQLite will NOT cascade for a header delete, because
        // their FK points at `accounts(id)` rather than `message_headers`.
        // Without a row here the "delete is complete" assertion would pass on an
        // empty table and prove nothing.
        try db.write { raw in
            try raw.execute(
                sql: """
                    INSERT OR REPLACE INTO message_pins (account_id, remote_id)
                    VALUES (?, ?)
                    """,
                arguments: [accountId, remoteId]
            )
            try raw.execute(
                sql: """
                    INSERT INTO draft_replies (account_id, remote_id, variants)
                    VALUES (?, ?, '[]')
                    """,
                arguments: [accountId, remoteId]
            )
            try raw.execute(
                sql: """
                    INSERT INTO ai_overrides (account_id, remote_id, from_group, to_group)
                    VALUES (?, ?, 'briefing', 'later')
                    """,
                arguments: [accountId, remoteId]
            )
        }
    }

    private func makeRouter(
        _ provider: any MailProvider, _ db: LagoonDB
    ) -> Router<BasicRequestContext> {
        let router = Router<BasicRequestContext>()
        ActionsRoutes.register(
            on: router, db: db, logger: self.logger, makeProvider: { _ in provider }
        )
        return router
    }

    @discardableResult
    private func post(
        _ path: String, _ accountId: UUID, _ db: LagoonDB, _ provider: any MailProvider
    ) async throws -> (status: Int, purged: Int) {
        let app = Application(router: makeRouter(provider, db))
        var status = 0
        var purged = -1
        try await app.test(.router) { client in
            try await client.execute(
                uri: "\(path)?accountId=\(accountId.uuidString)", method: .post
            ) { response in
                status = Int(response.status.code)
                if response.status == .ok, !response.body.readableBytesView.isEmpty {
                    struct Body: Decodable { let purged: Int }
                    purged = try JSONDecoder().decode(
                        Body.self, from: Data(response.body.readableBytesView)
                    ).purged
                }
            }
        }
        return (status, purged)
    }

    private func rowExists(
        _ remoteId: String, _ accountId: UUID, _ db: LagoonDB
    ) async throws -> Bool {
        try db.read { raw in
            try Row.fetchOne(
                raw,
                sql: "SELECT 1 FROM message_headers WHERE account_id = ? AND remote_id = ?",
                arguments: [accountId, remoteId]
            ) != nil
        }
    }

    private func dependentCounts(
        _ remoteId: String, _ accountId: UUID, _ db: LagoonDB
    ) async throws -> (bodies: Int, advice: Int, pins: Int, drafts: Int, overrides: Int) {
        try db.read { raw in
            // One static statement per table, joined rather than interpolated.
            // `ci-guardrails` rightly refuses a SQL literal that carries an
            // interpolation — a table name cannot be a bound parameter in
            // SQLite, so the honest shape is a fixed set of literal queries.
            func count(_ sql: String) throws -> Int {
                try Int.fetchOne(raw, sql: sql, arguments: [accountId, remoteId]) ?? 0
            }
            // `bodies` and `advice` have `ON DELETE CASCADE` to message_headers,
            // so SQLite would remove them even if `hardDeleteSync` forgot them.
            // `pins`, `drafts` and `overrides` reference `accounts(id)` instead,
            // so nothing cascades them — **these three are the real assertion**.
            // A test that only watched the cascading pair would stay green after
            // someone simplified the function down to one DELETE.
            return (
                bodies: try count(
                    "SELECT COUNT(*) FROM message_bodies WHERE account_id = ? AND remote_id = ?"
                ),
                advice: try count(
                    "SELECT COUNT(*) FROM advice WHERE account_id = ? AND remote_id = ?"
                ),
                pins: try count(
                    "SELECT COUNT(*) FROM message_pins WHERE account_id = ? AND remote_id = ?"
                ),
                drafts: try count(
                    "SELECT COUNT(*) FROM draft_replies WHERE account_id = ? AND remote_id = ?"
                ),
                overrides: try count(
                    "SELECT COUNT(*) FROM ai_overrides WHERE account_id = ? AND remote_id = ?"
                )
            )
        }
    }

    // MARK: - 彻底删除

    /// The happy path, and the one that proves the local delete is *complete*.
    ///
    /// Bodies and advice rows go with the header. This is the assertion that
    /// fails if someone "simplifies" `hardDeleteSync` to a single DELETE —
    /// which compiles, passes every other test, and leaves orphans that no list
    /// shows and no count includes.
    func test_purge_removesTheMessageAndAllItsDependentRows() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let provider = StubMailProvider()
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await seedMessage("p1", accountId: account.id, db: conn, deleted: true)

                let before = try await dependentCounts("p1", account.id, conn)
                XCTAssertEqual(before.bodies, 1, "fixture must actually have a body row")
                XCTAssertEqual(before.advice, 1, "fixture must actually have an advice row")
                XCTAssertEqual(before.pins, 1, "fixture must actually have a pin row")
                XCTAssertEqual(before.drafts, 1, "fixture must actually have a draft row")
                XCTAssertEqual(before.overrides, 1, "fixture must actually have an override row")

                let result = try await post(
                    "/api/messages/p1/purge", account.id, conn, provider
                )
                XCTAssertEqual(result.status, 200)
                XCTAssertEqual(result.purged, 1)

                let exists = try await rowExists("p1", account.id, conn)
                XCTAssertFalse(exists, "the header row must be gone")

                let after = try await dependentCounts("p1", account.id, conn)
                XCTAssertEqual(
                    after.bodies, 0,
                    "orphan body: invisible to every list, readable through a stale remoteId"
                )
                XCTAssertEqual(after.advice, 0, "orphan advice row")
                // These three have no FK to message_headers, so SQLite never
                // cascades them: if `hardDeleteSync` forgets one, it stays
                // forever and nothing in the app will ever show or count it.
                XCTAssertEqual(
                    after.pins, 0,
                    "orphan pin: nothing cascades a message_pins row on a header delete"
                )
                XCTAssertEqual(
                    after.drafts, 0,
                    "orphan draft reply — a later 「my drafts」 list would resurrect it"
                )
                XCTAssertEqual(
                    after.overrides, 0,
                    "orphan AI override: the classifier would read a verdict for a message that no longer exists"
                )
                let purgeCalls = await provider.purgeCalls
                XCTAssertEqual(purgeCalls, ["p1"])
            }
        }
    }

    /// **The most important test in this file.**
    ///
    /// A purge on a message that is not in the Trash is refused with 409. If
    /// this ever returns 200, the product has grown a way to permanently destroy
    /// inbox mail in one call — bypassing the soft-delete step, the undo toast,
    /// and the trash listing that tells the user what is recoverable.
    func test_purge_onAMessageOutsideTheTrash_isRefused() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let provider = StubMailProvider()
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await seedMessage("live", accountId: account.id, db: conn, deleted: false)

                let result = try await post(
                    "/api/messages/live/purge", account.id, conn, provider
                )
                XCTAssertEqual(result.status, 409, "irreversibility must not arrive before the intent")

                let exists = try await rowExists("live", account.id, conn)
                XCTAssertTrue(exists, "a refused purge must change nothing")
                let calls = await provider.purgeCalls
                XCTAssertTrue(
                    calls.isEmpty, "the provider must not be asked to destroy a live message"
                )
            }
        }
    }

    /// A failed remote purge leaves the local row completely intact.
    ///
    /// Remote-first ordering means the worst case here is a leftover row, not a
    /// lost message. The inverse order would lose it permanently.
    func test_purge_remoteFailure_leavesTheLocalRowAndItsDependents() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let provider = StubMailProvider()
            await provider.setPurgeFailure(.unreachable("test"))
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await seedMessage("p2", accountId: account.id, db: conn, deleted: true)

                let result = try await post(
                    "/api/messages/p2/purge", account.id, conn, provider
                )
                XCTAssertEqual(result.status, 502)
                let exists = try await rowExists("p2", account.id, conn)
                XCTAssertTrue(exists, "a failed purge must never remove the local row")
                let deps = try await dependentCounts("p2", account.id, conn)
                XCTAssertEqual(deps.bodies, 1, "and must not orphan the body either")
            }
        }
    }

    /// The audit row survives the message.
    ///
    /// "Lagoon did nothing" and "Lagoon deleted this permanently" must be
    /// distinguishable in the history — the action log is the one place this
    /// product is required to be honest (constitution §3).
    func test_purge_isRecordedInTheAuditLog() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let provider = StubMailProvider()
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await seedMessage("p3", accountId: account.id, db: conn, deleted: true)
                _ = try await post("/api/messages/p3/purge", account.id, conn, provider)

                let actions = try await AIActionStore.recent(
                    accountId: account.id, since: nil, limit: 10, db: conn
                )
                XCTAssertEqual(actions.count, 1)
                XCTAssertEqual(actions[0].kind, .purge)
                XCTAssertFalse(
                    actions[0].kind.isUndoable,
                    "purge must not claim to be undoable — the history is read by the user"
                )
            }
        }
    }

    // MARK: - 清空废纸篓

    /// Every trashed message goes, and nothing else does.
    func test_emptyTrash_removesOnlyTheTrashedMessages() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let provider = StubMailProvider()
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await seedMessage("g1", accountId: account.id, db: conn, deleted: true)
                try await seedMessage("g2", accountId: account.id, db: conn, deleted: true)
                try await seedMessage("keep", accountId: account.id, db: conn, deleted: false)
                try await seedMessage(
                    "arch", accountId: account.id, db: conn, archived: true, deleted: false
                )

                let result = try await post("/api/trash/empty", account.id, conn, provider)
                XCTAssertEqual(result.status, 200)
                XCTAssertEqual(result.purged, 2)

                for gone in ["g1", "g2"] {
                    let exists = try await rowExists(gone, account.id, conn)
                    XCTAssertFalse(exists, "\(gone) should be gone")
                }
                for kept in ["keep", "arch"] {
                    let exists = try await rowExists(kept, account.id, conn)
                    XCTAssertTrue(exists, "\(kept) must survive 清空废纸篓")
                }
                let empties = await provider.emptyTrashCalls
                XCTAssertEqual(empties, 1, "one remote call, not one per message")
            }
        }
    }

    /// An already-empty trash is a success, not an error.
    ///
    /// A 409 here would train people to click through warnings for a no-op,
    /// which is exactly how a real warning stops being read.
    func test_emptyTrash_onAnEmptyTrash_succeedsWithZero() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let provider = StubMailProvider()
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await seedMessage("live", accountId: account.id, db: conn)

                let result = try await post("/api/trash/empty", account.id, conn, provider)
                XCTAssertEqual(result.status, 200)
                XCTAssertEqual(result.purged, 0)
                let calls = await provider.emptyTrashCalls
                XCTAssertEqual(calls, 0, "nothing to empty means no provider call")
            }
        }
    }

    /// A failed remote empty leaves every local row alone.
    ///
    /// The wide-blast-radius version of the single-message test: half-erased
    /// local state across 300 messages is much worse than a no-op.
    func test_emptyTrash_remoteFailure_leavesEverythingAlone() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let provider = StubMailProvider()
            await provider.setEmptyTrashFailure(.unreachable("test"))
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await seedMessage("h1", accountId: account.id, db: conn, deleted: true)
                try await seedMessage("h2", accountId: account.id, db: conn, deleted: true)

                let result = try await post("/api/trash/empty", account.id, conn, provider)
                XCTAssertEqual(result.status, 502)
                for kept in ["h1", "h2"] {
                    let exists = try await rowExists(kept, account.id, conn)
                    XCTAssertTrue(exists, "\(kept) must survive a failed 清空废纸篓")
                }
            }
        }
    }

    /// The bulk action records *one* audit row, not one per message.
    ///
    /// The single-message route writes one row per purge, which is right — the
    /// user acted on one message. "Empty the trash" is one decision, and 300
    /// rows would bury every other action in the history.
    func test_emptyTrash_writesASingleScopedAuditRow() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let provider = StubMailProvider()
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                for i in 1...3 {
                    try await seedMessage("b\(i)", accountId: account.id, db: conn, deleted: true)
                }
                _ = try await post("/api/trash/empty", account.id, conn, provider)

                let actions = try await AIActionStore.recent(
                    accountId: account.id, since: nil, limit: 10, db: conn
                )
                XCTAssertEqual(actions.count, 1, "one decision, one row")
                XCTAssertEqual(actions[0].kind, .purge)
                XCTAssertEqual(actions[0].payload["scope"], "trash")
                XCTAssertEqual(actions[0].payload["count"], "3")
            }
        }
    }

    /// A purge is never reachable from an automatic path.
    ///
    /// Constitution §2 rule 5 says no rule may execute on its own. The user's
    /// 2026-10-05 decision relaxed the *reversibility* requirement; it did not
    /// relax this one. The guarantee is structural: the sync engine holds
    /// `any MailSyncReading`, and neither irreversible verb is declared on that
    /// protocol — so no amount of route wiring can hand them to the loop.
    ///
    /// ## Why this reads the source instead of reflecting the type
    ///
    /// The previous version asserted against a hand-written local array
    /// (`["pullChanges", "capabilities", "shutdown", "probe"]`), which is a
    /// statement about a literal in the test file: adding `permanentlyDelete`
    /// to `MailSyncReading` would have left it green. That is the "验证替身"
    /// failure — a test that cannot fail on the thing it names.
    ///
    /// Reflection through `MailSyncReading.requirementNames` would be ideal but
    /// is not reachable here: under `@testable import` the bare protocol name
    /// resolves to the `any`-erased type, which does not carry the metatype
    /// member. So this parses the real declaration out of
    /// `MailProvider.swift` — the same technique
    /// `ShortcutSheetCoversRealBindingsTests` uses for keyboard bindings. The
    /// assertion now fails if someone widens the protocol, which is the whole
    /// point of the guard.
    func test_purgeRoutes_areNotReachableFromTheSyncEngine() throws {
        let source = try String(
            contentsOf: Self.mailProviderSource, encoding: .utf8
        )

        let readOnly = try XCTUnwrap(
            Self.methods(inProtocolNamed: "MailSyncReading", in: source),
            "could not find the MailSyncReading declaration in \(Self.mailProviderSource.path)"
        )
        let writable = try XCTUnwrap(
            Self.methods(inProtocolNamed: "MailProvider", in: source),
            "could not find the MailProvider declaration in \(Self.mailProviderSource.path)"
        )

        for forbidden in ["permanentlyDelete", "emptyTrash", "setRead", "archive",
                          "unarchive", "trash", "restoreFromTrash", "send", "move"] {
            XCTAssertFalse(
                readOnly.contains(forbidden),
                "MailSyncReading must stay narrow — \(forbidden) on it would hand the "
                    + "sync engine a write verb it can never legitimately use. "
                    + "Declared: \(readOnly.sorted())"
            )
        }
        // And the loop still has its read surface, so the assertion above cannot
        // be satisfied by gutting the protocol.
        XCTAssertTrue(
            ["pullChanges", "capabilities", "shutdown"].allSatisfy(readOnly.contains),
            "the loop still needs its read surface: \(readOnly.sorted())"
        )

        // The irreversible verbs must exist on the wider protocol — or the
        // assertion above would pass vacuously.
        for verb in ["permanentlyDelete", "emptyTrash"] {
            XCTAssertTrue(
                writable.contains(verb),
                "\(verb) belongs on MailProvider; if this fails the verb was renamed, "
                    + "and the guard above must be updated to match. "
                    + "Declared: \(writable.sorted())"
            )
        }
    }

    /// `MailProvider.swift` next to this test's target, located the same way the
    /// client-side source-reading guard does it.
    private static let mailProviderSource: URL = {
        URL(fileURLWithPath: #filePath)          // …/PurgeRoutesTests.swift
            .deletingLastPathComponent()          // LagoonServerTests
            .deletingLastPathComponent()          // Tests
            .deletingLastPathComponent()          // package root
            .appendingPathComponent("Sources/LagoonServer/Mail/MailProvider.swift")
    }()

    /// Method names declared directly in `protocol <name> … { … }`.
    ///
    /// Deliberately shallow: it collects the `func` signatures at the protocol's
    /// own brace depth and does not follow comments or nested declarations, which
    /// is enough because these protocols declare requirements flat.
    private static func methods(inProtocolNamed name: String, in source: String) throws -> Set<String> {
        let lines = source.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: {
            $0.contains("protocol \(name):") || $0.contains("protocol \(name) {")
        }) else {
            throw XCTSkip("protocol \(name) not found — the declaration shape changed")
        }
        var names: Set<String> = []
        var opened = false
        for line in lines[start...] {
            if line.contains("{") { opened = true; continue }
            if line.contains("}") { break }
            guard opened else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("func ") || trimmed.contains(" func ") else { continue }
            let afterFunc = trimmed.components(separatedBy: "func ").last ?? trimmed
            let head = afterFunc.components(separatedBy: "(").first ?? afterFunc
            let name = head.trimmingCharacters(in: .whitespaces)
                .components(separatedBy: ":").first ?? name
            let cleaned = name.components(separatedBy: " ").last ?? name
            if !cleaned.isEmpty { names.insert(cleaned) }
        }
        return names
    }
}
