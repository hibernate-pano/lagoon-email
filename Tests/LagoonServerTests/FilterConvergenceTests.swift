import XCTest
import Foundation
import GRDB
@testable import LagoonKit
@testable import LagoonServer

/// R-01/B1: the multi-axis filter has exactly **one** authority.
///
/// ## Why this file exists
///
/// The store used to state the inbox/sent/trash axes eight times by hand —
/// `unreadCount`, `sentCount`, `deletedCount`, `trashedRemoteIds`,
/// `reconcileInbox` and friends all carried their own WHERE fragments beside
/// the shared `filterSQL` — and the drift was not hypothetical: the `is_sent`
/// axis reached the lists and skipped the hand-rolled counts, and the
/// reconciler's copy deleted sent mail. The convergence routes every *lens*
/// query through `filterSQL`; this file is what keeps it routed.
///
/// ## What it asserts, and why both halves matter
///
/// * **Internal consistency** — every count equals the list it labels, and
///   every list agrees with `trashedRemoteIds` / the reconciler. A future
///   edit that un-converges one side (or changes `filterSQL` unilaterally)
///   breaks this half.
/// * **Vetted semantics, as absolutes** — each seeded row must land in
///   exactly the sets the three-axis model says it lands in. Consistency
///   alone cannot catch a change that moves *both* a count and its list the
///   same wrong way; the absolute expectations can. They also pin the
///   documented quirks (Trash ignores the archived axis; Sent ignores it too;
///   both exclude each other where the model says so).
final class FilterConvergenceTests: XCTestCase {
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
                .imap(username: account.email, authCode: "code")
            ),
            db: db
        )
    }

    /// One row in an arbitrary axis combination, written through the real
    /// store paths (`upsert` never writes `is_deleted`/`is_sent`; those come
    /// from `setDeleted`/`markSent` exactly as in production).
    private func seedRow(
        _ remoteId: String,
        accountId: UUID,
        db: LagoonDB,
        read: Bool = true,
        archived: Bool = false,
        deleted: Bool = false,
        sent: Bool = false,
        receivedAt: Date = Date(),
        from: String = "sender@example.com",
        subject: String = "Subject",
        listUnsubscribe: Bool = false
    ) async throws {
        try await MessageStore.upsert(
            MessageHeader(
                id: UUID(),
                accountId: accountId,
                remoteId: remoteId,
                threadId: "t-\(remoteId)",
                fromAddress: from,
                fromName: nil,
                subject: subject,
                snippet: nil,
                receivedAt: receivedAt,
                isRead: read,
                isArchived: archived
            ),
            listUnsubscribe: listUnsubscribe,
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

    private func list(
        _ accountId: UUID, _ db: LagoonDB,
        archived: Bool = false, deleted: Bool = false, sent: Bool = false
    ) async throws -> [String] {
        try await MessageStore.recent(
            forAccount: accountId, limit: 10_000, sender: nil,
            archived: archived, deleted: deleted, sent: sent,
            stackMatch: nil, db: db
        ).map(\.remoteId).sorted()
    }

    // MARK: - 每轴一行 + 边界组合

    /// The full boundary matrix: one row per axis, plus every combination the
    /// model treats specially (`archived+unread`, `sent+archived`,
    /// `deleted+archived`, `sent+deleted`). Counts and lists must agree with
    /// each other AND with the model.
    func test_everyAxisCountAgreesWithItsListAndTheVettedSemantics() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                // 11 rows: 2 plain inbox (one read/one unread), 2 archived
                // (one unread — the archived+unread boundary), 3 trashed
                // (incl. archived+deleted), 3 sent (incl. sent+archived and
                // sent+deleted).
                try await seedRow("inRead", accountId: account.id, db: conn)
                try await seedRow("inUnread", accountId: account.id, db: conn, read: false)
                try await seedRow("archRead", accountId: account.id, db: conn, archived: true)
                try await seedRow(
                    "archUnread", accountId: account.id, db: conn, read: false, archived: true
                )
                try await seedRow("gone", accountId: account.id, db: conn, deleted: true)
                try await seedRow(
                    "goneUnread", accountId: account.id, db: conn, read: false, deleted: true
                )
                try await seedRow(
                    "goneArch", accountId: account.id, db: conn,
                    archived: true, deleted: true
                )
                try await seedRow("out", accountId: account.id, db: conn, sent: true)
                try await seedRow(
                    "outUnread", accountId: account.id, db: conn, read: false, sent: true
                )
                try await seedRow(
                    "outArch", accountId: account.id, db: conn, archived: true, sent: true
                )
                try await seedRow(
                    "outGone", accountId: account.id, db: conn, deleted: true, sent: true
                )

                // --- The lists, from the one shared clause.
                let inbox = try await list(account.id, conn)
                XCTAssertEqual(inbox, ["inRead", "inUnread"])
                let archive = try await list(account.id, conn, archived: true)
                XCTAssertEqual(archive, ["archRead", "archUnread"])
                // Trash ignores the archived axis (deleted wins the overlap)…
                let trash = try await list(account.id, conn, deleted: true)
                XCTAssertEqual(trash, ["gone", "goneArch", "goneUnread", "outGone"])
                // …and Sent ignores it too, but requires not-deleted.
                let sentList = try await list(account.id, conn, sent: true)
                XCTAssertEqual(sentList, ["out", "outArch", "outUnread"])

                // --- The counts, which must equal the lists they label.
                let unread = try await MessageStore.unreadCount(
                    forAccount: account.id, db: conn
                )
                XCTAssertEqual(
                    unread, 1,
                    "unreadCount must equal the inbox list's unread rows: only `inUnread`. "
                        + "An archived/sent/deleted unread row leaking in here is the exact "
                        + "axis-omission this file exists to catch."
                )
                let inboxUnread = try await MessageStore.recent(
                    forAccount: account.id, limit: 10_000, sender: nil,
                    archived: false, deleted: false, sent: false,
                    stackMatch: nil, db: conn
                ).filter { !$0.isRead }.count
                XCTAssertEqual(unread, inboxUnread, "badge vs the list it labels")

                let sentCount = try await MessageStore.sentCount(
                    forAccount: account.id, db: conn
                )
                XCTAssertEqual(sentCount, sentList.count)
                XCTAssertEqual(sentCount, 3)

                let deletedCount = try await MessageStore.deletedCount(
                    forAccount: account.id, db: conn
                )
                XCTAssertEqual(deletedCount, trash.count)
                XCTAssertEqual(deletedCount, 4)

                let trashedIds = try await MessageStore.trashedRemoteIds(
                    forAccount: account.id, db: conn
                )
                XCTAssertEqual(
                    trashedIds.sorted(), trash,
                    "清空废纸篓 and the trash listing must be the same set — one clause"
                )

                // --- No row in two folders, and none unreachable.
                let all = Set(inbox + archive + trash + sentList)
                XCTAssertEqual(all.count, 11, "a seeded row is in no list at all: \(all)")
            }
        }
    }

    /// `reconcileInbox` never touches a row that does not live on the inbox
    /// axes.
    ///
    /// This is the write half of the same definition the listing uses. The
    /// archived/sent/deleted rows are the control: the original bug deleted
    /// sent rows because the predicate was a hand-written copy missing that
    /// axis, so their survival is the assertion.
    func test_reconcileInboxKeepsEveryNonInboxAxis() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await seedRow("inKeep", accountId: account.id, db: conn)
                try await seedRow("archVanished", accountId: account.id, db: conn, archived: true)
                try await seedRow("outVanished", accountId: account.id, db: conn, sent: true)
                try await seedRow("goneVanished", accountId: account.id, db: conn, deleted: true)
                try await seedRow(
                    "outGoneVanished", accountId: account.id, db: conn,
                    deleted: true, sent: true
                )

                try await MessageStore.reconcileInbox(
                    accountId: account.id, keeping: ["inKeep"], db: conn
                )

                // The kept inbox row and every non-inbox row survive.
                for survivor in ["inKeep", "archVanished", "outVanished", "goneVanished", "outGoneVanished"] {
                    let row = try await MessageStore.find(
                        remoteId: survivor, accountId: account.id, db: conn
                    )
                    XCTAssertNotNil(
                        row,
                        "\(survivor) was deleted by reconcile — it lives on another axis "
                            + "and its absence from the INBOX snapshot says nothing about it"
                    )
                }
            }
        }
    }

    /// "Not in the inbox" is not "deleted".
    ///
    /// The reconciler used to read it that way: any inbox row the provider
    /// no longer listed was deleted, taking its cached body and its
    /// paid-for AI advice with it. But a message leaves the inbox every time
    /// it is **filed** — by Lagoon, or by another client on the same
    /// account — and the app never reads the archive or trash folders back.
    /// So the old rule could delete mail that was still on the server, in a
    /// folder Lagoon does not look at, for good.
    ///
    /// The rule now is: a row is removed only when the provider *confirmed*
    /// it is gone from the server, and a row whose whereabouts are unknown
    /// stays. This test pins both halves — the "confirmed gone" row is
    /// deleted, the "unknown" row is not, and the two confirmed-elsewhere
    /// rows are re-labelled rather than removed.
    func test_reconcileInboxRemovesOnlyRowsTheProviderConfirmedAreGone() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await seedRow("inKeep", accountId: account.id, db: conn)
                try await seedRow("inUnknown", accountId: account.id, db: conn)
                try await seedRow("inGone", accountId: account.id, db: conn)
                try await seedRow("inFiled", accountId: account.id, db: conn)
                try await seedRow("inBinned", accountId: account.id, db: conn)

                try await MessageStore.reconcileInbox(
                    accountId: account.id,
                    keeping: ["inKeep"],
                    archived: ["inFiled"],
                    trashed: ["inBinned"],
                    removing: ["inGone"],
                    db: conn
                )

                // `XCTAssert` takes autoclosures, which cannot await — every
                // lookup is hoisted into a local first.
                let gone = try await MessageStore.find(
                    remoteId: "inGone", accountId: account.id, db: conn
                )
                XCTAssertNil(
                    gone,
                    "a row the provider confirmed is gone from the server must be removed"
                )
                let unknown = try await MessageStore.find(
                    remoteId: "inUnknown", accountId: account.id, db: conn
                )
                XCTAssertNotNil(
                    unknown,
                    "a row whose whereabouts are unknown must not be deleted — it may have "
                        + "been filed by another client, and the app never reads that folder back"
                )
                let filed = try await MessageStore.find(
                    remoteId: "inFiled", accountId: account.id, db: conn
                )
                XCTAssertEqual(
                    filed?.isArchived, true,
                    "a row the provider found in the archive folder is re-labelled, not removed"
                )
                let binned = try await MessageStore.find(
                    remoteId: "inBinned", accountId: account.id, db: conn
                )
                XCTAssertEqual(
                    binned?.isDeleted, true,
                    "a row the provider found in the trash folder is re-labelled, not removed"
                )
                let kept = try await MessageStore.find(
                    remoteId: "inKeep", accountId: account.id, db: conn
                )
                XCTAssertNotNil(kept, "a row still in the inbox is kept")
            }
        }
    }

    /// Counts are scoped to one account.
    func test_axisCountsAreIsolatedPerAccount() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let first = makeAccount()
            let second = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(first, db: conn)
                try await seed(second, db: conn)
                try await seedRow("a1", accountId: first.id, db: conn, read: false)
                try await seedRow("a2", accountId: first.id, db: conn, deleted: true)
                try await seedRow("b1", accountId: second.id, db: conn, read: false)
                try await seedRow("b2", accountId: second.id, db: conn, sent: true)

                let firstUnread = try await MessageStore.unreadCount(
                    forAccount: first.id, db: conn
                )
                XCTAssertEqual(firstUnread, 1)
                let secondUnread = try await MessageStore.unreadCount(
                    forAccount: second.id, db: conn
                )
                XCTAssertEqual(secondUnread, 1)
                let firstDeleted = try await MessageStore.deletedCount(
                    forAccount: first.id, db: conn
                )
                XCTAssertEqual(firstDeleted, 1)
                let secondDeleted = try await MessageStore.deletedCount(
                    forAccount: second.id, db: conn
                )
                XCTAssertEqual(secondDeleted, 0)
                let secondSent = try await MessageStore.sentCount(
                    forAccount: second.id, db: conn
                )
                XCTAssertEqual(secondSent, 1)
                let firstSent = try await MessageStore.sentCount(
                    forAccount: first.id, db: conn
                )
                XCTAssertEqual(firstSent, 0)
            }
        }
    }

    // MARK: - 非 lens 查询的语义

    /// The queries that are *not* about a list keep their documented
    /// semantics — pinned here so the next person knows they were considered
    /// during the convergence, not overlooked.
    func test_nonLensQueriesKeepTheirDocumentedSemantics() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)

                // --- pinnedCount: counts the pin table, minus pins on sent
                // mail. A pin on an archived or trashed row still counts —
                // the documented quirk (see the function's comment).
                try await seedRow("pinArch", accountId: account.id, db: conn, archived: true)
                try await seedRow("pinGone", accountId: account.id, db: conn, deleted: true)
                try await seedRow("pinSent", accountId: account.id, db: conn, sent: true)
                for remoteId in ["pinArch", "pinGone", "pinSent"] {
                    try await MessageStore.setPinned(
                        true, remoteId: remoteId, accountId: account.id, db: conn
                    )
                }
                let pinned = try await MessageStore.pinnedCount(
                    forAccount: account.id, db: conn
                )
                XCTAssertEqual(
                    pinned, 2,
                    "pins on archived and trashed rows are deliberately counted; a pin on sent mail is not"
                )

                // --- oldestReceivedAt: the cache's lower edge. Skips deleted
                // rows; spans archived and sent ones.
                let base = Date(timeIntervalSince1970: 1_700_000_000)
                try await seedRow(
                    "oldGone", accountId: account.id, db: conn, deleted: true,
                    receivedAt: base.addingTimeInterval(-300 * 86_400)
                )
                try await seedRow(
                    "oldOut", accountId: account.id, db: conn, sent: true,
                    receivedAt: base.addingTimeInterval(-200 * 86_400)
                )
                try await seedRow(
                    "oldArch", accountId: account.id, db: conn, archived: true,
                    receivedAt: base.addingTimeInterval(-100 * 86_400)
                )
                let oldest = try await MessageStore.oldestReceivedAt(
                    forAccount: account.id, db: conn
                )
                XCTAssertNotNil(oldest)
                XCTAssertEqual(
                    oldest?.timeIntervalSince1970 ?? 0,
                    base.addingTimeInterval(-200 * 86_400).timeIntervalSince1970,
                    accuracy: 1.0,
                    "the sent row is the cache's oldest surviving row — deleted ones must not shift the bound"
                )

                // --- listUnsubscribeIds: the classifier's signal set spans
                // every axis.
                try await seedRow(
                    "subIn", accountId: account.id, db: conn, listUnsubscribe: true
                )
                try await seedRow(
                    "subGone", accountId: account.id, db: conn,
                    deleted: true, listUnsubscribe: true
                )
                try await seedRow("plain", accountId: account.id, db: conn)
                let signalled = try await MessageStore.listUnsubscribeIds(
                    forAccount: account.id, db: conn
                )
                XCTAssertEqual(
                    signalled, ["subIn", "subGone"],
                    "archived/trashed mail still teaches the classifier what subscription mail looks like"
                )

                // --- senderRanking: excludes sent and deleted, includes
                // archived (archived is where triage puts finished mail, not
                // mail that does not exist).
                let other = makeAccount()
                try await seed(other, db: conn)
                try await seedRow(
                    "bulkIn", accountId: other.id, db: conn, from: "bulk@x.com"
                )
                try await seedRow(
                    "bulkArch", accountId: other.id, db: conn,
                    archived: true, from: "bulk@x.com"
                )
                try await seedRow(
                    "bulkOut", accountId: other.id, db: conn,
                    sent: true, from: "bulk@x.com"
                )
                try await seedRow(
                    "bulkGone", accountId: other.id, db: conn,
                    deleted: true, from: "bulk@x.com"
                )
                try await seedRow(
                    "soloOut", accountId: other.id, db: conn,
                    sent: true, from: "solo@x.com"
                )
                let ranking = try await MessageStore.senderRanking(
                    forAccount: other.id, limit: 10, query: nil, db: conn
                )
                let bulk = ranking.first { $0.address == "bulk@x.com" }
                XCTAssertEqual(
                    bulk?.totalCount, 2,
                    "ranking counts inbox + archived, excludes sent + deleted"
                )
                XCTAssertNil(
                    ranking.first { $0.address == "solo@x.com" },
                    "a sender whose only mail is sent must not rank — the user is not their own correspondent"
                )
            }
        }
    }
}
