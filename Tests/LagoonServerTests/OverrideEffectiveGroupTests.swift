import XCTest
import Foundation
import Logging
import Hummingbird
import HummingbirdTesting
import NIOCore
import GRDB
@testable import LagoonServer
@testable import LagoonKit

/// 「改分组」 must resolve the group the way the **feed** resolves it.
///
/// ## The defect this file pins
///
/// The classify route computed the "from" group of a change from the
/// **sender** map. But the briefing resolves a mail's group with a
/// precedence of its own:
///
///   1. pinned
///   2. message-scoped override (the narrow rule)
///   3. sender-scoped override (the broad rule)
///   4. the classifier
///
/// So for a mail that carried a narrow rule, the route compared the
/// *sender's* group against the target while the feed was showing the
/// mail's own group. The two answers disagreed, and the consequences were
/// both bad:
///
/// * the change was **refused** with 「分组没变」 while the mail sat in a
///   different group — the user was denied a change they were entitled to
///   make; or
/// * the change was **accepted** while it moved nothing.
///
/// The mirror image broke the broad scope: a narrow rule on one mail made
/// 「把这个发件人的所有邮件移到 X」 answer 「分组没变」 while the sender's
/// other mail was still in the old group.
///
/// ## What these tests pin
///
/// The four cases of the precedence, each with the change the user is
/// entitled to make:
///
/// * (a) no override at all → the narrow change works;
/// * (b) a **sender** rule put the mail in X, and the user moves **this
///   mail** to Y → the narrow change works, and the sender's other mail
///   stays put;
/// * (c) a **narrow** rule already put the mail in the target → an honest
///   no-op, reported as such;
/// * (d) undoing a narrow rule → the mail falls back to the sender's rule
///   (or the heuristic), not to a stale value.
final class OverrideEffectiveGroupTests: XCTestCase {
    private let logger = Logger(label: "override-effective-group-tests")

    /// A value carried out of a Hummingbird test closure.
    ///
    /// The closure runs in a concurrent context, so a plain captured `var`
    /// would be a data race the compiler rightly warns about. The box is
    /// `@unchecked Sendable` because the write happens inside the response
    /// handler and the read happens after `app.test(.router)` returns —
    /// i.e. strictly ordered, with no concurrent access.
    private final class Captured<Value>: @unchecked Sendable {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    private func makeAccount() -> Account {
        Account(
            id: UUID(),
            provider: .qq,
            oauthUser: "oeg-\(UUID().uuidString)",
            email: "oeg-\(UUID().uuidString)@qq.com",
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
        daysAgo: Double = 1,
        isRead: Bool = false
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
        ActionsRoutes.register(on: router, db: db, logger: self.logger)
        BriefingRoutes.register(on: router, db: db, logger: self.logger)
        return router
    }

    /// POSTs a classify request.
    ///
    /// The response body is returned alongside the status, because the
    /// server's error envelope (`{"error":"group-unchanged"}`) is the
    /// thing several of these tests are about.
    private func classify(
        _ app: Application<RouterResponder<BasicRequestContext>>,
        remoteId: String,
        accountId: UUID,
        toGroup: String,
        scope: String?,
        fromGroup: String? = nil
    ) async throws -> (status: Int, body: String) {
        var payload: [String: Any] = ["toGroup": toGroup]
        if let scope { payload["scope"] = scope }
        if let fromGroup { payload["fromGroup"] = fromGroup }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let captured = Captured<(status: Int, body: String)>((0, ""))
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/messages/\(remoteId)/classify?accountId=\(accountId.uuidString)",
                method: .post,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(bytes: body)
            ) { response in
                captured.value = (
                    status: Int(response.status.code),
                    body: String(buffer: response.body)
                )
            }
        }
        return captured.value
    }

