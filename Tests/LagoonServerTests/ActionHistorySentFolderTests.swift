import Foundation
import Logging
import XCTest
import Hummingbird
import HummingbirdTesting
import NIOCore
import GRDB
@testable import LagoonServer
@testable import LagoonKit

/// The history must only say what Lagoon did.
///
/// ## What was wrong
///
/// A reply sent from *another* client — the webmail on the phone, another
/// mail app — is harvested from the Sent folder during sync and recorded as
/// a `send` action with a `sentFolder` marker. It is a **signal** ("this
/// thread was answered"), not an action Lagoon took.
///
/// The time-saved report already knew that and excluded those rows. The
/// "最近操作" panel did not: its query filtered `send` rows only by status,
/// and a `sentFolder` row has no status at all, so it passed the filter and
/// showed up in the list titled 「发送邮件」. The user reads that as "Lagoon
/// sent this", and it never did.
///
/// The count was wrong in the same way, and worse: "还有 N 条" counted rows
/// the list would never show.
///
/// ## What these tests pin
///
/// * a `sentFolder` row is not in the page;
/// * a `sentFolder` row is not in the count;
/// * a `send` row Lagoon really wrote is still there — the filter is not a
///   blanket "hide sends";
/// * a failed send is still hidden.
final class ActionHistorySentFolderTests: XCTestCase {
    private static let logger = Logger(label: "action-sent-folder-tests")

    private let account = Account(
        id: UUID(),
        provider: .qq,
        oauthUser: "sent-folder-\(UUID().uuidString)",
        email: "sent-folder-\(UUID().uuidString)@example.com",
        credentials: nil
    )

    // MARK: - The signal is not an action

    /// A reply sent elsewhere must not appear in the history, and must not
    /// be counted either.
    func test_crossClientReplySignal_isNeitherListedNorCounted() async throws {
        try await TestDatabase.withConnection { db in
            try await seedAccount(db)
            let realSend = try await record(.send, payload: ["remoteId": "m-1"], db: db)
            let crossClient = try await record(
                .send, payload: ["remoteId": "m-2", "sentFolder": "true"], db: db
            )
            let failedSend = try await record(
                .send, payload: ["remoteId": "m-3", "status": "failed"], db: db
            )

            let page = try await AIActionStore.page(accountId: account.id, db: db)

            XCTAssertFalse(
                page.actions.contains { $0.id == crossClient.id },
                "a reply sent from another client is not something Lagoon did"
            )
            XCTAssertFalse(
                page.actions.contains { $0.id == failedSend.id },
                "a send that failed never went out"
            )
            XCTAssertTrue(
                page.actions.contains { $0.id == realSend.id },
                "the send Lagoon really made must stay in the history"
            )
            XCTAssertEqual(
                page.totalCount, 1,
                "「还有 N 条」 must count the rows the list can actually show"
            )
        }
    }

    /// The count and the list are two halves of one number. If they disagree
    /// the panel says "已显示 1/2 条" over a list of one.
    func test_countAndListAgree() async throws {
        try await TestDatabase.withConnection { db in
            try await seedAccount(db)
            for index in 0..<5 {
                _ = try await record(.archive, payload: ["remoteId": "a-\(index)"], db: db)
            }
            _ = try await record(.send, payload: ["remoteId": "s-1", "sentFolder": "true"], db: db)

            let page = try await AIActionStore.page(accountId: account.id, db: db)

            XCTAssertEqual(page.actions.count, 5)
            XCTAssertEqual(
                page.totalCount, page.actions.count,
                "the total must describe the same set the page shows"
            )
        }
    }

    /// The whole history endpoint, not just the store: the panel reads
    /// `GET /api/actions`.
    func test_historyEndpoint_hidesTheSignal() async throws {
        try await TestDatabase.withConnection { db in
            try await seedAccount(db)
            let crossClient = try await record(
                .send, payload: ["remoteId": "m-2", "sentFolder": "true"], db: db
            )

            let app = makeApp(db: db)
            let body = try await get(app, "/api/actions?accountId=\(account.id.uuidString)")

            XCTAssertEqual(body.status, .ok)
            let decoded = try decode(body.data)
            XCTAssertFalse(
                decoded.actions.contains { $0.id == crossClient.id },
                "the history panel must not show a cross-client reply as Lagoon's send"
            )
            XCTAssertEqual(decoded.totalCount, 0)
        }
    }

    // MARK: - Harness

    private func seedAccount(_ db: LagoonDB) async throws {
        try await AccountStore.upsert(account, credentials: Data([1, 2, 3]), db: db)
    }

    @discardableResult
    private func record(
        _ kind: AIActionKind,
        payload: [String: String],
        db: LagoonDB
    ) async throws -> AIAction {
        try await AIActionStore.record(
            accountId: account.id, kind: kind, payload: payload, db: db
        )
    }

    private func makeApp(db: LagoonDB) -> Application<RouterResponder<BasicRequestContext>> {
        let router = Router<BasicRequestContext>()
        ActionsRoutes.register(
            on: router,
            db: db,
            logger: Self.logger,
            makeProvider: { _ in nil }
        )
        return Application(router: router)
    }

    private func get(
        _ app: Application<RouterResponder<BasicRequestContext>>,
        _ path: String
    ) async throws -> (status: HTTPResponse.Status, data: Data) {
        let box = Captured<(HTTPResponse.Status, Data)?>(nil)
        try await app.test(.router) { client in
            try await client.execute(uri: path, method: .get) { response in
                box.value = (response.status, Data(buffer: response.body))
            }
        }
        let value = try XCTUnwrap(box.value, "the route answered nothing")
        return (value.0, value.1)
    }

    private func decode(_ data: Data) throws -> AIActionListResponse {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AIActionListResponse.self, from: data)
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
