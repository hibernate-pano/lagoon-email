import Foundation
import XCTest
import Logging
import Hummingbird
import HummingbirdTesting
import NIOCore
import GRDB
@testable import LagoonKit
@testable import LagoonServer

/// 发信完整性：幂等键必须让一封邮件只发一次（F-04），超大的邮件必须被
/// 当成"太大"而不是"服务器坏了"（F-09）。
///
/// The bug these tests pin: the send routes looked the client's idempotency
/// key up and sent when nothing was there. That is a check-then-act race —
/// two requests arriving together both find nothing and both put the mail
/// on the wire. The unique index that was supposed to stop the second one
/// only failed *after* the mail was gone, and the failure was logged and
/// answered with 200 anyway. The recipient got two copies.
final class SendIntegrityTests: XCTestCase {
    private let logger = Logger(label: "send-integrity-tests")

    // MARK: - Route level

    /// Two requests, one idempotency key, one mail.
    ///
    /// The first request is parked inside the provider when the second one
    /// arrives, so the two really do overlap — which is the only way the
    /// race the fix is about can happen.
    func test_concurrentRequestsWithSameRequestId_sendOnlyOnce() async throws {
        let account = makeAccount()
        try await TestDatabase.withConnection { conn in
            try await seed(account, db: conn)
            let gate = RaceGate()
            let provider = GatedMailProvider()
            await provider.setSendGate(gate)
            let app = Application(router: makeRouter(db: conn, provider: provider))
            let requestId = UUID().uuidString.lowercased()
            let body = composeBody(requestId: requestId)

            try await app.test(.router) { client in
                let uri = "/api/compose/send?accountId=\(account.id.uuidString)"
                await withTaskGroup(of: HTTPResponse.Status?.self) { group in
                    for _ in 0..<2 {
                        group.addTask {
                            try? await client.execute(
                                uri: uri,
                                method: .post,
                                headers: [.contentType: "application/json"],
                                body: body
                            ) { $0.status }
                        }
                    }
                    // One of the two is inside the provider. The other must
                    // not get there: the claim is what stops it.
                    await gate.waitForArrival()
                    try? await Task.sleep(for: .milliseconds(300))
                    await gate.release()

                    var statuses: [HTTPResponse.Status] = []
                    for await status in group {
                        if let status { statuses.append(status) }
                    }
                    XCTAssertEqual(statuses.count, 2, "both requests must be answered")
                    XCTAssertTrue(
                        statuses.allSatisfy { $0 == .ok },
                        "both requests must be answered, got \(statuses)"
                    )
                }
            }

            let attempts = await provider.sendAttempts
            XCTAssertEqual(
                attempts, 1,
                "one idempotency key must produce exactly one mail — the recipient got two copies"
            )
        }
    }

    /// A send that failed must give the key back.
    ///
    /// The user's retry carries the same requestId (the composer keeps it
    /// for as long as the sheet is open), so a failed send that kept the
    /// claim would leave the message unsendable: the retry would find a
    /// claim nobody owns any more.
    func test_failedSend_releasesTheClaim_soTheSameRequestIdSendsAgain() async throws {
        let account = makeAccount()
        try await TestDatabase.withConnection { conn in
            try await seed(account, db: conn)
            let provider = GatedMailProvider()
            await provider.setSendResult(.failure(MailError.unreachable("smtp-421")))
            let app = Application(router: makeRouter(db: conn, provider: provider))
            let requestId = UUID().uuidString.lowercased()
            let body = composeBody(requestId: requestId)

            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/api/compose/send?accountId=\(account.id.uuidString)",
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: body
                ) { response in
                    XCTAssertEqual(response.status, .badGateway)
                }
            }

