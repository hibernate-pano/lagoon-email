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

    /// URLSession hands the body to `URLProtocol` as a stream, so body
    /// assertions read whichever form the request carries.
    private func bodyData(of request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
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

    /// A bulk toast must post every id it carries to the bulk endpoint in one
    /// call. If it fell back to the single-action route, ⇧⌘K over an inbox
    /// would reverse one message and silently leave the rest read — the exact
    /// "undo did nothing" failure this endpoint exists to prevent.
    func test_undo_withExtraIds_postsAllOfThemToTheBulkEndpoint() async throws {
        let body = try JSONEncoder().encode(
            UndoBulkResponse(items: [1, 2, 3].map { UndoBulkItem(actionId: $0, ok: true) }, undone: 3)
        )
        stub(status: 200, body: body)
        let (controller, accountId) = try makeController()
        controller.show(UndoItem(
            id: 1, message: "已将 3 封标为已读", systemImage: "envelope.open",
            extraIds: [2, 3]
        ))

        await controller.undo()

        let bulkCalls = StubURLProtocol.capturedRequests.filter {
            $0.url?.path == "/api/actions/undo-bulk"
        }
        XCTAssertEqual(bulkCalls.count, 1, "a bulk toast must hit the bulk endpoint exactly once")
        XCTAssertEqual(bulkCalls.first?.httpMethod, "POST")
        XCTAssertEqual(bulkCalls.first?.url?.query, "accountId=\(accountId.uuidString)")

        let request = try XCTUnwrap(bulkCalls.first)
        let decoded = try JSONDecoder().decode(
            UndoBulkRequest.self, from: try bodyData(of: request)
        )
        XCTAssertEqual(
            Set(decoded.actionIds), [1, 2, 3],
            "every id the toast carries must be reversed, not just the newest"
        )
        // The single-action route must NOT have been used.
        XCTAssertTrue(
            StubURLProtocol.capturedRequests.filter { $0.url?.path.hasSuffix("/undo") == true }.isEmpty,
            "a bulk undo must not also fire a single-action undo"
        )
        XCTAssertNil(controller.errorMessage, "a fully-successful bulk undo reports no error")
    }

    /// A single-item toast keeps using the single-action route. The bulk path
    /// is only for operations that genuinely produced several rows, so an
    /// ordinary archive must not change endpoint.
    func test_undo_withoutExtraIds_keepsUsingTheSingleActionRoute() async throws {
        stub(status: 200)
        let (controller, _) = try makeController()
        controller.show(UndoItem(id: 7, message: "已归档", systemImage: "tray"))

        await controller.undo()

        XCTAssertTrue(
            StubURLProtocol.capturedRequests.contains { $0.url?.path == "/api/actions/7/undo" },
            "a single-action toast must still use the single-action route"
        )
        XCTAssertTrue(
            StubURLProtocol.capturedRequests.filter { $0.url?.path == "/api/actions/undo-bulk" }.isEmpty
        )
    }

    /// A partial bulk result must not be reported as success. Saying "undone"
    /// when 1 of 3 reversed would misstate the mailbox in the one place the
    /// product promises to be honest about state.
    func test_undo_partialBulkResultSurfacesAPartialMessage() async throws {
        let body = try JSONEncoder().encode(
            UndoBulkResponse(
                items: [
                    UndoBulkItem(actionId: 1, ok: true),
                    UndoBulkItem(actionId: 2, ok: false, errorCode: "already-undone"),
                    UndoBulkItem(actionId: 3, ok: false, errorCode: "already-undone"),
                ],
                undone: 1
            )
        )
        stub(status: 200, body: body)
        let (controller, _) = try makeController()
        controller.show(UndoItem(
            id: 1, message: "已将 3 封标为已读", systemImage: "envelope.open",
            extraIds: [2, 3]
        ))

        await controller.undo()

        let message = try XCTUnwrap(
            controller.errorMessage,
            "a partial bulk undo must tell the user it only partly worked"
        )
        XCTAssertTrue(message.contains("1"), "the message should carry the count that succeeded")
    }

    /// ⌘Z while a bulk toast is showing must reverse the whole batch, exactly
    /// like the toast's own Undo button. ⌘Z is bound to `undoLatest()`, which
    /// otherwise falls back to "undo the newest single action" — so without
    /// this, pressing ⇧⌘K then ⌘Z (the natural reaction) would undo one
    /// message of the batch and leave the rest, the same "undo did nothing"
    /// feeling the bulk endpoint exists to prevent. Two entry points to one
    /// visible toast must not disagree.
    func test_undoLatest_withLiveBulkToast_reversesTheWholeBatch() async throws {
        let body = try JSONEncoder().encode(
            UndoBulkResponse(items: [1, 2, 3].map { UndoBulkItem(actionId: $0, ok: true) }, undone: 3)
        )
        stub(status: 200, body: body)
        let (controller, _) = try makeController()
        controller.show(UndoItem(
            id: 1, message: "已将 3 封标为已读", systemImage: "envelope.open",
            extraIds: [2, 3]
        ))

        await controller.undoLatest()

        let bulkCalls = StubURLProtocol.capturedRequests.filter {
            $0.url?.path == "/api/actions/undo-bulk"
        }
        XCTAssertEqual(bulkCalls.count, 1, "⌘Z on a bulk toast must use the bulk endpoint")
        let decoded = try JSONDecoder().decode(
            UndoBulkRequest.self, from: try bodyData(of: XCTUnwrap(bulkCalls.first))
        )
        XCTAssertEqual(Set(decoded.actionIds), [1, 2, 3])
        // It must NOT have fallen back to a single-action undo.
        XCTAssertTrue(
            StubURLProtocol.capturedRequests.filter { $0.url?.path.hasSuffix("/undo") == true }.isEmpty
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
