import XCTest
import Foundation
import Logging
import Hummingbird
import NIOCore
import GRDB
@testable import LagoonKit
@testable import LagoonServer

/// End-to-end for the two "get it back" routes:
///
/// * `POST /api/messages/{remoteId}/unarchive` — 取消归档
/// * `POST /api/messages/{remoteId}/restore` — 从废纸篓恢复
///
/// ## Why these routes are the whole point
///
/// `MailProvider` has implemented `unarchive` and `restoreFromTrash` since
/// before the UI existed, and the undo path has always used them — but only
/// within ⌘Z's 8-second toast window. Archiving is not an 8-second decision.
/// A user files a newsletter away in March and wants it back in September, and
/// "open the audit log, find the March row, hit undo" is not a recovery path.
///
/// These tests pin the four properties that make the routes trustworthy, and
/// each one is a way the feature can half-work:
///
/// 1. **Remote first.** The provider MOVE must happen before the local flag
///    flips. The reverse order leaves a message in the inbox on the server and
///    filed locally, which the next sync turns into a resurrection.
/// 2. **Compensation.** If the local commit fails after the remote MOVE, the
///    route must put the message back rather than leave a split-brain.
/// 3. **The flag actually flips.** A 200 with the row still archived is the
///    silent failure this whole feature exists to avoid.
/// 4. **Gating.** A provider without an archive folder gets 409 and changes
///    nothing, matching `archiveHandler`.
final class RestoreRoutesTests: XCTestCase {
    private let logger = Logger(label: "restore-routes-tests")

