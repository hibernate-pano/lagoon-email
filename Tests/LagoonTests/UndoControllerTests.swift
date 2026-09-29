import Foundation
import XCTest
import LagoonKit
@testable import Lagoon

/// The undo toast is the product's headline promise — "every action is fully
/// undoable" — and it had no test at all. These cover the three things that
/// can silently break it: the wrong action id going to the server, a double tap
/// firing two undos, and a server rejection leaving the user with no way back.
@MainActor
final class UndoControllerTests: XCTestCase {
    private let service = "lagoon.accountId.undo-test"
    private let baseURL = URL(string: "http://127.0.0.1:8080")!
    /// `UndoController` holds its `AccountStore` **weakly**, so a store that
    /// only lives in a local would be deallocated the moment the helper
    /// returned and every `undo()` would bail on a nil account. Held here for
    /// the test's lifetime instead.
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

    private func stub(status: Int, body: Data = Data("{}".utf8)) {
        StubURLProtocol.setHandler { request in
            let response = HTTPURLResponse(
                url: request.url ?? self.baseURL,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, body)
        }
    }

    private func makeController() throws -> (UndoController, UUID) {
        let accountId = UUID()
        let store = AccountStore(service: service)
        try store.set(accountId: accountId)
        self.store = store
        let controller = UndoController(api: makeClient())
        controller.bind(store)
        return (controller, accountId)
    }

    /// The toast carries the id the *server* returned. If the view ever
    /// invents one, or reuses a stale one, undo silently reverts the wrong
    /// action — the worst failure this feature can have, because it looks
    /// like it worked.
    func test_undo_postsExactlyTheIdFromTheToast() async throws {
        stub(status: 200)
        let (controller, accountId) = try makeController()
        controller.show(UndoItem(id: 4242, message: "已归档", systemImage: "tray"))

        await controller.undo()

        let undoCalls = StubURLProtocol.capturedRequests.filter {
            $0.url?.path.hasSuffix("/undo") == true
        }
        XCTAssertEqual(undoCalls.count, 1)
        XCTAssertEqual(undoCalls.first?.httpMethod, "POST")
        XCTAssertEqual(
            undoCalls.first?.url?.path, "/api/actions/4242/undo",
            "the toast's id must reach the server verbatim"
        )
        XCTAssertEqual(
            undoCalls.first?.url?.query,
            "accountId=\(accountId.uuidString)",
            "undo must be scoped to the signed-in account"
        )
    }

    /// The toast is cleared *before* the await, not after. If it were cleared
    /// afterwards, a second tap during the round trip would fire a second
    /// undo for the same action.
    ///
    /// The stub blocks until the test releases it, so the assertion lands
    /// while `undo()` is provably suspended inside the network call — a
    /// plain `async let` would race and prove nothing.
    func test_undoClearsTheToastBeforeAwaiting() async throws {
        let gate = AsyncGate()
        StubURLProtocol.setHandler { request in
            gate.wait()
            let response = HTTPURLResponse(
                url: request.url ?? self.baseURL,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data("{}".utf8))
        }
        let (controller, _) = try makeController()
        controller.show(UndoItem(id: 7, message: "已归档", systemImage: "tray"))

        let undoing = Task { await controller.undo() }
        await gate.waitUntilEntered()
        XCTAssertNil(
            controller.current,
            "the toast must be gone while the undo is still in flight, or a double tap undoes twice"
        )
        gate.open()
        await undoing.value
    }

    func test_doubleTapFiresExactlyOneUndo() async throws {
        stub(status: 200)
        let (controller, _) = try makeController()
        controller.show(UndoItem(id: 9, message: "已归档", systemImage: "tray"))

        async let first: Void = controller.undo()
        async let second: Void = controller.undo()
        _ = await (first, second)

        XCTAssertEqual(
            StubURLProtocol.capturedRequests.filter { $0.url?.path.hasSuffix("/undo") == true }.count,
            1,
            "the second tap found no toast and must be a no-op"
        )
    }

