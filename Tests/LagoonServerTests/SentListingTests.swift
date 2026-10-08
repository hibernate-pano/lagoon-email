import XCTest
import Foundation
import Logging
import Hummingbird
import NIOCore
import GRDB
@testable import LagoonKit
@testable import LagoonServer

/// R1 — `GET /api/sent`, and the `is_sent` axis it introduces.
///
/// ## The failure this file exists to prevent
///
/// 「已发送」 is the **third** independent axis, alongside 档案柜 and 废纸篓.
/// The first two already had one bug between them: a message that was archived
/// and *then* deleted appeared in **neither** list, because each list filtered on
/// its own axis and both excluded it. That row lived in the server's Trash
/// folder and was unreachable in the app — the worst outcome a mail client can
/// have, and it was invisible until someone went looking.
///
/// Sent is exactly the shape that bug takes when a third axis arrives. So these
/// tests are mostly about **exclusion**: every combination of the three flags
/// must land in exactly one list, and `is_sent` must never leak into the inbox.
final class SentListingTests: XCTestCase {
    private let logger = Logger(label: "sent-tests")

    private func makeAccount() -> Account {
        Account(
            id: UUID(),
            provider: .qq,
            oauthUser: "sent-\(UUID().uuidString)",
            email: "sent-\(UUID().uuidString)@qq.com",
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

    /// A row already in the local table, in a given state.
    private func seedLocal(
        _ remoteId: String,
        accountId: UUID,
        db: LagoonDB,
        archived: Bool = false,
        deleted: Bool = false,
        sent: Bool = false
    ) async throws {
        try await MessageStore.upsert(
            MessageHeader(
                id: UUID(),
                accountId: accountId,
                remoteId: remoteId,
                threadId: "t-\(remoteId)",
                fromAddress: "someone@example.com",
                fromName: nil,
                subject: "Subject \(remoteId)",
                snippet: nil,
                receivedAt: Date(),
                isRead: true,
                isArchived: archived,
                isSent: sent
            ),
            db: db
        )
        if deleted {
            try await MessageStore.setDeleted(
                remoteId: remoteId, accountId: accountId, deleted: true, db: db
            )
        }
        if sent {
            try db.write { raw in
                try MessageStore.markSent(remoteId: remoteId, accountId: accountId, db: raw)
            }
        }
    }

    private func get(
        _ path: String, _ accountId: UUID, _ db: LagoonDB, _ provider: any MailProvider
    ) async throws -> (status: Int, rows: [String], total: Int, stale: Bool) {
        let router = Router<BasicRequestContext>()
        SentRoutes.register(
            on: router, db: db, logger: self.logger, makeProvider: { _ in provider }
        )
        let app = Application(router: router)
        var status = 0
        var rows: [String] = []
        var total = -1
        var stale = false
        try await app.test(.router) { client in
            var components = URLComponents()
            components.path = path
            components.queryItems = [
                URLQueryItem(name: "accountId", value: accountId.uuidString)
            ]
            try await client.execute(uri: components.string ?? "", method: .get) { response in
                status = Int(response.status.code)
                guard response.status == .ok,
                      !response.body.readableBytesView.isEmpty else { return }
                struct Body: Decodable {
                    struct Row: Decodable { let remoteId: String }
                    let messages: [Row]
                    let totalCount: Int
                    let staleReason: String?
                }
                let decoded = try JSONDecoder().decode(
                    Body.self, from: Data(response.body.readableBytesView)
                )
                rows = decoded.messages.map(\.remoteId).sorted()
                total = decoded.totalCount
                stale = decoded.staleReason != nil
            }
        }
        return (status, rows, total, stale)
    }

    // MARK: - 刷新与落库

    /// The rows the provider returns are stored locally, marked sent, and
    /// returned — all in one request. This is the only way 已发送 can ever show
    /// anything, because the sync loop does not read the Sent folder.
    func test_sentRowsAreFetchedStoredAndReturned() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let provider = StubMailProvider()
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                await provider.setSentRows([
                    MessageHeader(
                        id: UUID(), accountId: account.id, remoteId: "s1", threadId: "t1",
                        fromAddress: "me@example.com", fromName: "Me", subject: "已发一封",
                        snippet: nil, receivedAt: Date(), isRead: true, isArchived: false
                    ),
                    MessageHeader(
                        id: UUID(), accountId: account.id, remoteId: "s2", threadId: "t2",
                        fromAddress: "me@example.com", fromName: "Me", subject: "已发两封",
                        snippet: nil, receivedAt: Date(), isRead: true, isArchived: false
                    ),
                ])

                let result = try await get("/api/sent", account.id, conn, provider)
                XCTAssertEqual(result.status, 200)
                XCTAssertEqual(result.rows, ["s1", "s2"])
                XCTAssertEqual(result.total, 2)
                XCTAssertFalse(result.stale)

                // Stored, not just returned — this is what makes search and the
                // detail view work on sent mail without any extra code.
                let stored = try await MessageStore.count(
                    forAccount: account.id, sender: nil,
                    archived: false, deleted: false, sent: true,
                    stackMatch: nil, db: conn
                )
                XCTAssertEqual(stored, 2, "sent mail must be persisted, not streamed")
            }
        }
    }

    /// An empty Sent folder is an empty list, not an error.
    func test_emptySentFolder_isAnEmptyList() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let provider = StubMailProvider()
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                let result = try await get("/api/sent", account.id, conn, provider)
                XCTAssertEqual(result.status, 200)
                XCTAssertTrue(result.rows.isEmpty)
                XCTAssertEqual(result.total, 0)
            }
        }
    }

    /// No Sent folder at all is 404 — never an empty list.
    ///
    /// "This account has no Sent folder" and "you have never sent anything" are
    /// different claims, and showing the second when the first is true is a
    /// small lie that costs the user their trust in the surface.
    func test_accountWithoutSentFolder_is404NotAnEmptyList() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let provider = StubMailProvider()
            await provider.setSentFailure(.sentUnavailable)
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                let result = try await get("/api/sent", account.id, conn, provider)
                XCTAssertEqual(result.status, 404, "\"never sent anything\" is not the truth here")
            }
        }
    }

    /// A provider failure still renders the stored rows, marked stale.
    ///
    /// The user opened 已发送 to read an old reply, not to check connectivity.
    /// An error page would be a worse answer than a possibly-stale list that
    /// says so.
    func test_providerFailure_servesStoredRowsAndMarksThemStale() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let provider = StubMailProvider()
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await seedLocal("old", accountId: account.id, db: conn, sent: true)
                await provider.setSentFailure(.unreachable("test"))

                let result = try await get("/api/sent", account.id, conn, provider)
                XCTAssertEqual(result.status, 200, "a stale list beats an error page")
                XCTAssertEqual(result.rows, ["old"])
                XCTAssertTrue(
                    result.stale, "and it must say so — silence would read as fresh"
                )
            }
        }
    }

    // MARK: - 三轴互斥（本文件的核心）

    /// Every combination of the three axes lands in **exactly one** list.
    ///
    /// This is the test that would have caught the archived-then-deleted
    /// orphan, extended to the third axis. Eight combinations, each asserted to
    /// appear in one list and only one — the property that makes "where is this
    /// message?" answerable.
    func test_theThreeAxesAreMutuallyExclusive() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                // The eight combinations of (sent, archived, deleted).
                let cases: [(id: String, sent: Bool, archived: Bool, deleted: Bool)] = [
                    ("plain", false, false, false),
                    ("arch", false, true, false),
                    ("gone", false, false, true),
                    ("archGone", false, true, true),
                    ("out", true, false, false),
                    ("outArch", true, true, false),
                    ("outGone", true, false, true),
                    ("outArchGone", true, true, true),
                ]
                for c in cases {
                    try await seedLocal(
                        c.id, accountId: account.id, db: conn,
                        archived: c.archived, deleted: c.deleted, sent: c.sent
                    )
                }

                func inList(_ sent: Bool, _ archived: Bool, _ deleted: Bool) async throws -> [String] {
                    try await MessageStore.recent(
                        forAccount: account.id, limit: 100, sender: nil,
                        archived: archived, deleted: deleted, sent: sent,
                        stackMatch: nil, db: conn
                    ).map(\.remoteId).sorted()
                }

                let inbox = try await inList(false, false, false)
                let archive = try await inList(false, true, false)
                let trash = try await inList(false, false, true)
                let sentList = try await inList(true, false, false)

                // Every seeded row appears somewhere.
                let all = Set(inbox + archive + trash + sentList)
                XCTAssertEqual(all.count, cases.count, "a row is in no list at all:\(all)")

                // And in exactly one.
                for c in cases {
                    let lists = [
                        inbox.contains(c.id), archive.contains(c.id),
                        trash.contains(c.id), sentList.contains(c.id),
                    ]
                    XCTAssertEqual(
                        lists.filter { $0 }.count, 1,
                        "\(c.id) appears in \(lists.filter { $0 }.count) lists, expected 1"
                    )
                }
            }
        }
    }

    /// `is_sent` never leaks into the inbox.
    ///
    /// The one-directional check, isolated because it is the failure that would
    /// be most visible: a reply you sent showing up in your inbox as if it
    /// arrived. (`upsert` never writes `is_sent`, so a row can only get the
    /// flag from the Sent refresh — but the *listing* still has to respect it.)
    func test_sentMailNeverAppearsInTheInbox() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let provider = StubMailProvider()
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await seedLocal("mine", accountId: account.id, db: conn, sent: true)
                try await seedLocal("theirs", accountId: account.id, db: conn)

                let result = try await get("/api/sent", account.id, conn, provider)
                XCTAssertEqual(result.rows, ["mine"])
                let inbox = try await MessageStore.recent(
                    forAccount: account.id, limit: 100, sender: nil,
                    archived: false, deleted: false, sent: false,
                    stackMatch: nil, db: conn
                ).map(\.remoteId)
                XCTAssertEqual(inbox, ["theirs"])
            }
        }
    }

    /// `upsert` must not set `is_sent` on its own.
    ///
    /// This is the invariant that keeps a reply you sent from flipping itself
    /// to "sent" the next time the INBOX syncs: the flag comes from *which
    /// folder* a row arrived through, and `upsert` is only ever called for the
    /// inbox. If a future change made `upsert` write the column, every reply
    /// would quietly become invisible in the inbox.
    func test_upsertDoesNotSetTheSentFlag() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await MessageStore.upsert(
                    MessageHeader(
                        id: UUID(), accountId: account.id, remoteId: "r1", threadId: "t1",
                        fromAddress: "me@example.com", fromName: "Me",
                        subject: "我发出的", snippet: nil,
                        receivedAt: Date(), isRead: true, isArchived: false,
                        isSent: true
                    ),
                    db: conn
                )
                let flagged = try await MessageStore.count(
                    forAccount: account.id, sender: nil,
                    archived: false, deleted: false, sent: true,
                    stackMatch: nil, db: conn
                )
                XCTAssertEqual(
                    flagged, 0,
                    "upsert carries no folder knowledge, so it must not write is_sent"
                )
            }
        }
    }

    /// The count and the rows come from the same clause.
    func test_countMatchesTheRowsItLabels() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let provider = StubMailProvider()
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                for i in 1...4 {
                    try await seedLocal(
                        "s\(i)", accountId: account.id, db: conn, sent: true
                    )
                }
                let result = try await get("/api/sent", account.id, conn, provider)
                XCTAssertEqual(result.rows.count, result.total)
            }
        }
    }

    /// An unknown account is 404 and never reaches the provider.
    func test_unknownAccount_is404WithoutProviderCall() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let provider = StubMailProvider()
            try await TestDatabase.withConnection { conn in
                let ghost = UUID()
                let result = try await get("/api/sent", ghost, conn, provider)
                XCTAssertEqual(result.status, 404)
                let calls = await provider.listSentCalls
                XCTAssertEqual(calls, 0, "a 404 must not reach the provider")
            }
        }
    }

    /// The unread badge must not count sent mail.
    ///
    /// Found in the round-end review, not by a test — `unreadCount` and
    /// `pinnedCount` hand-roll their own predicates and predate `filterSQL`, so
    /// adding a third axis to the shared clause silently skipped them. These two
    /// assertions are here so that the *next* axis does not have to be
    /// remembered.
    func test_unreadBadge_excludesSentMail() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await seedLocal("unreadIn", accountId: account.id, db: conn)
                // `seedLocal` writes `isRead: true`; unread is the state under
                // test, so both rows are set unread explicitly below.
                _ = try conn.write { raw in
                    try MessageStore.setReadSync(
                        remoteId: "unreadIn", accountId: account.id,
                        isRead: false, db: raw
                    )
                }
                // A sent row that was never marked read — exactly what a
                // freshly sent reply looks like before it is opened.
                try await seedLocal("unreadOut", accountId: account.id, db: conn, sent: true)
                _ = try conn.write { raw in
                    try MessageStore.setReadSync(
                        remoteId: "unreadOut", accountId: account.id,
                        isRead: false, db: raw
                    )
                }
                let unread = try await MessageStore.unreadCount(
                    forAccount: account.id, db: conn
                )
                XCTAssertEqual(
                    unread, 1,
                    "a reply you sent is not unread mail; the badge must not claim it is"
                )
            }
        }
    }

    /// The pin badge must not count pins on sent mail, for the same reason.
    func test_pinnedBadge_excludesSentMail() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await seedLocal("pIn", accountId: account.id, db: conn)
                try await seedLocal("pOut", accountId: account.id, db: conn, sent: true)
                for remoteId in ["pIn", "pOut"] {
                    try conn.write { raw in
                        try raw.execute(
                            sql: """
                                INSERT OR REPLACE INTO message_pins
                                    (account_id, remote_id, created_at)
                                VALUES (?, ?, strftime('%Y-%m-%d %H:%M:%f','now'))
                                """,
                            arguments: [account.id, remoteId]
                        )
                    }
                }
                let pinned = try await MessageStore.pinnedCount(
                    forAccount: account.id, db: conn
                )
                XCTAssertEqual(
                    pinned, 1,
                    "a pin on a sent message describes nothing the 置顶 list shows"
                )
            }
        }
    }

    /// `reconcileInbox` must not delete sent rows — the **write** half of the
    /// exclusion this file already tests on the read half.
    ///
    /// `test_sentMailNeverAppearsInTheInbox` proves the inbox *listing*
    /// excludes sent mail. It says nothing about the reconciler, which decides
    /// which rows still *exist* — and that predicate used to be a second,
    /// hand-written copy of the inbox axes. It listed `is_archived` and
    /// `is_deleted` but not `is_sent`, because `is_sent` arrived later, with
    /// R1.
    ///
    /// That divergence deleted real mail. A sent row is written by
    /// `SentRoutes` with `is_archived = FALSE` and `is_deleted = FALSE` (the
    /// sync loop hardcodes `isArchived: false`), so it fell straight through
    /// the delete predicate on the next sync round: the header went, the
    /// cached body went with it via `ON DELETE CASCADE`, and `draft_replies`
    /// / `ai_overrides` — which carry no FK — were orphaned. The list came
    /// back on the next GET, so from the outside it read as a flicker; what
    /// did not come back was everything the user had taught the app about
    /// that sender.
    ///
    /// The row has to survive with its **body** attached: a surviving header
    /// over a cascaded-away body is the same loss wearing a nicer symptom.
    ///
    /// The ordinary inbox row is the control. It *should* be reconciled away,
    /// and if it ever survives, this test has passed for the wrong reason —
    /// which is why it is asserted rather than left implicit.
    func test_reconcileInboxKeepsSentRowsAndTheirBodies() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                let sentId = "sent-\(UUID().uuidString)"
                try await seedLocal(sentId, accountId: account.id, db: conn, sent: true)
                try await BodyStore.put(
                    accountId: account.id,
                    remoteId: sentId,
                    body: FetchedBody(
                        text: "a reply I sent", html: nil, attachments: [], hasMore: false
                    ),
                    db: conn
                )
                let goneId = "gone-\(UUID().uuidString)"
                try await seedLocal(goneId, accountId: account.id, db: conn)

                try await MessageStore.reconcileInbox(
                    accountId: account.id, keeping: [], db: conn
                )

                let survivors = try await MessageStore.recent(
                    forAccount: account.id, limit: 100, sender: nil,
                    archived: false, deleted: false, sent: true,
                    stackMatch: nil, db: conn
                ).map(\.remoteId)
                XCTAssertEqual(
                    survivors, [sentId],
                    "reconcile deleted a sent row: it is absent from the INBOX "
                    + "snapshot, but it is not inbox mail either"
                )
                let body = try await BodyStore.get(
                    accountId: account.id, remoteId: sentId, db: conn
                )
                XCTAssertEqual(
                    body?.text, "a reply I sent",
                    "the header survived but its body was cascaded away — the "
                    + "same loss with a symptom that reads like a cache miss"
                )
                let inbox = try await MessageStore.recent(
                    forAccount: account.id, limit: 100, sender: nil,
                    archived: false, deleted: false, sent: false,
                    stackMatch: nil, db: conn
                ).map(\.remoteId)
                XCTAssertTrue(
                    inbox.isEmpty,
                    "the control row survived, so this test could pass with "
                    + "reconcile having stopped deleting altogether"
                )
            }
        }
    }
}
