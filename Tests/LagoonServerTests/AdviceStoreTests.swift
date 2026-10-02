import XCTest
import Foundation
import Logging
import GRDB
@testable import LagoonKit
@testable import LagoonServer

/// Pins the advice store's load-bearing invariants (constitution §3).
final class AdviceStoreTests: XCTestCase {
    private func seedMessage(_ remoteId: String, accountId: UUID, db: LagoonDB) async throws {
        try await MessageStore.upsert(
            MessageHeader(
                id: UUID(),
                accountId: accountId,
                remoteId: remoteId,
                threadId: "t-\(remoteId)",
                fromAddress: "sender@example.com",
                fromName: "Sender",
                subject: "Subject",
                snippet: "snippet",
                receivedAt: Date(),
                isRead: false,
                isArchived: false
            ),
            db: db
        )
    }

    private func makeAccount() -> Account {
        Account(
            id: UUID(),
            provider: .qq,
            oauthUser: "advice-\(UUID().uuidString)",
            email: "advice-\(UUID().uuidString)@qq.com",
            credentials: nil
        )
    }

    /// Nothing in this file decrypts anything; a sealed dummy keeps the store
    /// contract intact without needing a real authorization code.
    private func seedAccount(_ account: Account, db: LagoonDB) async throws {
        try await AccountStore.upsert(
            account,
            credentials: try CredentialVault.seal(
                .imap(username: account.email, authCode: "auth-code")
            ),
            db: db
        )
    }

    private func cleanup(_ accountIds: [UUID]) -> @Sendable (LagoonDB) async -> Void {
        { conn in
            for id in accountIds {
                try? await TestDatabase.deleteMessages(accountId: id, db: conn)
                try? await TestDatabase.deleteAccount(id: id, db: conn)
            }
        }
    }

    /// Wraps the store's optional return so a nil can be asserted on separately
    /// from the value itself — `XCTUnwrap`'s autoclosure cannot await.
    private func record(
        accountId: UUID,
        remoteId: String,
        advice: Advice,
        source: AdviceSource = .ai,
        model: String? = "stub-model",
        db: LagoonDB
    ) async throws -> AdviceRecord? {
        try await AdviceStore.upsert(
            accountId: accountId,
            remoteId: remoteId,
            advice: advice,
            source: source,
            model: model,
            db: db
        )
    }

    // MARK: - Writing advice changes no mail