    /// A rejected undo must not vanish silently: the action is still done and
    /// the user needs to know it could not be taken back.
    func test_undoFailureSurfacesAnErrorAndKeepsTheActionUndone() async throws {
        stub(status: 400, body: Data(#"{"error":"action-expired"}"#.utf8))
        let (controller, _) = try makeController()
        controller.show(UndoItem(id: 11, message: "已归档", systemImage: "tray"))

        await controller.undo()

        XCTAssertNotNil(controller.errorMessage, "a failed undo must not be swallowed")
    }

    /// A terminal action (unsubscribe, send) has no inverse on the server, so
    /// the toast must not offer a button that can only ever fail.
    func test_terminalActionToastOffersNoUndoButton() {
        let terminal = UndoItem(id: 1, message: "已退订", systemImage: "x", undoable: false)
        XCTAssertFalse(terminal.undoable)
        XCTAssertTrue(UndoItem(id: 1, message: "已归档", systemImage: "x").undoable)
    }

    /// ⌘Z is the discoverable path to undo once the toast has gone.
    func test_undoLatestPicksTheNewestUndoableAction() async throws {
        let accountId = UUID()
        // `AIAction` is {id, accountId, kind, payload, createdAt, expiresAt};
        // undoability is derived from `kind` by `isUndoable`, not a wire field.
        // The list is newest-first, which is what `undoLatest` relies on.
        let payload = """
        {"actions":[
          {"id":1,"accountId":"\(accountId.uuidString)","kind":"unsubscribe","payload":{},
           "createdAt":"2026-09-29T11:00:00Z"},
          {"id":3,"accountId":"\(accountId.uuidString)","kind":"archive","payload":{},
           "createdAt":"2026-09-29T10:00:00Z"},
          {"id":2,"accountId":"\(accountId.uuidString)","kind":"archive","payload":{},
           "createdAt":"2026-09-29T09:00:00Z"}
        ]}
        """
        StubURLProtocol.setHandler { request in
            let response = HTTPURLResponse(
                url: request.url ?? self.baseURL,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(payload.utf8))
        }
        let store = AccountStore(service: service)
        try store.set(accountId: accountId)
        self.store = store
        let controller = UndoController(api: makeClient())
        controller.bind(store)

        await controller.undoLatest()

        let undoCalls = StubURLProtocol.capturedRequests.filter {
            $0.url?.path.hasSuffix("/undo") == true
        }
        XCTAssertEqual(undoCalls.count, 1)
        XCTAssertEqual(
            undoCalls.first?.url?.path, "/api/actions/3/undo",
            "newest undoable action wins; a terminal one must be skipped"
        )
    }

    func test_undoLatestWithNoUndoableActionReportsInsteadOfFailing() async throws {
        stub(status: 200, body: Data(#"{"actions":[]}"#.utf8))
        let (controller, _) = try makeController()

        await controller.undoLatest()

        XCTAssertNotNil(controller.errorMessage)
        XCTAssertTrue(
            StubURLProtocol.capturedRequests.allSatisfy { $0.url?.path.hasSuffix("/undo") != true },
            "nothing to undo must not produce an undo call"
        )
    }
}

/// One-shot gate the stub blocks on, so a test can assert about state *while*
/// a request is in flight. Without it, "the toast is cleared before the await"
/// is unobservable: the assertion would race the round trip and pass or fail
/// by luck.
///
/// `NSCondition` rather than a continuation soup: the stub side has to block a
/// real thread (URLProtocol hands it to a delegate queue), and the test side
/// needs to suspend without occupying the main actor.
private final class AsyncGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var opened = false

    /// Blocks the calling thread until `open()`. Called on the stub's queue.
    func wait() {
        condition.lock()
        entered = true
        condition.broadcast()
        while !opened { condition.wait() }
        condition.unlock()
    }

    /// Suspends until the stub has been reached.
    func waitUntilEntered() async {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                self.condition.lock()
                while !self.entered { self.condition.wait() }
                self.condition.unlock()
                continuation.resume()
            }
        }
    }

    func open() {
        condition.lock()
        opened = true
        condition.broadcast()
        condition.unlock()
    }
}