            // The provider works now: the retry with the same key must send.
            await provider.setSendResult(.success("<retry@example.com>"))
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/api/compose/send?accountId=\(account.id.uuidString)",
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: body
                ) { response in
                    XCTAssertEqual(response.status, .ok)
                    let decoded = try JSONDecoder().decode(
                        SendResponse.self,
                        from: Data(response.body.readableBytesView)
                    )
                    XCTAssertEqual(decoded.providerMessageId, "<retry@example.com>")
                }
            }

            let attempts = await provider.sendAttempts
            XCTAssertEqual(attempts, 2, "the failed attempt and the retry")
            let delivered = await provider.deliveredOutbounds
            XCTAssertEqual(delivered.count, 1, "only the successful attempt went out")
        }
    }

    // MARK: - Store level

    /// The claim itself: two requests, one winner.
    ///
    /// This is the root cause in its smallest form — the winner is decided
    /// by the unique index, not by whoever read the table first.
    func test_claimSend_twoConcurrentClaims_onlyOneWins() async throws {
        let account = makeAccount()
        try await TestDatabase.withConnection { conn in
            try await seed(account, db: conn)
            let requestId = UUID().uuidString.lowercased()
            let shared = SharedDB(db: conn)

            let claims = try await withThrowingTaskGroup(
                of: AIActionStore.SendClaim.self
            ) { group in
                for _ in 0..<2 {
                    group.addTask {
                        try await AIActionStore.claimSend(
                            accountId: account.id,
                            requestId: requestId,
                            payload: ["to": "alice@example.com"],
                            db: shared.db,
                            waitForInFlight: .milliseconds(50)
                        )
                    }
                }
                var collected: [AIActionStore.SendClaim] = []
                for try await claim in group { collected.append(claim) }
                return collected
            }

            let winners = claims.filter { if case .claimed = $0 { return true } else { return false } }
            XCTAssertEqual(winners.count, 1, "exactly one request may send")
        }
    }

    /// A claim that is still in flight blocks the next one. The next one
    /// waits rather than sending — that is the whole point.
    func test_claimSend_aPendingClaimBlocksTheNextClaim() async throws {
        let account = makeAccount()
        try await TestDatabase.withConnection { conn in
            try await seed(account, db: conn)
            let requestId = UUID().uuidString.lowercased()

            let first = try await AIActionStore.claimSend(
                accountId: account.id,
                requestId: requestId,
                payload: ["to": "alice@example.com"],
                db: conn
            )
            guard case .claimed(let rowId) = first else {
                return XCTFail("the first claim must win")
            }

            let second = try await AIActionStore.claimSend(
                accountId: account.id,
                requestId: requestId,
                payload: ["to": "alice@example.com"],
                db: conn,
                waitForInFlight: .milliseconds(50)
            )
            guard case .inFlight = second else {
                return XCTFail("a claim in flight must not be taken over")
            }

            // Once the claim is delivered, the next request replays it.
            try await AIActionStore.completeSend(
                id: rowId, payload: ["providerMessageId": "<m1@example.com>"], db: conn
            )
            let third = try await AIActionStore.claimSend(
                accountId: account.id,
                requestId: requestId,
                payload: ["to": "alice@example.com"],
                db: conn,
                waitForInFlight: .milliseconds(50)
            )
            guard case .alreadySent(let action) = third else {
                return XCTFail("a delivered send must be replayed, not re-sent")
            }
            XCTAssertEqual(action.payload["providerMessageId"], "<m1@example.com>")
        }
    }

    /// A claim whose holder died (the process was killed, a socket write
    /// hung forever) must not block the key for the next 30 days.
    func test_claimSend_aStaleClaimIsTakenOver() async throws {
        let account = makeAccount()
        try await TestDatabase.withConnection { conn in
            try await seed(account, db: conn)
            let requestId = UUID().uuidString.lowercased()

            let first = try await AIActionStore.claimSend(
                accountId: account.id,
                requestId: requestId,
                payload: ["to": "alice@example.com"],
                db: conn
            )
            guard case .claimed(let rowId) = first else {
                return XCTFail("the first claim must win")
            }

            // Age the claim past the lease: this is what a request that
            // died mid-send leaves behind.
            let stale = Date().addingTimeInterval(-AIActionStore.sendClaimLeaseSeconds - 60)
            try conn.write { db in
                try db.execute(
                    sql: "UPDATE ai_actions SET created_at = ? WHERE id = ?",
                    arguments: [stale, rowId]
                )
            }

            let second = try await AIActionStore.claimSend(
                accountId: account.id,
                requestId: requestId,
                payload: ["to": "alice@example.com"],
                db: conn,
                waitForInFlight: .milliseconds(50)
            )
            guard case .claimed = second else {
                return XCTFail("a stale claim must be taken over, not waited on forever")
            }
        }
    }

    /// A failed send is not a reply: the briefing classifier must keep
    /// asking about a message the user never answered.
    func test_repliedRemoteIds_ignoresASendThatFailed() async throws {
        let account = makeAccount()
        try await TestDatabase.withConnection { conn in
            try await seed(account, db: conn)
            let requestId = UUID().uuidString.lowercased()

            let claim = try await AIActionStore.claimSend(
                accountId: account.id,
                requestId: requestId,
                payload: ["remoteId": "m-1", "to": "alice@example.com"],
                db: conn
            )
            guard case .claimed(let rowId) = claim else {
                return XCTFail("the claim must be taken")
            }
            try await AIActionStore.failSend(id: rowId, reason: "unreachable", db: conn)

            let replied = try await AIActionStore.repliedRemoteIds(accountId: account.id, db: conn)
            XCTAssertTrue(replied.isEmpty, "a failed send is not a reply")

            // The same row, once delivered, does count.
            try await AIActionStore.completeSend(id: rowId, payload: [:], db: conn)
            let afterDelivery = try await AIActionStore.repliedRemoteIds(accountId: account.id, db: conn)
            XCTAssertEqual(afterDelivery, ["m-1"])
        }
    }

    /// `findSend` answers "has this gone out?". A claim that is still in
    /// flight has not.
    func test_findSend_onlyReportsDeliveredSends() async throws {
        let account = makeAccount()
        try await TestDatabase.withConnection { conn in
            try await seed(account, db: conn)
            let requestId = UUID().uuidString.lowercased()

            let claim = try await AIActionStore.claimSend(
                accountId: account.id,
                requestId: requestId,
                payload: ["to": "alice@example.com"],
                db: conn
            )
            guard case .claimed(let rowId) = claim else {
                return XCTFail("the claim must be taken")
            }

            let inFlight = try await AIActionStore.findSend(
                accountId: account.id, requestId: requestId, db: conn
            )
            XCTAssertNil(inFlight, "a claim in flight is not a delivered send")

            try await AIActionStore.completeSend(
                id: rowId, payload: ["providerMessageId": "<m1@example.com>"], db: conn
            )
            let delivered = try await AIActionStore.findSend(
                accountId: account.id, requestId: requestId, db: conn
            )
            XCTAssertEqual(delivered?.payload["providerMessageId"], "<m1@example.com>")
        }
    }

    /// The history says what Lagoon *did*.
    ///
    /// The claim row exists from the moment the send starts, but the
    /// client's title for a send row is "Sent message". A send that is
    /// still in flight, or that failed, must not sit in the history
    /// claiming the mail went out.
    func test_recent_hidesASendThatHasNotGoneOut() async throws {
        let account = makeAccount()
        try await TestDatabase.withConnection { conn in
            try await seed(account, db: conn)
            let requestId = UUID().uuidString.lowercased()

            let claim = try await AIActionStore.claimSend(
                accountId: account.id,
                requestId: requestId,
                payload: ["to": "alice@example.com", "type": "compose"],
                db: conn
            )
            guard case .claimed(let rowId) = claim else {
                return XCTFail("the claim must be taken")
            }

            let inFlight = try await AIActionStore.recent(accountId: account.id, db: conn)
            XCTAssertTrue(
                inFlight.allSatisfy { $0.payload["requestId"] != requestId },
                "a send in flight is not in the history yet"
            )

            try await AIActionStore.failSend(id: rowId, reason: "unreachable", db: conn)
            let failed = try await AIActionStore.recent(accountId: account.id, db: conn)
            XCTAssertTrue(
                failed.allSatisfy { $0.payload["requestId"] != requestId },
                "a failed send did not go out"
            )

            try await AIActionStore.completeSend(id: rowId, payload: [:], db: conn)
            let delivered = try await AIActionStore.recent(accountId: account.id, db: conn)
            XCTAssertTrue(
                delivered.contains { $0.payload["requestId"] == requestId },
                "a delivered send belongs in the history"
            )
        }
    }

    // MARK: - F-09: too big is not broken

    /// A message whose encoded body does not fit the framing ceiling is too
    /// big — 413, not 502 "server error".
    ///
    /// 25 MB of attachment travels as ~33 MB of base64, so this is a size
    /// the product promised to accept. Answering 502 told the user the
    /// server broke and invited a retry that could never work.
    func test_providerError_oversizeLiteral_is413Not502() {
        let response = MessageRoutes.providerError(
            .protocolError(IMAPConnection.oversizeLiteralLabel),
            logger: self.logger,
            remoteId: "m-1"
        )
        XCTAssertEqual(response.status, .contentTooLarge)

        // A protocol error that is not about size stays a 502.
        let other = MessageRoutes.providerError(
            .protocolError("tagged BAD"),
            logger: self.logger,
            remoteId: "m-1"
        )
        XCTAssertEqual(other.status, .badGateway)
    }

    /// The same verdict, end to end: the body route turns the framing
    /// overflow into 413.
    func test_bodyRoute_oversizeLiteral_is413Not502() async throws {
        let account = makeAccount()
        try await TestDatabase.withConnection { conn in
            try await seed(account, db: conn)
            let provider = GatedMailProvider()
            await provider.setBodyError(.protocolError(IMAPConnection.oversizeLiteralLabel))
            let app = Application(router: makeRouter(db: conn, provider: provider))

            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/api/messages/m-1/body?accountId=\(account.id.uuidString)",
                    method: .get
                ) { response in
                    XCTAssertEqual(response.status, .contentTooLarge)
                }
            }
        }
    }

    // MARK: - Helpers

    private func composeBody(requestId: String) -> ByteBuffer {
        ByteBuffer(data: Data(
            #"{"to":"alice@example.com","subject":"s","body":"b","requestId":"\#(requestId)"}"#.utf8
        ))
    }

    private func makeRouter(
        db: LagoonDB,
        provider: any MailProvider
    ) -> Router<BasicRequestContext> {
        let router = Router()
        MessageRoutes.register(
            on: router, db: db, logger: self.logger, makeProvider: { _ in provider }
        )
        return router
    }

    private func makeAccount() -> Account {
        Account(
            id: UUID(),
            provider: .qq,
            oauthUser: "send-\(UUID().uuidString)",
            email: "send-\(UUID().uuidString)@example.com",
            credentials: nil,
            isActive: false
        )
    }

    private func seed(_ account: Account, db: LagoonDB) async throws {
        try await AccountStore.upsert(account, credentials: Data([1, 2, 3]), db: db)
    }
}

