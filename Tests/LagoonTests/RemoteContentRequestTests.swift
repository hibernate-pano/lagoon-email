import XCTest
import Network
import WebKit
@testable import Lagoon

/// "Opening a message is not a read receipt" has to mean *the request never
/// leaves*.
///
/// The existing tests watch the pixel fail to load — which is the wrong
/// half. A pixel that errors still told the sender the message was opened,
/// because the request went out and only the *answer* was missing. So the
/// assertion here is about the request, and the only way to see a request
/// is to be the server: a local HTTP listener on loopback that records what
/// arrives.
///
/// The control matters as much as the assertion. Without the rule list the
/// very same document *does* produce requests; if it did not, the harness
/// would be blind and the "no request" assertion would be passing for the
/// wrong reason.
final class RemoteContentRequestTests: XCTestCase {

    /// A mail that carries a remote image — the tracking pixel, exactly.
    ///
    /// The `fetch` is there so the control has a second, initiator-driven
    /// request to look for: an image load can be deferred by the layout
    /// engine, and a deferred load is not a request — which would make the
    /// control pass for the wrong reason too.
    private static func document(imageURL: String) -> String {
        """
        <html><body>
          <img id="pixel" src="\(imageURL)">
          <script>
            window.__lagoonFetch = "pending";
            fetch("\(imageURL)")
              .then(function () { window.__lagoonFetch = "arrived"; })
              .catch(function (e) { window.__lagoonFetch = "failed"; });
          </script>
        </body></html>
        """
    }

    @MainActor
    func test_remoteContentIsNeverRequested() async throws {
        let server = try await CountingHTTPServer.start()
        defer { server.stop() }
        let url = "http://127.0.0.1:\(server.port)/pixel.png"

        // Control: no rule list, so the WebView fetches the image for real.
        // This proves the harness can see a request at all. The WebView
        // lives in its own function so that it is gone — and cannot fire a
        // late request into the production phase below.
        await Self.runControl(document: Self.document(imageURL: url), server: server)
        XCTAssertTrue(
            server.hasRequest,
            "sanity: the harness must be able to observe a request — otherwise "
                + "the blocked assertion below would pass for the wrong reason"
        )
        let before = server.requestCount

        // The production wiring: the remote-content rule list is on the
        // WebView, and the very same document must produce no request.
        let compiled = await HTMLMessageView.remoteContentRuleList()
        let rules = try XCTUnwrap(
            compiled,
            "the remote-content rule list failed to compile, so nothing is blocked"
        )
        let webView = WKWebView(frame: .init(x: 0, y: 0, width: 400, height: 300))
        webView.configuration.userContentController.add(rules)
        // `loadHTMLString` is the plain Objective-C method — WebKit has no
        // async overlay for it, so the `await` here was a no-op that the
        // compiler rightly flagged. The load itself is asynchronous; the
        // pump below is what waits for it.
        webView.loadHTMLString(Self.document(imageURL: url), baseURL: nil)
        // At least as long as the control needed, and then some: a request
        // that arrives late would still be a request.
        await Self.run(for: 12, webView: webView, server: server)

        XCTAssertEqual(
            server.requestCount, before,
            "the remote image was requested: opening a message is acting as a "
                + "read receipt, and the sender learns the IP and the open time"
        )
    }

    /// The navigation delegate has to be a *true* witness for the SDK's
    /// requirement, not a near match.
    ///
    /// A near match compiles — with a warning — and is dispatched today
    /// because the Objective-C selector still lines up. But nothing in the
    /// language promises it: the day the SDK changes the requirement, the
    /// privacy rule would stop running and not one behavioural test would
    /// fail. The compiler is the only thing that can catch that, and it
    /// only speaks up as a warning, so the shape is pinned here.
    ///
    /// The requirement the SDK declares (`WKNavigationDelegate.h`) puts
    /// `WK_SWIFT_UI_ACTOR` on the decision-handler block, which Swift
    /// imports as an `@MainActor` closure. Without that annotation on the
    /// implementation the method is a near match — the compiler says so:
    ///
    ///     warning: instance method 'webView(_:decidePolicyFor:decisionHandler:)'
    ///     nearly matches optional requirement ... of protocol 'WKNavigationDelegate'
    ///
    /// so the assertion is that the annotation is there, and that the
    /// *preferences* overload — the one the SDK prefers, and the one that
    /// replaces the older callback entirely — is the one implemented.
    func test_theNavigationDelegateIsARealWitness() throws {
        let source = try ViewSource.read("HTMLMessageView")
        XCTAssertTrue(
            source.contains(
                "decisionHandler: @escaping @MainActor (WKNavigationActionPolicy, WKWebpagePreferences) -> Void"
            ),
            "the decision handler must carry the SDK's @MainActor annotation — without it "
                + "the method is only a near match for the protocol requirement, and nothing "
                + "guarantees WebKit would ever call it"
        )
        XCTAssertTrue(
            source.contains("preferences: WKWebpagePreferences,"),
            "the preferences overload must be the one implemented: the SDK says the older "
                + "decidePolicyFor:decisionHandler: is not called once it is"
        )
        // And the Objective-C entry point WebKit actually sends exists.
        XCTAssertTrue(
            HTMLMessageView.Coordinator.instancesRespond(
                to: NSSelectorFromString(
                    "webView:decidePolicyForNavigationAction:preferences:decisionHandler:"
                )
            ),
            "the delegate must implement the selector WebKit sends"
        )
    }