    /// The store writes only the `advice` table. A suggestion that says
    /// "delete" must leave the message exactly as it found it — unarchived,
    /// undeleted, unread, with no audit row. The whole product promise is here.
    func test_writingAdvice_leavesTheMessageUntouched() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection(cleanup: cleanup([account.id])) { conn in
                try await seedAccount(account, db: conn)
                try await seedMessage("m1", accountId: account.id, db: conn)

                let stored = try await record(
                    accountId: account.id,
                    remoteId: "m1",
                    advice: Advice(
                        action: .delete,
                        category: .marketing,
                        confidence: .high,
                        rationale: "促销邮件，无保留价值。"
                    ),
                    db: conn
                )
                let row = try XCTUnwrap(stored)
                XCTAssertEqual(row.advice.action, .delete)
                XCTAssertEqual(row.decision, .pending, "a fresh suggestion starts pending")

                let message = try await MessageStore.find(
                    remoteId: "m1", accountId: account.id, db: conn
                )
                XCTAssertEqual(message?.isArchived, false, "advice must not archive")
                XCTAssertEqual(message?.isDeleted, false, "advice must not delete")
                XCTAssertEqual(message?.isRead, false, "advice must not mark read")

                let actions = try await AIActionStore.recent(accountId: account.id, db: conn)
                XCTAssertTrue(
                    actions.isEmpty,
                    "advice must write no action audit rows; found \(actions.map(\.kind))"
                )
            }
        }
    }

    /// Advice for a message that is no longer local is dropped, not raised. The
    /// foreign key rejects it, and one lost row must not fail the batch it was
    /// classified in — the background classifier runs detached from the sync
    /// loop, so this race is reachable in normal operation.
    func test_adviceForVanishedMessage_isSkippedNotThrown() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection(cleanup: cleanup([account.id])) { conn in
                try await seedAccount(account, db: conn)
                // No message row: this is the vanished-header case.
                let stored = try await record(
                    accountId: account.id,
                    remoteId: "ghost",
                    advice: Advice(action: .archive),
                    source: .heuristic,
                    model: nil,
                    db: conn
                )
                XCTAssertNil(stored, "advice for mail that is gone must not create a row")
            }
        }
    }

    // MARK: - A verdict survives re-evaluation

    /// The failure mode this guards is nagging, not a crash: the background
    /// classifier re-evaluates the feed every refresh and a model's output is
    /// not deterministic, so an upsert that reset `decision` would put a
    /// dismissed suggestion straight back into the queue forever.
    func test_reUpsert_preservesTheUsersVerdict() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection(cleanup: cleanup([account.id])) { conn in
                try await seedAccount(account, db: conn)
                try await seedMessage("m1", accountId: account.id, db: conn)

                let firstStored = try await record(
                    accountId: account.id,
                    remoteId: "m1",
                    advice: Advice(action: .delete, confidence: .high),
                    db: conn
                )
                let first = try XCTUnwrap(firstStored)
                let dismissed = try await AdviceStore.setDecision(
                    id: first.id, accountId: account.id, decision: .dismissed, db: conn
                )
                XCTAssertTrue(dismissed)

                // The classifier re-evaluates the same message, now with a
                // different (and differently-worded) answer.
                let secondStored = try await record(
                    accountId: account.id,
                    remoteId: "m1",
                    advice: Advice(
                        action: .archive,
                        confidence: .low,
                        rationale: "第二轮的判断"
                    ),
                    db: conn
                )
                let second = try XCTUnwrap(secondStored)
                XCTAssertEqual(second.id, first.id, "the row is updated, not duplicated")
                XCTAssertEqual(second.advice.action, .archive, "the fresh advice is stored")
                XCTAssertEqual(second.advice.rationale, "第二轮的判断")
                XCTAssertEqual(
                    second.decision, .dismissed,
                    "re-evaluation must never resurrect a dismissed suggestion"
                )
                XCTAssertNotNil(second.decidedAt, "the verdict timestamp survives too")

                let queue = try await AdviceStore.list(
                    accountId: account.id, filter: .pending, db: conn
                )
                XCTAssertTrue(queue.isEmpty, "and it is out of the queue")
            }
        }
    }

    /// Withdrawing a verdict puts the suggestion back in the queue — the user
    /// changed their mind, and the UI must be able to say so.
    func test_decisionCanBeWithdrawnBackToPending() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection(cleanup: cleanup([account.id])) { conn in
                try await seedAccount(account, db: conn)
                try await seedMessage("m1", accountId: account.id, db: conn)
                let stored = try await record(
                    accountId: account.id,
                    remoteId: "m1",
                    advice: Advice(action: .archive),
                    source: .heuristic,
                    model: nil,
                    db: conn
                )
                let row = try XCTUnwrap(stored)

                _ = try await AdviceStore.setDecision(
                    id: row.id, accountId: account.id, decision: .accepted, db: conn
                )
                _ = try await AdviceStore.setDecision(
                    id: row.id, accountId: account.id, decision: .pending, db: conn
                )

                let queue = try await AdviceStore.list(
                    accountId: account.id, filter: .pending, db: conn
                )
                XCTAssertEqual(queue.map(\.id), [row.id])
                XCTAssertNil(queue.first?.decidedAt, "a pending row has no verdict timestamp")
            }
        }
    }

    /// Another mailbox's advice id must not be reachable. The route answers the
    /// same 404 for "does not exist" and "belongs elsewhere", so this is what
    /// keeps it from leaking another account's ids.
    func test_setDecision_isScopedToTheAccount() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let mine = makeAccount()
            let theirs = makeAccount()
            try await TestDatabase.withConnection(cleanup: cleanup([mine.id, theirs.id])) { conn in
                try await seedAccount(mine, db: conn)
                try await seedAccount(theirs, db: conn)
                try await seedMessage("m1", accountId: theirs.id, db: conn)
                let stored = try await record(
                    accountId: theirs.id,
                    remoteId: "m1",
                    advice: Advice(action: .delete),
                    db: conn
                )
                let row = try XCTUnwrap(stored)

                let crossed = try await AdviceStore.setDecision(
                    id: row.id, accountId: mine.id, decision: .dismissed, db: conn
                )
                XCTAssertFalse(crossed, "another account must not decide my advice")

                let untouched = try await AdviceStore.find(
                    remoteId: "m1", accountId: theirs.id, db: conn
                )
                XCTAssertEqual(untouched?.decision, .pending)
            }
        }
    }

    /// Batch read: a feed of 25 rows costs one query and every id comes back.
    func test_byRemoteIds_returnsOneRowPerId() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection(cleanup: cleanup([account.id])) { conn in
                try await seedAccount(account, db: conn)
                let ids = (0..<25).map { "m\($0)" }
                for id in ids {
                    try await seedMessage(id, accountId: account.id, db: conn)
                    _ = try await record(
                        accountId: account.id,
                        remoteId: id,
                        advice: Advice(action: .archive, confidence: .medium),
                        source: .heuristic,
                        model: nil,
                        db: conn
                    )
                }
                let found = try await AdviceStore.byRemoteIds(
                    Set(ids), accountId: account.id, db: conn
                )
                XCTAssertEqual(found.count, 25)
                XCTAssertEqual(Set(found.keys), Set(ids))

                let empty = try await AdviceStore.byRemoteIds([], accountId: account.id, db: conn)
                XCTAssertTrue(
                    empty.isEmpty,
                    "an empty id set must not reach the database with an empty IN ()"
                )
            }
        }
    }

    /// Deleting a message drops its advice with it. A suggestion about mail the
    /// user no longer has is noise, and the row would otherwise accumulate
    /// forever because advice is regenerated on every classifier pass.
    func test_deletingTheMessage_cascadesToItsAdvice() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection(cleanup: cleanup([account.id])) { conn in
                try await seedAccount(account, db: conn)
                try await seedMessage("m1", accountId: account.id, db: conn)
                _ = try await record(
                    accountId: account.id,
                    remoteId: "m1",
                    advice: Advice(action: .delete),
                    db: conn
                )
                // Removed the way the sync loop's reconcile removes it, so the
                // foreign key cascade is what is under test.
                try await conn.write { db in
                    try db.execute(
                        sql: "DELETE FROM message_headers WHERE account_id = ? AND remote_id = ?",
                        arguments: [account.id, "m1"]
                    )
                }
                let found = try await AdviceStore.find(
                    remoteId: "m1", accountId: account.id, db: conn
                )
                XCTAssertNil(found, "advice must not outlive its message")
            }
        }
    }

    /// Pruning only touches dismissed rows. Accepted and pending advice are
    /// the user's live queue and must survive; dismissed rows are derived data
    /// the classifier can regenerate, so they are the only safe prune target.
    func test_prune_removesOnlyDismissedAdvice() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection(cleanup: cleanup([account.id])) { conn in
                try await seedAccount(account, db: conn)
                for (index, decision) in [AdviceDecision.pending, .accepted, .dismissed].enumerated() {
                    let remoteId = "m\(index)"
                    try await seedMessage(remoteId, accountId: account.id, db: conn)
                    let stored = try await record(
                        accountId: account.id,
                        remoteId: remoteId,
                        advice: Advice(action: .archive),
                        source: .heuristic,
                        model: nil,
                        db: conn
                    )
                    let row = try XCTUnwrap(stored)
                    if decision != .pending {
                        _ = try await AdviceStore.setDecision(
                            id: row.id, accountId: account.id, decision: decision, db: conn
                        )
                    }
                }

                let pruned = try await AdviceStore.pruneDismissed(
                    accountId: account.id,
                    before: Date().addingTimeInterval(86_400),
                    db: conn
                )
                XCTAssertEqual(pruned, 1, "exactly the dismissed row is prunable")

                let remaining = try await AdviceStore.list(
                    accountId: account.id, filter: .all, db: conn
                )
                XCTAssertEqual(
                    Set(remaining.map(\.remoteId)),
                    ["m0", "m1"],
                    "pending and accepted advice must survive pruning"
                )
            }
        }
    }
}