/// GRDB's pool is safe to use from any thread; `LagoonDB` simply does not
/// advertise it, so the test hands it to a task group through this box.
private struct SharedDB: @unchecked Sendable {
    let db: LagoonDB
}

/// A mail provider whose `send` can be parked, failed, and counted.
///
/// The send gate is what makes the concurrency test possible: the first
/// request has to be *inside* the provider when the second one arrives,
/// otherwise the two never overlap and the race cannot happen.
actor GatedMailProvider: MailProvider {
    let kind: MailProviderKind = .qq

    private var sendGate: RaceGate?
    private var sendResult: Result<String?, MailError> = .success("<sent@example.com>")
    private var bodyError: MailError?
    /// How many times `send` was entered — attempts, not deliveries.
    private(set) var sendAttempts = 0
    /// The messages that actually went out.
    private(set) var deliveredOutbounds: [OutboundMessage] = []

    func setSendGate(_ gate: RaceGate?) {
        sendGate = gate
    }

    func setSendResult(_ result: Result<String?, MailError>) {
        sendResult = result
    }

    func setBodyError(_ error: MailError?) {
        bodyError = error
    }

    func send(_ outbound: OutboundMessage) async throws -> String? {
        sendAttempts += 1
        if let sendGate { await sendGate.hold() }
        let result = try sendResult.get()
        deliveredOutbounds.append(outbound)
        return result
    }

    // MARK: - The rest of the protocol: not exercised by these tests.

    func capabilities() async -> MailCapabilities? {
        MailCapabilities(archiveFolder: false, idle: false, move: false, serverSnippet: false)
    }

    func pullChanges(after cursor: MailSyncState, waitUpTo: Duration) async throws -> MailChangeSet {
        MailChangeSet(upserts: [], resetRequired: false, cursor: cursor)
    }

    func fetchBody(remoteId: String) async throws -> FetchedBody {
        if let bodyError { throw bodyError }
        return FetchedBody(text: "", html: nil, attachments: [], hasMore: false)
    }

    func fetchAttachment(remoteId: String, attachmentId: String) async throws -> FetchedAttachmentBytes {
        throw AttachmentError.notFound
    }

    func fetchRawMessage(remoteId: String) async throws -> Data { Data() }
    func fetchRawHeaderValues(remoteId: String) async throws -> [String: String] { [:] }
    func setRead(remoteId: String, isRead: Bool) async throws {}
    func archive(remoteId: String) async throws {}
    func unarchive(remoteId: String) async throws {}
    func trash(remoteId: String) async throws {}
    func restoreFromTrash(remoteId: String) async throws {}
    func permanentlyDelete(remoteId: String) async throws {}
    func emptyTrash() async throws {}
    func listFolders() async throws -> [MailFolder] { [] }
    func move(remoteId: String, to folder: String, createIfMissing: Bool) async throws -> Bool { false }
    func listSent(limit: Int) async throws -> [MessageHeader] { [] }
    func probe() async throws {}
}