    // MARK: - Driving the WebView

    /// Loads the document in a WebView with no rule list and waits for the
    /// requests to arrive.
    ///
    /// The WebView is created and dropped here, so that the production
    /// phase cannot be polluted by a late request from the control.
    @MainActor
    private static func runControl(document: String, server: CountingHTTPServer) async {
        let webView = WKWebView(frame: .init(x: 0, y: 0, width: 400, height: 300))
        webView.loadHTMLString(document, baseURL: nil)
        // Two requests: the image and the script-initiated fetch.
        await Self.run(for: 20, webView: webView, server: server, until: { server.requestCount >= 2 })
    }

    /// Pumps the WebView for `seconds`, or until `until` is true.
    ///
    /// Asking the page a question is what makes the WebView do its work:
    /// an image load is deferred until the document is laid out, and a
    /// deferred load never becomes a request — which would make the
    /// control pass for the wrong reason.
    @MainActor
    private static func run(
        for seconds: TimeInterval,
        webView: WKWebView,
        server: CountingHTTPServer,
        until: () -> Bool = { false }
    ) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            Self.pumpRunLoop(for: 0.1)
            _ = try? await webView.evaluateJavaScript("1")
            if until() { return }
        }
    }

    /// Runs the main run loop for `interval` seconds.
    ///
    /// The WebView only fetches while its run loop turns, and `run(_:before:)`
    /// is unavailable from an async context — so the pumping lives in a
    /// synchronous main-actor function and the async callers just call it.
    @MainActor
    private static func pumpRunLoop(for interval: TimeInterval) {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(interval))
    }
}

/// A local HTTP server that records the requests it receives.
///
/// Loopback, so the app's ATS configuration does not stand between the test
/// and the request it is trying to observe.
final class CountingHTTPServer {
    private let listener: NWListener
    private let lock = NSLock()
    private var requestLines: [String] = []

    /// The HTTP request lines the server actually received.
    var requests: [String] {
        lock.lock()
        defer { lock.unlock() }
        return requestLines
    }

    var requestCount: Int { requests.count }

    /// Whether a request ever reached the server.
    var hasRequest: Bool { requestCount > 0 }

    var port: UInt16 { listener.port?.rawValue ?? 0 }

    private init(listener: NWListener) {
        self.listener = listener
    }

    /// Binds an ephemeral port and starts accepting.
    static func start() async throws -> CountingHTTPServer {
        let listener = try NWListener(using: .tcp, on: .any)
        let server = CountingHTTPServer(listener: listener)
        listener.newConnectionHandler = { connection in
            // The listener hands over a connection that has not been started
            // yet: without this the receive below never fires and the
            // request is never seen — the harness would be blind, and the
            // "no request" assertion would pass for the wrong reason.
            connection.start(queue: DispatchQueue(label: "lagoon.tests.counting-http.connection"))
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                // The first chunk carries the request line. A connection that
                // is opened and then dropped without a request is not a
                // request, and must not be counted as one.
                if let data, let text = String(data: data, encoding: .utf8),
                   let line = text.split(separator: "\r\n").first {
                    server.noteRequest(String(line))
                }
                // Answer with a 1-byte body: the content is irrelevant, the
                // arrival is the point. A 404 would be enough too — the
                // request is what the sender learns from.
                let response = "HTTP/1.1 200 OK\r\n"
                    + "Content-Type: image/gif\r\n"
                    + "Content-Length: 1\r\n"
                    + "Connection: close\r\n\r\nG"
                connection.send(
                    content: Data(response.utf8),
                    completion: .contentProcessed { _ in connection.cancel() }
                )
            }
        }
        listener.start(queue: DispatchQueue(label: "lagoon.tests.counting-http"))
        // The port is known once the listener is bound. It reads back as 0
        // for a moment after `start`, so waiting for a non-zero value is
        // the only way to be sure the bound port is the real one.
        let deadline = Date().addingTimeInterval(5)
        while (listener.port?.rawValue ?? 0) == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard (listener.port?.rawValue ?? 0) > 0 else {
            listener.cancel()
            throw NSError(
                domain: "CountingHTTPServer", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "the listener never bound a port"]
            )
        }
        return server
    }

    private func noteRequest(_ line: String) {
        lock.lock()
        requestLines.append(line)
        lock.unlock()
    }

    func stop() {
        listener.cancel()
    }
}