    /// The groups of several mails, read in one briefing request.
    private func groupsOf(
        _ app: Application<RouterResponder<BasicRequestContext>>,
        accountId: UUID
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

    /// Undoes the classify-override action that carries `scope`.
    private func undoOverride(
        _ app: Application<RouterResponder<BasicRequestContext>>,
        accountId: UUID,
        db: LagoonDB,
        scope: OverrideScope
    ) async throws -> AIAction {
        let actions = try await AIActionStore.recent(accountId: accountId, db: db)
        let row = try XCTUnwrap(
            actions.first { $0.kind == .classifyOverride && $0.payload["scope"] == scope.rawValue },
            "no classify-override action with scope \(scope.rawValue)"
        )
        let captured = Captured<Int>(0)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/actions/\(row.id)/undo?accountId=\(accountId.uuidString)",
                method: .post
            ) { response in
                captured.value = Int(response.status.code)
            }
        }
        XCTAssertEqual(captured.value, 200, "the undo must succeed")
        return row
    }

    // MARK: - (a) No override at all

    /// (a) A mail nobody has overridden, changed with the narrow scope.
    ///
    /// The baseline: the change works, and it moves exactly one mail.
    func test_narrowChangeOnAMailWithNoOverride_works() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                let first = header("a-1", accountId: account.id, from: "alice@example.com")
                let second = header("a-2", accountId: account.id, from: "alice@example.com")
                try await MessageStore.upsert(first, db: conn)
                try await MessageStore.upsert(second, db: conn)

                let app = Application(router: router(conn))
                let result = try await classify(
                    app, remoteId: first.remoteId, accountId: account.id,
                    toGroup: "subscriptionNoise", scope: "message"
                )
                XCTAssertEqual(
                    result.status, 200,
                    "a mail with no override must accept the narrow change"
                )

                let groups = try await groupsOf(app, accountId: account.id)
                XCTAssertEqual(groups[first.remoteId], .subscriptionNoise)
                XCTAssertNotEqual(
                    groups[second.remoteId], .subscriptionNoise,
                    "the narrow scope must still move only one mail"
                )
            }
        }
    }

    // MARK: - (b) The sender's rule put it in X; move THIS mail to Y

    /// (b) **The broken case.** A sender rule put every mail from Alice in
    /// X; the user picks Y for **this one mail**.
    ///
    /// The old code compared the *sender's* group (X) against Y, so the
    /// change was accepted and written — but the guard did not describe
    /// the mail, and a change to the group the mail was *already* in was
    /// refused with 「分组没变」 even though the mail was in X.
    ///
    /// What must happen: the mail moves to Y, and the sender's other mail
    /// stays in X.
    func test_narrowChangeOutOfTheSenderRule_movesTheMailAndNotTheSender() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                let first = header("b-1", accountId: account.id, from: "alice@example.com")
                let second = header("b-2", accountId: account.id, from: "alice@example.com")
                try await MessageStore.upsert(first, db: conn)
                try await MessageStore.upsert(second, db: conn)

                let app = Application(router: router(conn))
                // The broad rule: every mail from Alice goes to X.
                _ = try await classify(
                    app, remoteId: first.remoteId, accountId: account.id,
                    toGroup: "subscriptionNoise", scope: "sender"
                )
                var groups = try await groupsOf(app, accountId: account.id)
                XCTAssertEqual(groups[first.remoteId], .subscriptionNoise)
                XCTAssertEqual(groups[second.remoteId], .subscriptionNoise)

                // Now the narrow one: this mail moves to Y.
                let result = try await classify(
                    app, remoteId: first.remoteId, accountId: account.id,
                    toGroup: "awaitingReply", scope: "message"
                )
                XCTAssertEqual(
                    result.status, 200,
                    "moving one mail out of the group a sender rule gave it must work"
                )

                groups = try await groupsOf(app, accountId: account.id)
                XCTAssertEqual(
                    groups[first.remoteId], .awaitingReply,
                    "the mail the user acted on must be in the group they picked"
                )
                XCTAssertEqual(
                    groups[second.remoteId], .subscriptionNoise,
                    "the sender's other mail must stay where the sender rule put it"
                )
            }
        }
    }

    /// The mirror of (b): the narrow change to the group the mail is
    /// **already** in, because a sender rule put it there.
    ///
    /// This is a genuine no-op — the mail really is in that group — and
    /// the route must say so rather than pretending to have moved it.
    func test_narrowChangeToTheGroupTheSenderRuleAlreadyPutItIn_isAnHonestNoOp() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                let first = header("b2-1", accountId: account.id, from: "alice@example.com")
                try await MessageStore.upsert(first, db: conn)

                let app = Application(router: router(conn))
                _ = try await classify(
                    app, remoteId: first.remoteId, accountId: account.id,
                    toGroup: "subscriptionNoise", scope: "sender"
                )
                let result = try await classify(
                    app, remoteId: first.remoteId, accountId: account.id,
                    toGroup: "subscriptionNoise", scope: "message"
                )
                XCTAssertEqual(
                    result.status, 400,
                    "the mail is already in that group, so there is nothing to change"
                )
                XCTAssertTrue(
                    result.body.contains("group-unchanged"),
                    "the refusal must say *why*: the mail is already in that group. "
                        + "Got: \(result.body)"
                )

                // And nothing was written.
                let byMessage = try await AIActionStore.overridesByMessage(
                    accountId: account.id, db: conn
                )
                XCTAssertNil(
                    byMessage[first.remoteId],
                    "a refused no-op must not leave a rule behind"
                )
            }
        }
    }

    // MARK: - (c) A narrow rule already in the target group

    /// (c) The mail already carries a **narrow** rule naming the target.
    ///
    /// A genuine no-op, and the route must report it as one. The old code
    /// compared the *sender's* group here — which said nothing about this
    /// mail — so it either refused a real change or accepted a fake one.
    func test_narrowChangeToTheGroupANarrowRuleAlreadyNamed_isAnHonestNoOp() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                let first = header("c-1", accountId: account.id, from: "alice@example.com")
                try await MessageStore.upsert(first, db: conn)

                let app = Application(router: router(conn))
                let firstChange = try await classify(
                    app, remoteId: first.remoteId, accountId: account.id,
                    toGroup: "subscriptionNoise", scope: "message"
                )
                XCTAssertEqual(firstChange.status, 200)

                // The same group again: the mail is already there.
                let second = try await classify(
                    app, remoteId: first.remoteId, accountId: account.id,
                    toGroup: "subscriptionNoise", scope: "message"
                )
                XCTAssertEqual(
                    second.status, 400,
                    "the mail is already in the group its own rule named"
                )
                XCTAssertTrue(
                    second.body.contains("group-unchanged"),
                    "the refusal must name the reason. Got: \(second.body)"
                )

                let groups = try await groupsOf(app, accountId: account.id)
                XCTAssertEqual(
                    groups[first.remoteId], .subscriptionNoise,
                    "the mail must still be where the first change put it"
                )
            }
        }
    }

    /// The same case, but the mail also has a **sender** rule in a third
    /// group — so the two rules disagree, and only the narrow one may
    /// decide.
    ///
    /// The old code compared the sender's group, so it *accepted* a change
    /// to the group the mail was already in: it wrote a rule that moved
    /// nothing and reported success.
    func test_narrowNoOpWinsOverASenderRuleThatDisagrees() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                let first = header("c2-1", accountId: account.id, from: "alice@example.com")
                let second = header("c2-2", accountId: account.id, from: "alice@example.com")
                try await MessageStore.upsert(first, db: conn)
                try await MessageStore.upsert(second, db: conn)

                let app = Application(router: router(conn))
                // The sender's rule: X.
                _ = try await classify(
                    app, remoteId: second.remoteId, accountId: account.id,
                    toGroup: "subscriptionNoise", scope: "sender"
                )
                // The narrow rule on the first mail: Y.
                _ = try await classify(
                    app, remoteId: first.remoteId, accountId: account.id,
                    toGroup: "awaitingReply", scope: "message"
                )
                var groups = try await groupsOf(app, accountId: account.id)
                XCTAssertEqual(groups[first.remoteId], .awaitingReply)
                XCTAssertEqual(groups[second.remoteId], .subscriptionNoise)

                // Now ask for Y again on the first mail — where it already
                // is. The sender's rule (X) says "different", but the mail
                // is in Y, so this is a no-op.
                let result = try await classify(
                    app, remoteId: first.remoteId, accountId: account.id,
                    toGroup: "awaitingReply", scope: "message"
                )
                XCTAssertEqual(
                    result.status, 400,
                    "the mail is already in Y, so asking for Y again changes nothing"
                )
                XCTAssertTrue(
                    result.body.contains("group-unchanged"),
                    "the refusal must name the reason. Got: \(result.body)"
                )

                // And the mail did not move.
                groups = try await groupsOf(app, accountId: account.id)
                XCTAssertEqual(groups[first.remoteId], .awaitingReply)
            }
        }
    }

    // MARK: - The broad scope must not be blocked by a narrow rule

    /// The mirror of (c), on the **broad** scope.
    ///
    /// A narrow rule on one mail must not make 「把这个发件人的所有邮件移到
    /// X」 answer 「分组没变」 while the sender's other mail is still in the
    /// old group. The broad scope is a claim about the *sender*, so the
    /// narrow rule on one of its mails says nothing about it.
    func test_broadChangeIsNotBlockedByANarrowRuleOnOneMail() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                let first = header("d-1", accountId: account.id, from: "alice@example.com")
                let second = header("d-2", accountId: account.id, from: "alice@example.com")
                try await MessageStore.upsert(first, db: conn)
                try await MessageStore.upsert(second, db: conn)

                let app = Application(router: router(conn))
                // A narrow rule puts ONE mail in X.
                _ = try await classify(
                    app, remoteId: first.remoteId, accountId: account.id,
                    toGroup: "subscriptionNoise", scope: "message"
                )
                // Now the broad change to the same group X. The sender's
                // other mail is still in the heuristic group, so this is a
                // real change — and it must be accepted.
                let result = try await classify(
                    app, remoteId: first.remoteId, accountId: account.id,
                    toGroup: "subscriptionNoise", scope: "sender"
                )
                XCTAssertEqual(
                    result.status, 200,
                    "one mail's narrow rule must not block a change to the whole sender"
                )

                let groups = try await groupsOf(app, accountId: account.id)
                XCTAssertEqual(
                    groups[second.remoteId], .subscriptionNoise,
                    "the broad change must reach the sender's other mail"
                )
            }
        }
    }

    // MARK: - (d) Undo falls back, it does not freeze a stale value

    /// (d) Undoing a **narrow** rule lets the mail fall back to the
    /// sender's rule.
    ///
    /// The old undo wrote a counter-row naming the group the mail was in
    /// when the user made the change. That is a **stale** value: if the
    /// sender's rule has moved on since, the mail stays in the old group
    /// instead of following the sender's current one.
    ///
    /// What must happen: the mail falls back to the sender's rule as it
    /// stands now.
    func test_undoOfANarrowRule_fallsBackToTheSenderRule() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                let first = header("e-1", accountId: account.id, from: "alice@example.com")
                let second = header("e-2", accountId: account.id, from: "alice@example.com")
                try await MessageStore.upsert(first, db: conn)
                try await MessageStore.upsert(second, db: conn)

                let app = Application(router: router(conn))
                // The sender's rule: X.
                _ = try await classify(
                    app, remoteId: second.remoteId, accountId: account.id,
                    toGroup: "subscriptionNoise", scope: "sender"
                )
                // The narrow rule on the first mail: Y.
                _ = try await classify(
                    app, remoteId: first.remoteId, accountId: account.id,
                    toGroup: "awaitingReply", scope: "message"
                )
                var groups = try await groupsOf(app, accountId: account.id)
                XCTAssertEqual(groups[first.remoteId], .awaitingReply)

                // Undo the narrow rule.
                _ = try await undoOverride(
                    app, accountId: account.id, db: conn, scope: .message
                )

                groups = try await groupsOf(app, accountId: account.id)
                XCTAssertEqual(
                    groups[first.remoteId], .subscriptionNoise,
                    "undoing the narrow rule must let the mail fall back to the "
                        + "sender's rule, not stay in a stale value"
                )
                XCTAssertEqual(
                    groups[second.remoteId], .subscriptionNoise,
                    "the sender's other mail must not have moved"
                )

                // And the narrow map must no longer name this mail.
                let byMessage = try await AIActionStore.overridesByMessage(
                    accountId: account.id, db: conn
                )
                XCTAssertNil(
                    byMessage[first.remoteId],
                    "undoing the narrow rule must remove it, so the mail can fall back"
                )
            }
        }
    }

    /// Undoing a narrow rule with **no** sender rule falls back to the
    /// classifier's group **as it stands now** — not to the group the mail
    /// was in when the user made the change.
    ///
    /// ## Why the read flag moves in the middle
    ///
    /// The first version of this test applied the rule and undid it with
    /// nothing else happening. That passed under a mutation that wrote a
    /// counter-row instead of removing the rule, because the stale value
    /// and the live one happened to be the same group — so the assertion
    /// could not tell "fell back" from "froze".
    ///
    /// Here the classifier's answer **changes** between the change and the
    /// undo: the mail is old and unread (→ needs reply), the user moves it
    /// to X, then reads it — and old + read is "safe to archive". Undoing
    /// the rule must land in "safe to archive", the group the mail is in
    /// now. A counter-row would restore the stale "needs reply".
    func test_undoOfANarrowRule_fallsBackToTheClassifiersCurrentAnswer() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                // Old and unread: the heuristic says needsReply.
                let first = header(
                    "e2-1", accountId: account.id, from: "alice@example.com",
                    daysAgo: 20, isRead: false
                )
                try await MessageStore.upsert(first, db: conn)

                let app = Application(router: router(conn))
                var groups = try await groupsOf(app, accountId: account.id)
                XCTAssertEqual(
                    groups[first.remoteId], .needsReply,
                    "an old unread mail needs a reply"
                )

                _ = try await classify(
                    app, remoteId: first.remoteId, accountId: account.id,
                    toGroup: "subscriptionNoise", scope: "message"
                )
                groups = try await groupsOf(app, accountId: account.id)
                XCTAssertEqual(groups[first.remoteId], .subscriptionNoise)

                // Reading it changes the classifier's answer: old + read is
                // safe to archive. The rule still wins, so the feed does not
                // move yet.
                try await MessageStore.setRead(
                    remoteId: first.remoteId, accountId: account.id,
                    isRead: true, db: conn
                )
                groups = try await groupsOf(app, accountId: account.id)
                XCTAssertEqual(
                    groups[first.remoteId], .subscriptionNoise,
                    "the narrow rule still wins while it exists"
                )

                _ = try await undoOverride(
                    app, accountId: account.id, db: conn, scope: .message
                )

                groups = try await groupsOf(app, accountId: account.id)
                XCTAssertEqual(
                    groups[first.remoteId], .safeToArchive,
                    "undo must fall back to the classifier's CURRENT answer "
                        + "(old + read = safe to archive), not the group the "
                        + "mail was in when the rule was written"
                )
            }
        }
    }

    /// The broad scope's undo still flips the **sender** back.
    ///
    /// The narrow scope's undo removes a rule; the broad scope's undo
    /// writes a counter-rule, because the rule it reverses reached every
    /// mail from that sender and the inverse must too.
    func test_undoOfABroadRule_stillFlipsTheSenderBack() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                let first = header("f-1", accountId: account.id, from: "alice@example.com")
                let second = header("f-2", accountId: account.id, from: "alice@example.com")
                try await MessageStore.upsert(first, db: conn)
                try await MessageStore.upsert(second, db: conn)

                let app = Application(router: router(conn))
                let before = try await groupsOf(app, accountId: account.id)
                let originalGroup = try XCTUnwrap(before[first.remoteId])

                _ = try await classify(
                    app, remoteId: first.remoteId, accountId: account.id,
                    toGroup: "subscriptionNoise", scope: "sender"
                )
                _ = try await undoOverride(
                    app, accountId: account.id, db: conn, scope: .sender
                )

                let groups = try await groupsOf(app, accountId: account.id)
                XCTAssertEqual(
                    groups[first.remoteId], originalGroup,
                    "undoing the broad rule must flip the sender back"
                )
                XCTAssertEqual(
                    groups[second.remoteId], originalGroup,
                    "the sender's other mail must flip back too"
                )
            }
        }
    }
}
