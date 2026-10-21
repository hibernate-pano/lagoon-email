import XCTest
import Foundation
import Logging
import Hummingbird
import HummingbirdTesting
import NIOCore
import GRDB
@testable import LagoonKit
@testable import LagoonServer

/// The briefing's window hides mail that still needs a reply.
///
/// The feed is bounded to 30 days. That is right for the bulk of a mailbox —
/// nobody wants a three-year-old newsletter in their triage pile — and wrong
/// for the mail the product's headline promise is about. The promise is
/// "clear it in ten minutes"; a mail that genuinely needs a reply does not
/// stop needing one because it got old, so a 35-day-old unanswered mail
/// would never appear in the queue. And a queue that can never be cleared is
/// not a queue.
///
/// So the window bounds the noise, and the backlog reaches past it for what
/// is still open.
final class BriefingBacklogTests: XCTestCase {
    private let logger = Logger(label: "briefing-backlog-tests")

    private func makeAccount() -> Account {
        Account(
            id: UUID(),
            provider: .qq,
            oauthUser: "bl-\(UUID().uuidString)",
            email: "bl-\(UUID().uuidString)@qq.com",
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

    /// A header that is *not* from a subscription sender and *not* from the
    /// account owner, so the heuristics put it in "needs reply" — the group
    /// the backlog is supposed to feed.
    private func header(
        _ remoteId: String,
        accountId: UUID,
        daysAgo: Double,
        isRead: Bool = false
    ) -> MessageHeader {
        MessageHeader(
            id: UUID(),
            accountId: accountId,
            remoteId: remoteId,
            threadId: "t-\(remoteId)",
            fromAddress: "person@example.com",
            fromName: "Person",
            subject: "Subject \(remoteId)",
            snippet: nil,
            receivedAt: Date().addingTimeInterval(-daysAgo * 24 * 60 * 60),
            isRead: isRead,
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
        BriefingRoutes.register(on: router, db: db, logger: self.logger)
        return router
    }

    private func briefing(
        _ accountId: UUID,
        db: LagoonDB,
        classifier: (any BriefingClassifying)? = nil
    ) async throws -> BriefingResponse {
        let router = Router()
        BriefingRoutes.register(
            on: router, db: db, logger: self.logger, classifier: classifier
        )
        let app = Application(router: router)
        var out: BriefingResponse?
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/briefing?accountId=\(accountId.uuidString)",
                method: .get
            ) { response in
                XCTAssertEqual(response.status, .ok)
                out = try Self.decoder().decode(
                    BriefingResponse.self,
                    from: Data(buffer: response.body)
                )
            }
        }
        return try XCTUnwrap(out)
    }

    // MARK: - The backlog reaches past the window

    /// An old unanswered mail appears in the feed.
    ///
    /// This is the whole point: the mail the user has to answer must never be
    /// invisible, however old it is.
    func test_oldUnansweredMailAppearsInTheFeed() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await MessageStore.upsert(
                    header("recent", accountId: account.id, daysAgo: 2), db: conn
                )
                try await MessageStore.upsert(
                    header("old", accountId: account.id, daysAgo: 90), db: conn
                )

                let response = try await briefing(account.id, db: conn)
                let ids = Set(response.items.map(\.message.remoteId))
                XCTAssertTrue(
                    ids.contains("old"),
                    "a 90-day-old unanswered mail is invisible — the queue can never be cleared"
                )
                // It lands where it belongs: in the group that says it needs
                // a reply, not in a separate section the user has to think
                // about.
                let old = response.items.first { $0.message.remoteId == "old" }
                XCTAssertEqual(old?.group, .needsReply)
            }
        }
    }

    /// Read old mail is not backlog.
    ///
    /// "Unread" is the honest test: the heuristics put a read mail older than
    /// a week into "safe to archive" — the user has seen it, the decision
    /// left is filing it, not answering it. Treating it as backlog would put
    /// every old newsletter the user ever opened back into the triage queue.
    func test_readOldMailIsNotBacklog() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await MessageStore.upsert(
                    header("old-read", accountId: account.id, daysAgo: 90, isRead: true),
                    db: conn
                )

                let response = try await briefing(account.id, db: conn)
                XCTAssertFalse(
                    response.items.contains { $0.message.remoteId == "old-read" },
                    "read mail is not backlog — the user has seen it"
                )
                XCTAssertNil(response.backlogCount)
            }
        }
    }

    /// Archived and trashed mail is not backlog either.
    ///
    /// The user filed it on purpose. Resurrecting it in the triage queue
    /// would undo a decision they made.
    func test_archivedAndTrashedMailIsNotBacklog() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await MessageStore.upsert(
                    header("old-archived", accountId: account.id, daysAgo: 90), db: conn
                )
                try await MessageStore.upsert(
                    header("old-trashed", accountId: account.id, daysAgo: 90), db: conn
                )
                try await MessageStore.setArchived(
                    true, remoteId: "old-archived", accountId: account.id, db: conn
                )
                try await MessageStore.setDeleted(
                    remoteId: "old-trashed", accountId: account.id, deleted: true, db: conn
                )

                let response = try await briefing(account.id, db: conn)
                let ids = Set(response.items.map(\.message.remoteId))
                XCTAssertFalse(
                    ids.contains("old-archived"),
                    "archived mail must not come back to the triage queue"
                )
                XCTAssertFalse(
                    ids.contains("old-trashed"),
                    "trashed mail must not come back to the triage queue"
                )
                XCTAssertNil(response.backlogCount)
            }
        }
    }

    /// Another account's old mail is not this account's backlog.
    func test_theBacklogDoesNotLeakAcrossAccounts() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let mine = makeAccount()
            let theirs = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(mine, db: conn)
                try await seed(theirs, db: conn)
                try await MessageStore.upsert(
                    header("theirs", accountId: theirs.id, daysAgo: 90), db: conn
                )

                let response = try await briefing(mine.id, db: conn)
                XCTAssertFalse(
                    response.items.contains { $0.message.remoteId == "theirs" },
                    "another mailbox's backlog leaked into this one"
                )
                XCTAssertNil(response.backlogCount)
            }
        }
    }

    // MARK: - The count

    /// The count says how many are waiting, so a capped backlog never reads
    /// as a complete one.
    func test_theBacklogCountIsReported() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                for i in 0..<3 {
                    try await MessageStore.upsert(
                        header("old-\(i)", accountId: account.id, daysAgo: 60 + Double(i)),
                        db: conn
                    )
                }

                let response = try await briefing(account.id, db: conn)
                XCTAssertEqual(response.backlogCount, 3)
                XCTAssertEqual(
                    response.items.filter { $0.message.remoteId.hasPrefix("old-") }.count,
                    3
                )
            }
        }
    }

    /// A quiet mailbox reports no backlog at all.
    ///
    /// Nil rather than 0: the field's presence means "there is a backlog",
    /// and a client that checks only for non-nil must not show an "0" line.
    func test_aQuietMailboxHasNoBacklog() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await MessageStore.upsert(
                    header("recent", accountId: account.id, daysAgo: 1), db: conn
                )

                let response = try await briefing(account.id, db: conn)
                XCTAssertNil(response.backlogCount)
            }
        }
    }

    /// The backlog is capped, and the count is the *total*, not the number
    /// shown.
    ///
    /// A mailbox with 200 old unanswered mails must not put 200 rows in the
    /// feed — and must not say "50" as if that were all of them.
    func test_theBacklogIsCapped_butTheCountIsTheTotal() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                let total = BriefingRoutes.maxBacklogItems + 20
                for i in 0..<total {
                    try await MessageStore.upsert(
                        header("old-\(i)", accountId: account.id, daysAgo: 60 + Double(i)),
                        db: conn
                    )
                }

                let response = try await briefing(account.id, db: conn)
                let oldRows = response.items.filter { $0.message.remoteId.hasPrefix("old-") }
                XCTAssertEqual(
                    oldRows.count, BriefingRoutes.maxBacklogItems,
                    "the backlog must be capped — a three-year backlog must not bury the feed"
                )
                XCTAssertEqual(
                    response.backlogCount, total,
                    "the count is the total, not the number of rows on screen"
                )
            }
        }
    }

    // MARK: - Cost

    /// The backlog rows are **not** sent to the AI classifier.
    ///
    /// The classifier's value is judging mail by content, and the backlog is
    /// unread mail the user has not looked at. Paying for a model to file it
    /// — every 30 seconds, on every refresh — would be the most expensive
    /// thing in the app for the least user-visible gain.
    func test_theBacklogIsNotSentToTheClassifier() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await MessageStore.upsert(
                    header("recent", accountId: account.id, daysAgo: 2), db: conn
                )
                try await MessageStore.upsert(
                    header("old", accountId: account.id, daysAgo: 90), db: conn
                )

                let classifier = RecordingClassifier()
                let response = try await briefing(account.id, db: conn, classifier: classifier)

                XCTAssertEqual(
                    classifier.asked, ["recent"],
                    "the backlog went to the model — every refresh would pay for it"
                )
                // And the old mail is still there, in the feed, at no cost.
                XCTAssertTrue(response.items.contains { $0.message.remoteId == "old" })
            }
        }
    }
}

/// Records the remote ids the classifier was asked about.
private final class RecordingClassifier: BriefingClassifying, @unchecked Sendable {
    private let lock = NSLock()
    private var _asked: [String] = []
    var asked: [String] { lock.lock(); defer { lock.unlock() }; return _asked }

    func classify(
        _ messages: [MessageHeader],
        accountEmail: String,
        language: String?
    ) async throws -> [String: ClassificationOutcome] {
        lock.lock()
        _asked.append(contentsOf: messages.map(\.remoteId))
        lock.unlock()
        return [:]
    }
}
