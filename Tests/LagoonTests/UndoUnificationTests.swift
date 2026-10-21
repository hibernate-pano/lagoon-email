import Foundation
import XCTest
import SwiftUI
import LagoonKit
@testable import Lagoon

/// P2-11: the undo toast and the action-history panel must never disagree.
///
/// ## What was wrong
///
/// The panel called `api.undoAction` directly, so `UndoController.current` —
/// the toast — was untouched by an undo performed from the panel. A user
/// could undo a three-minute-old archive from the history and still see
/// "已归档 · 撤销" at the bottom of the window, offering to undo a *different*
/// action. Two undo surfaces, two states.
///
/// The reverse direction was just as bad: an undo fired from the toast left
/// the panel's row in place, still offering a button the server would answer
/// with 409.
///
/// ## What these tests pin
///
/// * the panel has no API call of its own — it goes through the controller;
/// * the controller has one method that undoes a named action, and it
///   retires the toast;
/// * a successful undo from **either** side posts `.lagoonDidUndo` carrying
///   the ids that actually reversed, so the panel can retire the right rows;
/// * the panel listens, and removes those rows.
///
/// The first three are executable. The wiring assertions are source-level:
/// a SwiftUI body is not runnable in a unit test, and the failure they guard
/// against is a deleted line, not a wrong computation.
@MainActor
final class UndoUnificationTests: XCTestCase {
    private let service = "lagoon.accountId.undo-unify-test"
    private let baseURL = URL(string: "http://127.0.0.1:8080")!
    /// `UndoController` holds `AccountStore` weakly; the test owns it.
    private var store: AccountStore?

    override func setUp() {
        super.setUp()
        StubURLProtocol.setHandler(nil)
        try? KeychainStore.clear(service: service)
    }

    nonisolated override func tearDown() {
        try? KeychainStore.clear(service: service)
        super.tearDown()
    }