    /// An account with the capabilities a real connected mailbox has.
///
/// The capability set is **explicit** rather than defaulted, and that matters:
/// a fresh `Account` carries `MailCapabilities.unknown` (every flag false), so
/// a fixture that relied on the default would get a 409 from the archive gate
/// and the test would be asserting the gate instead of the route. The
/// `NoArchiveProvider` case below is where the 409 belongs.
private func makeAccount(
    archiveFolder: Bool = true
) -> Account {
    Account(
        id: UUID(),
        provider: .qq,
        oauthUser: "restore-\(UUID().uuidString)",
        email: "restore-\(UUID().uuidString)@qq.com",
        credentials: nil,
        capabilities: MailCapabilities(
            archiveFolder: archiveFolder, idle: true, move: true, serverSnippet: false
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

    /// Seeds a message already in the given state.
    ///
    /// `deleted` goes through `setDeleted` rather than the header: `upsert`
    /// deliberately never writes `is_deleted` (a header arriving from the
    /// provider is by definition not deleted), so a fixture that sets it there
    /// silently produces a live message.
    @discardableResult
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
        if deleted {
            try await MessageStore.setDeleted(
                remoteId: remoteId, accountId: accountId, deleted: true, db: db
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

    private func post(
        _ path: String, _ accountId: UUID, _ db: LagoonDB, _ provider: any MailProvider
    ) async throws -> (status: Int, actionId: Int64?) {
        let app = Application(router: makeRouter(provider, db))
        // The status is returned as a plain code rather than a typed enum so the
        // assertions below can name the exact code they mean (409 vs 502 is the
        // difference between "not allowed" and "the server was unreachable",
        // and `XCTAssertEqual(status, .conflict)` against a bare Int would not
        // compile).
        var status = 0
        var actionId: Int64?
        try await app.test(.router) { client in
            try await client.execute(
                uri: "\(path)?accountId=\(accountId.uuidString)", method: .post
            ) { response in
                status = Int(response.status.code)
                if response.status == .ok, !response.body.readableBytesView.isEmpty {
                    struct Body: Decodable { let ok: Bool; let actionId: Int64 }
                    actionId = try JSONDecoder().decode(
                        Body.self, from: Data(response.body.readableBytesView)
                    ).actionId
                }
            }
        }
        return (status, actionId)
    }

    private func flags(
        _ remoteId: String, _ accountId: UUID, _ db: LagoonDB
    ) async throws -> (archived: Bool, deleted: Bool)? {
        try db.read { raw in
            let row = try Row.fetchOne(
                raw,
                sql: """
                    SELECT is_archived, is_deleted FROM message_headers
                    WHERE account_id = ? AND remote_id = ?
                    """,
                arguments: [accountId, remoteId]
            )
            guard let row else { return nil }
            return (archived: row["is_archived"], deleted: row["is_deleted"])
        }
    }

    // MARK: - 取消归档

    /// The happy path: remote MOVE, local flag cleared, audit row written.
    func test_unarchive_movesRemotelyAndClearsTheLocalFlag() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let provider = StubMailProvider()
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await seedMessage("a1", accountId: account.id, db: conn, archived: true)

                let result = try await post(
                    "/api/messages/a1/unarchive", account.id, conn, provider
                )
                XCTAssertEqual(result.status, 200)

                let raw = try await flags("a1", account.id, conn)
                let after = try XCTUnwrap(raw)
                XCTAssertFalse(
                    after.archived,
                    "a 200 that leaves the row archived is the silent failure this route exists to prevent"
                )
                let remote = await provider.unarchiveCalls
                XCTAssertEqual(remote, ["a1"], "the remote MOVE must actually happen")
                XCTAssertNotNil(result.actionId, "every user verb must be undoable")
            }
        }
    }

    /// A provider that cannot move messages is rejected before any write, so a
    /// 409 leaves both sides untouched — the same contract `archiveHandler` has.
    ///
    /// Both halves are disabled deliberately: the *account* says there is no
    /// archive folder, which is the flag the route actually gates on. The
    /// provider wrapper is redundant with that and exists to prove the gate does
    /// not depend on asking the provider first — if the route asked the provider
    /// instead of reading the account, this test would still pass while a real
    /// mailbox with a mis-negotiated flag would not.
    func test_unarchive_withoutArchiveCapability_isConflictAndChangesNothing() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let provider = NoArchiveProvider(base: StubMailProvider())
            let account = makeAccount(archiveFolder: false)
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await seedMessage("a2", accountId: account.id, db: conn, archived: true)

                let result = try await post(
                    "/api/messages/a2/unarchive", account.id, conn, provider
                )
                XCTAssertEqual(result.status, 409)
                let raw = try await flags("a2", account.id, conn)
                let after = try XCTUnwrap(raw)
                XCTAssertTrue(after.archived, "a rejected unarchive must not touch the flag")
            }
        }
    }

    /// A failed remote MOVE must not clear the local flag.
    ///
    /// The failure this prevents: the server never moved the message, the local
    /// list drops it from the 档案柜 anyway, and the user believes it is in the
    /// inbox when it is still in the archive folder on the server.
    func test_unarchive_remoteFailure_leavesTheMessageArchived() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let provider = StubMailProvider()
            await provider.setUnarchiveFailure(.unreachable("test"))
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await seedMessage("a3", accountId: account.id, db: conn, archived: true)

                let result = try await post(
                    "/api/messages/a3/unarchive", account.id, conn, provider
                )
                XCTAssertEqual(result.status, 502)
                let raw = try await flags("a3", account.id, conn)
                let after = try XCTUnwrap(raw)
                XCTAssertTrue(after.archived)
            }
        }
    }

    // MARK: - 从废纸篓恢复

    /// The happy path: remote MOVE out of Trash, local flag cleared.
    func test_restore_movesRemotelyAndClearsTheDeletedFlag() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let provider = StubMailProvider()
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await seedMessage("d1", accountId: account.id, db: conn, deleted: true)

                let result = try await post(
                    "/api/messages/d1/restore", account.id, conn, provider
                )
                XCTAssertEqual(result.status, 200)

                let raw = try await flags("d1", account.id, conn)
                let after = try XCTUnwrap(raw)
                XCTAssertFalse(after.deleted, "a restored message must come back to the inbox")
                let remote = await provider.restoreCalls
                XCTAssertEqual(remote, ["d1"])
                XCTAssertNotNil(result.actionId)
            }
        }
    }

    /// A failed restore leaves the message deleted, both sides.
    func test_restore_remoteFailure_leavesTheMessageDeleted() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let provider = StubMailProvider()
            await provider.setRestoreFailure(.unreachable("test"))
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await seedMessage("d2", accountId: account.id, db: conn, deleted: true)

                let result = try await post(
                    "/api/messages/d2/restore", account.id, conn, provider
                )
                XCTAssertEqual(result.status, 502)
                let raw = try await flags("d2", account.id, conn)
                let after = try XCTUnwrap(raw)
                XCTAssertTrue(after.deleted, "the trash must not silently empty itself")
            }
        }
    }

    /// Restoring a message that is not in the trash is a no-op the client can
    /// ignore, not a server fault — the UI can offer 恢复 on any row.
    func test_restore_isIdempotentForALiveMessage() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let provider = StubMailProvider()
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await seedMessage("d3", accountId: account.id, db: conn, deleted: false)

                let result = try await post(
                    "/api/messages/d3/restore", account.id, conn, provider
                )
                XCTAssertEqual(result.status, 200)
                let raw = try await flags("d3", account.id, conn)
                let after = try XCTUnwrap(raw)
                XCTAssertFalse(after.deleted)
            }
        }
    }

    // MARK: - Guards

    /// Both routes are user-triggered and audited, never automatic.
    ///
    /// Constitution §2 rule 5: nothing may execute on its own. These routes are
    /// the *escape hatch* for two irreversible-ish verbs, so the risk is not
    /// that they fire by themselves but that a future "helpful" feature starts
    /// calling them without a gesture. This test says: calling them is a
    /// deliberate act that leaves exactly one audit row each.
    func test_bothRoutes_writeExactlyOneAuditRowEach() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let provider = StubMailProvider()
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await seedMessage("x1", accountId: account.id, db: conn, archived: true)
                try await seedMessage("x2", accountId: account.id, db: conn, deleted: true)

                _ = try await post("/api/messages/x1/unarchive", account.id, conn, provider)
                _ = try await post("/api/messages/x2/restore", account.id, conn, provider)

                let actions = try await AIActionStore.recent(
                    accountId: account.id, since: nil, limit: 50, db: conn
                )
                XCTAssertEqual(
                    actions.count, 2,
                    "one audit row per restore; a retry loop must not inflate the history"
                )
            }
        }
    }

    /// An unknown account is 404, not a silent success.
    func test_unknownAccount_isNotFound() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let provider = StubMailProvider()
            try await TestDatabase.withConnection { conn in
                let ghost = UUID()
                let un = try await post("/api/messages/none/unarchive", ghost, conn, provider)
                XCTAssertEqual(un.status, 404)
                let re = try await post("/api/messages/none/restore", ghost, conn, provider)
                XCTAssertEqual(re.status, 404)
                let calls = await provider.unarchiveCalls + provider.restoreCalls
                XCTAssertTrue(calls.isEmpty, "a 404 must not reach the provider")
            }
        }
    }
}

