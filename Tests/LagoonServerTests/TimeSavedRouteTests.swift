import XCTest
import Logging
import Hummingbird
import PostgresNIO
import LagoonKit
@testable import LagoonServer

/// Covers the M1-finale additions (spec 2026-09-19):
/// - `GET /api/time-saved` aggregation (undo exclusion, window split, byDay),
/// - reply detection: a recorded send action moves the original message out
///   of "needs reply" in `GET /api/briefing`.
final class TimeSavedRouteTests: XCTestCase {
    private let testLogger = Logger(label: "time-saved-tests")

    // MARK: - Helpers

    private func makeAccount(email: String) -> Account {
        Account(
            id: UUID(),
            provider: .gmail,
            oauthUser: "route-\(UUID().uuidString)",
            email: email,
            credentials: nil,
            isActive: false
        )
    }

    private func makeHeader(accountId: UUID, remoteId: String, from: String) -> MessageHeader {
        MessageHeader(
            id: UUID(),
            accountId: accountId,
            remoteId: remoteId,
            threadId: "thread-\(remoteId)",
            fromAddress: from,
            fromName: nil,
            subject: "subject \(remoteId)",
            snippet: nil,
            receivedAt: Date(),
            isRead: false,
            isArchived: false
        )
    }

    private func cleanup(accountId: UUID) -> @Sendable (PostgresConnection) async -> Void {
        { conn in
            try? await TestDatabase.deleteMessages(accountId: accountId, db: conn)
            try? await TestDatabase.deleteAccount(id: accountId, db: conn)
        }
    }

    private static func iso8601Decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // MARK: - Time-saved aggregation