    private func makeClient() -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return APIClient(baseURL: baseURL, session: URLSession(configuration: configuration))
    }

    private func makeController() async throws -> (UndoController, UUID) {
        let accountId = UUID()
        let store = AccountStore(service: service)
        try await store.set(accountId: accountId)
        self.store = store
        let controller = UndoController(api: makeClient())
        controller.bind(store)
        return (controller, accountId)
    }

    private func stubOK() {
        StubURLProtocol.setHandler { request in
            let response = HTTPURLResponse(
                url: request.url ?? self.baseURL,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data("{}".utf8))
        }
    }

    // MARK: - One owner of the undo state

    /// The panel must use the controller, not the API client.
    ///
    /// This is the whole of P2-11 spelled as an assertion. If the panel ever
    /// grows its own `api.undoAction` call again, the toast stops being the
    /// single source of truth and the two surfaces can contradict each
    /// other again — silently, because both calls succeed.
    func test_thePanelUndoesThroughTheController() throws {
        let source = try ViewSource.read("ActionHistorySheet")
        XCTAssertTrue(
            source.contains("@EnvironmentObject private var undo: UndoController"),
            "the panel must receive the undo controller, or it has no single owner to call"
        )
        XCTAssertTrue(
            source.contains("undo.undo(actionId:"),
            "an undo from the panel must go through the controller that owns the toast"
        )
        XCTAssertFalse(
            source.contains("api.undoAction"),
            "the panel must not call the undo route directly — two entry points, two states"
        )
    }

    /// Undoing a named action retires the toast.
    ///
    /// The toast said "已归档" about a *different* action. After this call
    /// that sentence is false, so it has to go — before the network round
    /// trip, for the same reason `undo()` clears it first: a second click
    /// during the await must not find a toast to fire against.
    func test_undoingANamedActionRetiresWhateverToastIsShowing() async throws {
        stubOK()
        let (controller, _) = try await makeController()
        controller.show(UndoItem(id: 555, message: "已归档", systemImage: "tray"))
        XCTAssertNotNil(controller.current)

        let result = await controller.undo(actionId: 42)

        XCTAssertEqual(result, .undone)
        XCTAssertNil(
            controller.current,
            "an undo from the panel must clear the toast — otherwise the window keeps claiming a different undo is pending"
        )
    }

    /// The named undo hits the single-action route for exactly that id.
    /// Not the newest, not a batch: the row the user clicked.
    func test_undoingANamedActionReversesExactlyThatId() async throws {
        stubOK()
        let (controller, accountId) = try await makeController()

        _ = await controller.undo(actionId: 9001)

        let calls = StubURLProtocol.capturedRequests.filter {
            $0.url?.path.hasSuffix("/undo") == true
        }
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.url?.path, "/api/actions/9001/undo")
        XCTAssertEqual(calls.first?.url?.query, "accountId=\(accountId.uuidString)")
        XCTAssertTrue(
            StubURLProtocol.capturedRequests
                .filter { $0.url?.path == "/api/actions/undo-bulk" }.isEmpty,
            "one row is one action; the panel must not reverse a batch the row never mentioned"
        )
    }

    /// A failed named undo must be reported to the caller **without** being
    /// parked in `errorMessage`.
    ///
    /// `RootView` renders `errorMessage` with a retry wired to
    /// `undoLatest()`, which undoes the newest action — not the one the user
    /// clicked. Putting this failure there would give the panel a retry
    /// button that silently reverses something else.
    func test_aFailedNamedUndoIsReturnedToTheCallerAndNotParkedInTheGlobalError() async throws {
        StubURLProtocol.setHandler { request in
            let response = HTTPURLResponse(
                url: request.url ?? self.baseURL,
                statusCode: 409,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"error":"already-undone"}"#.utf8))
        }
        let (controller, _) = try await makeController()

        let result = await controller.undo(actionId: 7)

        guard case .failed(let message, _) = result else {
            return XCTFail("a 409 must come back as a failure, not as success")
        }
        XCTAssertFalse(message.isEmpty, "the failure must carry something to show")
        XCTAssertNil(
            controller.errorMessage,
            "the global undo error retries `undoLatest()`; a panel retry must not mean a different action"
        )
    }

    // MARK: - Both directions converge

    /// A successful undo posts the ids that actually reversed.
    ///
    /// The panel holds rows; without the ids it can only re-fetch, which
    /// discards its loaded pages. With them it retires exactly the rows that
    /// are gone.
    func test_aSuccessfulUndoAnnouncesTheReversedIds() async throws {
        stubOK()
        let (controller, _) = try await makeController()
        controller.show(UndoItem(id: 77, message: "已归档", systemImage: "tray"))

        let expectation = expectation(description: "lagoonDidUndo carries the id")
        let token = NotificationCenter.default.addObserver(
            forName: .lagoonDidUndo, object: nil, queue: nil
        ) { note in
            XCTAssertEqual(note.object as? [Int64], [77])
            expectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        await controller.undo()
        await fulfillment(of: [expectation], timeout: 2)
    }

    /// A **partial** bulk undo announces only the rows that reversed.
    ///
    /// Announcing all fifty ids would make the panel drop rows that are
    /// still undoable — the user would then have no way back to them from
    /// the list, while the server would still accept the undo.
    func test_aPartialBulkUndoAnnouncesOnlyTheReversedIds() async throws {
        let body = try JSONEncoder().encode(
            UndoBulkResponse(
                items: [
                    UndoBulkItem(actionId: 1, ok: true),
                    UndoBulkItem(actionId: 2, ok: false, errorCode: "already-undone"),
                    UndoBulkItem(actionId: 3, ok: true),
                ],
                undone: 2
            )
        )
        StubURLProtocol.setHandler { request in
            let response = HTTPURLResponse(
                url: request.url ?? self.baseURL,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, body)
        }
        let (controller, _) = try await makeController()
        controller.show(UndoItem(
            id: 1, message: "已归档 3 封", systemImage: "tray", extraIds: [2, 3]
        ))

        let expectation = expectation(description: "lagoonDidUndo carries only reversed ids")
        let token = NotificationCenter.default.addObserver(
            forName: .lagoonDidUndo, object: nil, queue: nil
        ) { note in
            XCTAssertEqual(
                Set(note.object as? [Int64] ?? []), [1, 3],
                "row 2 did not reverse; the panel must keep offering it"
            )
            expectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        await controller.undo()
        await fulfillment(of: [expectation], timeout: 2)
    }

    /// The panel listens for the notification and removes those rows.
    ///
    /// Source-level: the receiver lives in a SwiftUI body. The failure it
    /// guards is a deleted line, which no runtime test here can reach.
    func test_thePanelRetiresRowsAnnouncedByAnUndoElsewhere() throws {
        let source = try ViewSource.read("ActionHistorySheet")
        XCTAssertTrue(
            source.contains(".onReceive(NotificationCenter.default.publisher(for: .lagoonDidUndo))"),
            "an undo from the toast must remove the row here, or the panel keeps offering a 409"
        )
        XCTAssertTrue(
            source.contains("actions.removeAll { ids.contains($0.id) }"),
            "the receiver must remove exactly the announced rows"
        )
    }

    // MARK: - The panel's copy

    /// The panel must not call an expired row "不可撤销".
    ///
    /// `notUndoable` is a fact about the *kind* of action. An expired archive
    /// was reversible — time closed the window — and the user guide promises
    /// the panel shows that state as 「已过期」. Telling the user the product
    /// never could undo it is a different, falser statement.
    func test_expiredRowsAreLabelledExpiredNotUnreversible() throws {
        let source = try ViewSource.read("ActionHistorySheet")
        XCTAssertTrue(
            source.contains("l10n.actionExpired"),
            "the panel must have an expired label of its own"
        )
        let zh = L10n(language: .zhHans)
        XCTAssertNotEqual(
            zh.actionExpired, zh.notUndoable,
            "expired and never-reversible are different facts and need different words"
        )
        let en = L10n(language: .english)
        XCTAssertNotEqual(en.actionExpired, en.notUndoable)
    }
}