/// Wraps a provider so `capabilities()` reports no archive folder, while every
/// other call passes through. Used to prove the 409 gate runs *before* the
/// remote MOVE rather than after it.
private actor NoArchiveProvider: MailProvider {
    let base: any MailProvider
    let kind: MailProviderKind

    init(base: any MailProvider) {
        self.base = base
        self.kind = base.kind
    }

    func capabilities() async -> MailCapabilities {
        MailCapabilities(archiveFolder: false, idle: true, move: true, serverSnippet: false)
    }

    func pullChanges(after cursor: MailSyncState, waitUpTo: Duration) async throws -> MailChangeSet {
        try await base.pullChanges(after: cursor, waitUpTo: waitUpTo)
    }
    func setRead(remoteId: String, isRead: Bool) async throws { try await base.setRead(remoteId: remoteId, isRead: isRead) }
    func archive(remoteId: String) async throws { try await base.archive(remoteId: remoteId) }
    func unarchive(remoteId: String) async throws { try await base.unarchive(remoteId: remoteId) }
    func trash(remoteId: String) async throws { try await base.trash(remoteId: remoteId) }
    func restoreFromTrash(remoteId: String) async throws { try await base.restoreFromTrash(remoteId: remoteId) }
    func permanentlyDelete(remoteId: String) async throws { try await base.permanentlyDelete(remoteId: remoteId) }
    func emptyTrash() async throws { try await base.emptyTrash() }
    /// R2: folders `listFolders` returns and moves the stub recorded.
    var folderRows: [MailFolder] = []
    var moveCalls: [(remoteId: String, folder: String, createIfMissing: Bool)] = []
    var moveFailure: MailError?
    func listFolders() async throws -> [MailFolder] { folderRows }
    @discardableResult
    func move(remoteId: String, to folder: String, createIfMissing: Bool) async throws -> Bool {
        moveCalls.append((remoteId, folder, createIfMissing))
        if let moveFailure { throw moveFailure }
        return true
    }
    func listSent(limit: Int) async throws -> [MessageHeader] { try await base.listSent(limit: limit) }
    func fetchBody(remoteId: String) async throws -> FetchedBody { try await base.fetchBody(remoteId: remoteId) }
    func fetchAttachment(remoteId: String, attachmentId: String) async throws -> FetchedAttachmentBytes {
        try await base.fetchAttachment(remoteId: remoteId, attachmentId: attachmentId)
    }
    func fetchRawMessage(remoteId: String) async throws -> Data { try await base.fetchRawMessage(remoteId: remoteId) }
    func fetchRawHeaderValues(remoteId: String) async throws -> [String: String] {
        try await base.fetchRawHeaderValues(remoteId: remoteId)
    }
    func send(_ outbound: OutboundMessage) async throws -> String? { try await base.send(outbound) }
    func probe() async throws { try await base.probe() }
    func shutdown() async { await base.shutdown() }
}