    /// Two archives (one undone), one send, one unsubscribe → today and week
    /// windows count only what stuck; the byDay breakdown is week-only.
    func test_timeSaved_aggregatesExcludesUndoneAndSplitsWindows() async throws {
        let account = makeAccount(email: "ts-\(UUID().uuidString)@example.com")

        try await TestDatabase.withConnection(cleanup: cleanup(accountId: account.id)) { conn in
            try await AccountStore.upsert(account, credentials: Data([1, 2, 3]), db: conn)

            let archivedA = try await AIActionStore.record(
                accountId: account.id, kind: .archive,
                payload: ["remoteId": "a-\(UUID())"], db: conn
            )
            let archivedUndone = try await AIActionStore.record(
                accountId: account.id, kind: .archive,
                payload: ["remoteId": "a-\(UUID())"], db: conn
            )
            _ = try await AIActionStore.record(
                accountId: account.id, kind: .undo,
                payload: ["undoOf": "\(archivedUndone.id)"], db: conn
            )
            _ = try await AIActionStore.record(
                accountId: account.id, kind: .send,
                payload: ["remoteId": "r-\(UUID())", "to": "alice@example.com"], db: conn
            )
            _ = try await AIActionStore.record(
                accountId: account.id, kind: .unsubscribe,
                payload: ["remoteId": "u-\(UUID())"], db: conn
            )
            // An action from before the week window must not surface anywhere.
            let stale = try await AIActionStore.record(
                accountId: account.id, kind: .archive,
                payload: ["remoteId": "old-\(UUID())"], db: conn
            )
            _ = try await conn.query(
                "UPDATE ai_actions SET created_at = now() - interval '9 days' WHERE id = $1",
                [PostgresData(int64: stale.id)]
            ).get()

            let app = Application(router: Self.router(db: conn))
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/api/time-saved?accountId=\(account.id.uuidString)",
                    method: .get
                ) { response in
                    XCTAssertEqual(response.status, .ok)
                    let report = try Self.iso8601Decoder().decode(
                        TimeSavedReport.self,
                        from: Data(buffer: response.body)
                    )
                    // archive(0.5) + send(2) + unsubscribe(2); the undone
                    // archive and the 9-day-old archive are excluded.
                    XCTAssertEqual(report.today.minutesSaved, 4.5)
                    XCTAssertEqual(report.today.messagesHandled, 3)
                    XCTAssertEqual(report.today.draftsSent, 1)
                    XCTAssertEqual(report.today.unsubscribed, 1)
                    XCTAssertEqual(report.week.minutesSaved, 4.5)
                    XCTAssertEqual(report.week.messagesHandled, 3)
                    XCTAssertFalse(report.week.byDay.isEmpty, "the week window carries a per-day breakdown")
                    XCTAssertTrue(report.today.byDay.isEmpty, "the today window has no breakdown")
                }
            }
        }
    }

    /// An account with no actions reports all-zero windows instead of 404.
    func test_timeSaved_emptyAccount_returnsZeroWindows() async throws {
        let account = makeAccount(email: "ts-\(UUID().uuidString)@example.com")

        try await TestDatabase.withConnection(cleanup: cleanup(accountId: account.id)) { conn in
            try await AccountStore.upsert(account, credentials: Data([1, 2, 3]), db: conn)
            let app = Application(router: Self.router(db: conn))
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/api/time-saved?accountId=\(account.id.uuidString)",
                    method: .get
                ) { response in
                    XCTAssertEqual(response.status, .ok)
                    let report = try Self.iso8601Decoder().decode(
                        TimeSavedReport.self,
                        from: Data(buffer: response.body)
                    )
                    XCTAssertTrue(report.today.isEmpty)
                    XCTAssertTrue(report.week.isEmpty)
                }
            }
        }
    }

    func test_timeSaved_malformedAccountId_returns400() async throws {
        try await TestDatabase.withConnection { conn in
            let app = Application(router: Self.router(db: conn))
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/api/time-saved?accountId=not-a-uuid",
                    method: .get
                ) { response in
                    XCTAssertEqual(response.status, .badRequest)
                }
            }
        }
    }

    // MARK: - Reply detection end to end

    /// A send action naming a message's remoteId moves that message from
    /// "needs reply" to safe-to-archive with the `replied` reason; an
    /// untouched message keeps its old grouping.
    func test_briefing_recordedReply_movesMessageOutOfNeedsReply() async throws {
        let account = makeAccount(email: "ts-\(UUID().uuidString)@example.com")

        try await TestDatabase.withConnection(cleanup: cleanup(accountId: account.id)) { conn in
            try await AccountStore.upsert(account, credentials: Data([1, 2, 3]), db: conn)

            let replied = makeHeader(accountId: account.id, remoteId: "replied-\(UUID())", from: "alice@example.com")
            let fresh = makeHeader(accountId: account.id, remoteId: "fresh-\(UUID())", from: "bob@example.com")
            for header in [replied, fresh] {
                try await MessageStore.upsert(header, db: conn)
            }
            _ = try await AIActionStore.record(
                accountId: account.id, kind: .send,
                payload: ["remoteId": replied.remoteId, "to": "alice@example.com"], db: conn
            )
            // A compose send carries no remoteId and must not mark anything.
            _ = try await AIActionStore.record(
                accountId: account.id, kind: .send,
                payload: ["to": "carol@example.com", "type": "compose"], db: conn
            )

            let router = Router()
            BriefingRoutes.register(on: router, db: conn, logger: testLogger)
            let app = Application(router: router)
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/api/briefing?accountId=\(account.id.uuidString)",
                    method: .get
                ) { response in
                    XCTAssertEqual(response.status, .ok)
                    let decoded = try Self.iso8601Decoder().decode(
                        BriefingResponse.self,
                        from: Data(buffer: response.body)
                    )
                    var byRemoteId: [String: BriefingItem] = [:]
                    for item in decoded.items { byRemoteId[item.message.remoteId] = item }
                    XCTAssertEqual(byRemoteId[replied.remoteId]?.group, .safeToArchive)
                    XCTAssertEqual(byRemoteId[replied.remoteId]?.reasonCode, BriefingReason.replied.rawValue)
                    XCTAssertEqual(byRemoteId[fresh.remoteId]?.group, .needsReply)
                }
            }
        }
    }

    // MARK: - Router

    private static func router(db: PostgresConnection) -> Router<BasicRequestContext> {
        let router = Router()
        TimeSavedRoutes.register(
            on: router,
            db: db,
            logger: Logger(label: "time-saved-tests")
        )
        return router
    }
}
