import XCTest
import AppKit
import SwiftUI
import WebKit
@testable import Lagoon

/// Tests for `HTMLMessageView`'s head-level CSS injection. The CSS makes
/// HTML email lay out fluidly inside the reading column (max-width 100%
/// on tables, word-wrap on body, image scaling) so a sender's hardcoded
/// `<table width="600">` no longer shows as a narrow strip in a wide
/// window. Without this, the bug "body doesn't fill the window" recurs
/// every time the user opens a fixed-width email.
final class HTMLMessageViewTests: XCTestCase {

    /// An email with a `<head>` gets our CSS prepended to it — the
    /// `!important` overrides win against the sender's width rules.
    func test_injectFluidCSS_intoExistingHead() {
        let html = "<html><head><meta charset='utf-8'></head><body>hi</body></html>"
        let out = HTMLMessageView.injectFluidCSS(into: html)
        XCTAssertTrue(out.contains("max-width: 100%"), "fluid CSS missing from output")
        XCTAssertTrue(out.contains("<meta charset='utf-8'>"), "sender head was dropped")
        // The fluid CSS lands inside the sender's head, before the meta tag,
        // so author CSS can still win specificity ties if needed.
        XCTAssertLessThan(
            out.range(of: "max-width: 100%")!.lowerBound,
            out.range(of: "<meta charset='utf-8'>")!.lowerBound
        )
    }

    /// Case-insensitive: real-world HTML is loose with `<HEAD>` / `<Html>`.
    func test_injectFluidCSS_caseInsensitive() {
        let html = "<HTML><HEAD></HEAD><body></body></HTML>"
        let out = HTMLMessageView.injectFluidCSS(into: html)
        XCTAssertTrue(out.contains("max-width: 100%"))
    }

    /// Some emails omit `<head>` entirely — a body-only fragment.
    /// We wrap them in `<html><head>…</head>` so the CSS still applies.
    func test_injectFluidCSS_wrapsHeadlessHTML() {
        let html = "<body><p>just text</p></body>"
        let out = HTMLMessageView.injectFluidCSS(into: html)
        XCTAssertTrue(out.contains("<html"))
        XCTAssertTrue(out.contains("<head>"))
        XCTAssertTrue(out.contains("max-width: 100%"))
        XCTAssertTrue(out.contains("<p>just text</p>"))
    }

    /// No `<html>` at all (the worst senders): we wrap the whole document.
    /// The user's content survives verbatim.
    func test_injectFluidCSS_wrapsFragment() {
        let html = "<p>naked paragraph</p>"
        let out = HTMLMessageView.injectFluidCSS(into: html)
        XCTAssertTrue(out.contains("<html"))
        XCTAssertTrue(out.contains("max-width: 100%"))
        XCTAssertTrue(out.contains("<p>naked paragraph</p>"))
    }

    /// The CSS itself contains the rules we promise the user. If anyone
    /// removes a rule, this test catches it — guarding against silent
    /// regressions that bring back the "body disjointed" bug.
    func test_fluidCSS_containsAllRequiredRules() {
        let css = HTMLMessageView.fluidCSS
        XCTAssertTrue(css.contains("max-width: 100%"))
        XCTAssertTrue(css.contains("word-wrap: break-word"))
        XCTAssertTrue(css.contains("height: auto"), "images must scale, not stay at sender-set height")
        XCTAssertTrue(css.contains("table { max-width: 100%"))
    }

    /// `cid:` resolution and CSS injection cooperate: an email with inline
    /// images gets both the data: replacements AND the fluid layout rules.
    /// (The body width bug and the inline-image bug were fixed in two
    /// separate passes; this test prevents one regressing the other.)
    ///
    /// `guessMimeType(forCid:)` deliberately returns `nil` — the WebView
    /// sniffs MIME from the data URL bytes. So the test asserts a generic
    /// `data:` scheme, not a specific `data:image/png` form.
    func test_injectFluidCSS_preservesCidReplacements() {
        // Tiny PNG bytes — the regex matches the cid prefix; the WebKit
        // MIME sniffer handles the bytes.
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        let html = """
        <html><head></head><body>
        <img src="cid:logo@example.com" />
        </body></html>
        """
        let resolved = HTMLMessageView.resolveCidReferences(
            in: html,
            with: ["logo@example.com": bytes]
        )
        let out = HTMLMessageView.injectFluidCSS(into: resolved)
        XCTAssertTrue(out.contains("data:"), "cid: must be replaced with a data: URL")
        XCTAssertFalse(out.contains("cid:logo@example.com"), "original cid: must be gone")
        XCTAssertTrue(out.contains("max-width: 100%"), "fluid CSS must still be injected")
    }

    // MARK: - Single-scroller contract (PassThroughScrollWebView)

    /// The core guarantee: wheel events pass through to the responder
    /// chain instead of being consumed by the WebView. Guards the pair of
    /// regressions behind "nested scroll box" — gestures bouncing back
    /// after a measurement hiccup, and gestures silently swallowed.
    func test_scrollWheel_forwardsUpTheResponderChain() {
        let container = ScrollCaptureView()
        let webView = PassThroughScrollWebView(frame: .zero)
        container.addSubview(webView)
        defer { webView.removeFromSuperview() }

        XCTAssertFalse(container.captured, "sanity: nothing captured before the event")
        webView.scrollWheel(with: Self.wheelEvent)
        XCTAssertTrue(
            container.captured,
            "gesture must reach the responder chain (the outer ScrollView)"
        )
    }

    /// Fallback mode (measurement failed): the WebView keeps its own
    /// scrolling — the event must NOT be forwarded away.
    func test_scrollWheel_fallbackStopsForwarding() {
        let container = ScrollCaptureView()
        let webView = PassThroughScrollWebView(frame: .zero)
        webView.forwardsScrollWheel = false
        container.addSubview(webView)
        defer { webView.removeFromSuperview() }

        webView.scrollWheel(with: Self.wheelEvent)
        XCTAssertFalse(container.captured, "fallback must keep gestures inside the WebView")
    }

    /// Keyboard scrolling follows the same contract as the wheel. With the
    /// frame sized to content there is nothing to scroll inside the
    /// WebView, so arrow keys / PageDown must travel to the outer
    /// scroller — otherwise a keyboard user cannot reach the tail of a
    /// long message at all.
    func test_keyboardScrollForwardsUpTheResponderChain() {
        let container = ScrollCaptureView()
        let webView = PassThroughScrollWebView(frame: .zero)
        container.addSubview(webView)
        defer { webView.removeFromSuperview() }

        webView.scrollLineDown(nil)
        webView.scrollPageDown(nil)
        XCTAssertEqual(container.keyboardScrolles, 2, "keyboard scroll must reach the outer scroller")
    }

    /// In fallback mode the WebView keeps keyboard scrolling too.
    func test_keyboardScroll_fallbackStaysInsideWebView() {
        let container = ScrollCaptureView()
        let webView = PassThroughScrollWebView(frame: .zero)
        webView.forwardsScrollWheel = false
        container.addSubview(webView)
        defer { webView.removeFromSuperview() }

        webView.scrollLineDown(nil)
        XCTAssertEqual(container.keyboardScrolles, 0, "fallback must keep keyboard gestures inside")
    }

    private static let wheelEvent: NSEvent = {
        // `NSEvent.mouseEvent(with:)` rejects .scrollWheel (asserts the
        // mouse mask), and the otherEvent factory's Swift overlay is
        // finicky across SDKs — build a real scroll CGEvent and wrap it.
        let cg = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: -10,
            wheel2: 0,
            wheel3: 0
        )!
        return NSEvent(cgEvent: cg)!
    }()

    // MARK: - Measurement without the private scroll-view hierarchy

    /// macOS 26/27 removed `WKWebView`'s internal `NSScrollView` from the
    /// AppKit hierarchy (probed: `WKWebView → WKFlippedView`, no scroll
    /// view). The old DFS-based measurement found nothing, the height
    /// binding stayed 0, and every body collapsed to the 80pt floor with
    /// the fallback inner scrollbar — the "one line + slider, screen
    /// mostly blank" bug. The evalJS polling channel must report the real
    /// document height on any OS.
    @MainActor
    func test_measurementReportsHeightWithoutPrivateScrollView() {
        let box = HeightBox()
        let coordinator = HTMLMessageView.Coordinator(
            contentHeight: Binding(get: { box.value }, set: { box.value = $0 })
        )
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 80))
        webView.navigationDelegate = coordinator
        webView.loadHTMLString(
            "<html><body>" + String(repeating: "line of mail body<br>", count: 60) + "</body></html>",
            baseURL: nil
        )
        // Pump the main run loop so the load finishes, didFinish fires, and
        // the measurement task's @MainActor work runs between samples.
        // First honest sample lands at ~150ms debounce + 250ms poll.
        let deadline = Date().addingTimeInterval(10)
        while box.value <= 500, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        XCTAssertGreaterThan(
            box.value, 500,
            "height never reported — the body would collapse to the 80pt floor"
        )
    }

    /// The entire macOS 26/27 fix rests on one claim: our own
    /// `evaluateJavaScript` measurement call keeps working while the page's
    /// JavaScript stays disabled. The other measurement test builds a
    /// default (JS-enabled) WebView, so nothing in CI would catch losing
    /// it. This one uses the *production* configuration and asserts both
    /// halves: the API answers, and the page still cannot run scripts.
    @MainActor
    func test_evaluateJavaScriptWorksWithContentJavaScriptDisabled() async {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        XCTAssertFalse(
            config.defaultWebpagePreferences.allowsContentJavaScript,
            "sanity: this test is only meaningful with JS disabled"
        )
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 80),
            configuration: config
        )
        webView.loadHTMLString(
            "<html><body><script>window.__lagoonProbe = 1</script>"
                + String(repeating: "line of mail body<br>", count: 60)
                + "</body></html>",
            baseURL: nil
        )
        var height: CGFloat?
        let deadline = Date().addingTimeInterval(10)
        while (height ?? 0) <= 500, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
            height = await Self.documentHeight(of: webView) ?? height
        }
        // The page's own script must not have run …
        let probe = try? await webView.evaluateJavaScript("typeof window.__lagoonProbe")
        XCTAssertNotNil(height, "evaluateJavaScript never answered with JS disabled")
        XCTAssertGreaterThan(height ?? 0, 500, "measurement channel returned a nonsense height")
        XCTAssertEqual(
            (probe as? String) ?? "undefined", "undefined",
            "page script ran — the security posture changed"
        )
    }

    /// A "measured" height has to be *taller than the frame*. A document
    /// that reports exactly the viewport (`body{overflow:hidden}`,
    /// `html{height:100%}`) is a wrong measurement: the old `> 1` filter
    /// accepted it, the parent's 80pt floor then looked like a real
    /// height, and the wheel was forwarded away from clipped content.
    func test_viewportHeightIsNotAMeasurement() {
        XCTAssertFalse(HTMLMessageView.Coordinator.isMeasured(0, frameHeight: 80), "never measured")
        XCTAssertFalse(HTMLMessageView.Coordinator.isMeasured(80, frameHeight: 80), "measured == viewport")
        XCTAssertFalse(
            HTMLMessageView.Coordinator.isMeasured(85, frameHeight: 80),
            "within the epsilon of the viewport is still the viewport"
        )
        XCTAssertTrue(HTMLMessageView.Coordinator.isMeasured(200, frameHeight: 80), "real content")
    }

    /// End-to-end version of the same rule: a document that reports exactly
    /// the viewport (content pinned with `position:fixed`, or
    /// `body{overflow:hidden}` where the sender's own CSS wins) is a *wrong*
    /// measurement. The old `> 1` filter accepted it, the parent's 80pt
    /// floor then looked like a real height, and the wheel was forwarded
    /// away from content that was still there. Nothing is written back, so
    /// the pre-measurement floor plus the internal-scrolling fallback stay
    /// in charge.
    @MainActor
    func test_viewportHeightDocumentIsNotWrittenBack() async {
        let box = HeightBox()
        let coordinator = HTMLMessageView.Coordinator(
            contentHeight: Binding(get: { box.value }, set: { box.value = $0 })
        )
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 80))
        webView.navigationDelegate = coordinator
        webView.loadHTMLString(
            "<html><head><style>html,body{height:100%;margin:0}"
                + "body>div{position:fixed;inset:0;overflow:hidden}</style></head>"
                + "<body><div>" + String(repeating: "clipped line<br>", count: 200) + "</div></body></html>",
            baseURL: nil
        )
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        let raw = await Self.documentHeight(of: webView)
        XCTAssertEqual(
            raw ?? 0, 80, accuracy: 1,
            "sanity: this document reports the viewport, not its content"
        )
        XCTAssertEqual(box.value, 0, "a viewport-height sample must not be treated as content")
    }

    /// The fallback has three properties: it fires on the grace timer when
    /// no *usable* height arrived, it does not fire when one did, and a
    /// later real measurement re-arms gesture forwarding (the fallback used
    /// to latch on forever, which re-created the nested scroll box).
    @MainActor
    func test_didFinishFallbackFiresAfterGraceAndCanBeReArmed() {
        let originalGrace = HTMLMessageView.Coordinator.fallbackGraceSeconds
        HTMLMessageView.Coordinator.fallbackGraceSeconds = 0.1
        defer { HTMLMessageView.Coordinator.fallbackGraceSeconds = originalGrace }

        let box = HeightBox()
        let coordinator = HTMLMessageView.Coordinator(
            contentHeight: Binding(get: { box.value }, set: { box.value = $0 })
        )
        let webView = PassThroughScrollWebView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 80),
            configuration: WKWebViewConfiguration()
        )
        XCTAssertTrue(webView.forwardsScrollWheel, "sanity: forwarding starts on")

        coordinator.webView(webView, didFinish: nil)
        pump(for: 0.4)
        XCTAssertFalse(
            webView.forwardsScrollWheel,
            "grace elapsed with no usable height — gestures must stay inside the WebView"
        )

        // …and a real height puts us back in the single-scroller contract.
        XCTAssertTrue(coordinator.commit(1200, to: webView), "commit should write the height")
        XCTAssertEqual(box.value, 1200)
        XCTAssertTrue(webView.forwardsScrollWheel, "a committed height must re-arm forwarding")
        coordinator.cancelMeasurement()
    }

    /// With a usable height already in the binding, the grace timer must
    /// not steal the gestures.
    @MainActor
    func test_didFinishFallbackStaysOffWhenHeightIsUsable() {
        let originalGrace = HTMLMessageView.Coordinator.fallbackGraceSeconds
        HTMLMessageView.Coordinator.fallbackGraceSeconds = 0.1
        defer { HTMLMessageView.Coordinator.fallbackGraceSeconds = originalGrace }

        let box = HeightBox()
        box.value = 1200
        let coordinator = HTMLMessageView.Coordinator(
            contentHeight: Binding(get: { box.value }, set: { box.value = $0 })
        )
        let webView = PassThroughScrollWebView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 80),
            configuration: WKWebViewConfiguration()
        )
        coordinator.webView(webView, didFinish: nil)
        pump(for: 0.4)
        XCTAssertTrue(webView.forwardsScrollWheel, "measured height — keep forwarding the wheel")
        coordinator.cancelMeasurement()
    }

    /// A width change reflows the document, so measurement has to restart.
    /// `onWidthChange` is a stored closure that nothing else exercised, so
    /// this also locks the closure exists and fires on a layout-driven
    /// width change (not only on the first layout).
    @MainActor
    func test_onWidthChangeRestartsMeasurement() {
        let box = HeightBox()
        let coordinator = HTMLMessageView.Coordinator(
            contentHeight: Binding(get: { box.value }, set: { box.value = $0 })
        )
        let webView = PassThroughScrollWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 80))
        var restarts = 0
        webView.onWidthChange = { restarts += 1 }

        webView.layout()
        XCTAssertEqual(restarts, 1, "first real width must fire the hook")
        webView.frame = NSRect(x: 0, y: 0, width: 601, height: 80)
        webView.layout()
        XCTAssertEqual(restarts, 2, "a resize must re-fire the hook so the frame follows")
        webView.layout()
        XCTAssertEqual(restarts, 2, "same width must not re-fire")

        HTMLMessageView.dismantleNSView(webView, coordinator: coordinator)
        XCTAssertNil(webView.onWidthChange, "teardown must detach the closure")
    }

    /// The polling loop is bounded: burst (early-exit on 3 stable samples)
    /// plus a heartbeat tail, then silence. Anything that keeps polling
    /// forever is a battery bug; anything that never samples is the
    /// invisible-wall bug.
    @MainActor
    func test_measurementLoopStops() {
        let burstIterations = HTMLMessageView.Coordinator.burstIterations
        let burstInterval = HTMLMessageView.Coordinator.burstInterval
        let heartbeatIterations = HTMLMessageView.Coordinator.heartbeatIterations
        let heartbeatInterval = HTMLMessageView.Coordinator.heartbeatInterval
        HTMLMessageView.Coordinator.burstIterations = 2
        HTMLMessageView.Coordinator.burstInterval = 20_000_000
        HTMLMessageView.Coordinator.heartbeatIterations = 2
        HTMLMessageView.Coordinator.heartbeatInterval = 20_000_000
        defer {
            HTMLMessageView.Coordinator.burstIterations = burstIterations
            HTMLMessageView.Coordinator.burstInterval = burstInterval
            HTMLMessageView.Coordinator.heartbeatIterations = heartbeatIterations
            HTMLMessageView.Coordinator.heartbeatInterval = heartbeatInterval
        }

        let box = HeightBox()
        let coordinator = HTMLMessageView.Coordinator(
            contentHeight: Binding(get: { box.value }, set: { box.value = $0 })
        )
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 80))
        webView.navigationDelegate = coordinator
        webView.loadHTMLString(
            "<html><body>" + String(repeating: "line of mail body<br>", count: 60) + "</body></html>",
            baseURL: nil
        )
        coordinator.startMeasuring(on: webView)
        pump(for: 1.5)
        let settled = box.value
        XCTAssertGreaterThan(settled, 500, "sanity: the loop sampled at all")
        pump(for: 1.0)
        XCTAssertEqual(box.value, settled, "the loop must stop, not poll forever")
        coordinator.cancelMeasurement()
    }

    /// Slow growth after the burst window: the heartbeat keeps sampling,
    /// so a document that grows (late image / font) is not left short. The
    /// schedule is shrunk to keep the test fast; the production numbers
    /// are asserted right after.
    @MainActor
    func test_heartbeatCatchesLateGrowth() async {
        let burstIterations = HTMLMessageView.Coordinator.burstIterations
        let burstInterval = HTMLMessageView.Coordinator.burstInterval
        let heartbeatInterval = HTMLMessageView.Coordinator.heartbeatInterval
        let heartbeatIterations = HTMLMessageView.Coordinator.heartbeatIterations
        // Burst is over in ~250ms; the growth below lands in the heartbeat
        // window, which is the whole point of the fix.
        HTMLMessageView.Coordinator.burstIterations = 2
        HTMLMessageView.Coordinator.burstInterval = 50_000_000
        HTMLMessageView.Coordinator.heartbeatInterval = 30_000_000
        HTMLMessageView.Coordinator.heartbeatIterations = 300
        defer {
            HTMLMessageView.Coordinator.burstIterations = burstIterations
            HTMLMessageView.Coordinator.burstInterval = burstInterval
            HTMLMessageView.Coordinator.heartbeatInterval = heartbeatInterval
            HTMLMessageView.Coordinator.heartbeatIterations = heartbeatIterations
        }
        XCTAssertEqual(heartbeatInterval, 2_000_000_000, "production heartbeat is 2s")
        XCTAssertEqual(heartbeatIterations, 15, "production heartbeat is bounded to ~30s")
        XCTAssertEqual(burstIterations, 40, "production burst stays 40 samples")
        XCTAssertEqual(burstInterval, 250_000_000, "production burst stays 250ms apart")

        let box = HeightBox()
        let coordinator = HTMLMessageView.Coordinator(
            contentHeight: Binding(get: { box.value }, set: { box.value = $0 })
        )
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 80))
        webView.navigationDelegate = coordinator
        webView.loadHTMLString(
            "<html><body><div id='grow'></div></body></html>", baseURL: nil
        )
        coordinator.startMeasuring(on: webView)
        // Wait for the document to commit, then let the burst window close.
        // Real async sleeps, not RunLoop pumping: an async test that blocks
        // the main actor in RunLoop.run starves the measurement task.
        await waitUntil { await Self.documentReady(of: webView) }
        try? await Task.sleep(nanoseconds: 600_000_000)
        // Simulate a late image / web font: the document is now tall.
        let filled: Any?
        do {
            filled = try await webView.evaluateJavaScript(
                "document.getElementById('grow').innerHTML = Array.from({length: 80}, (_, i) => 'late line ' + i + '<br>').join('')"
            )
        } catch {
            XCTFail("late-growth injection failed: \(error)")
            return
        }
        XCTAssertNotNil(filled, "the late-growth injection itself must work")
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertGreaterThan(box.value, 500, "growth after the burst window must still be measured")
        coordinator.cancelMeasurement()
    }

    /// The end-to-end proof the synthetic-parent test cannot give: a wheel
    /// event on the WebView really does move a *real* SwiftUI ScrollView.
    @MainActor
    func test_scrollWheelMovesRealSwiftUIScrollView() {
        let webView = PassThroughScrollWebView(frame: .zero)
        let root = ScrollProbe(webView: webView)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        let deadline = Date().addingTimeInterval(2)
        var scrollView: NSScrollView?
        while scrollView == nil, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
            scrollView = Self.firstScrollView(in: host)
        }
        guard let scrollView else {
            return XCTFail("could not find the enclosing SwiftUI ScrollView")
        }
        let before = scrollView.contentView.bounds.origin.y
        webView.scrollWheel(with: Self.wheelEvent)
        pump(for: 0.2)
        XCTAssertGreaterThan(
            scrollView.contentView.bounds.origin.y, before,
            "the wheel never reached the real outer ScrollView"
        )
    }

    /// Pumps the main run loop for `seconds`, so measurement tasks and
    /// `DispatchQueue.main.asyncAfter` grace timers can run.
    private func pump(for seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    /// Pumps until `ready` (an async check) answers true, bounded at 5s.
    @MainActor
    /// Pumps until `check` answers true, bounded at 5s.
    private func waitUntil(_ check: @MainActor () async -> Bool, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await check() { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// `document.readyState` — "the load has committed", i.e. the DOM the
    /// measurement expression runs against is the one we loaded.
    @MainActor
    private static func documentReady(of webView: WKWebView) async -> Bool {
        let state = try? await webView.evaluateJavaScript("document.readyState")
        return ((state as? String) ?? "") == "complete"
    }

    /// Depth-first hunt for the SwiftUI ScrollView's AppKit scroller.
    private static func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        for subview in view.subviews {
            if let found = firstScrollView(in: subview) { return found }
        }
        return nil
    }

    /// Async bridge for the measurement expression (the surrounding test
    /// is `@MainActor` and needs a sync call site).
    @MainActor
    private static func documentHeight(of webView: WKWebView) async -> CGFloat? {
        let expression = "Math.max(document.documentElement?.scrollHeight ?? 0, document.body?.scrollHeight ?? 0)"
        guard let value = try? await webView.evaluateJavaScript(expression) else { return nil }
        return (value as? NSNumber).map { CGFloat($0.doubleValue) }
    }
}

/// Minimal SwiftUI host: a tall column inside a real `ScrollView`, with the
/// WebView as the first child — the production arrangement.
private struct ScrollProbe: View {
    let webView: WKWebView

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                WebViewSlot(webView: webView)
                ForEach(0..<40, id: \.self) { index in
                    Text("filler \(index)").frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// Embeds an already-configured WebView in SwiftUI, so the test can hold a
/// reference to it and post a wheel event at it.
private struct WebViewSlot: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

/// Test-local binding storage for the measurement test.
private final class HeightBox {
    var value: CGFloat = 0
}

/// Test double that records wheel events reaching it via the responder
/// chain — stands in for the outer SwiftUI ScrollView in the app.
private final class ScrollCaptureView: NSView {
    var captured = false
    var keyboardScrolles = 0
    override func scrollWheel(with event: NSEvent) {
        captured = true
        super.scrollWheel(with: event)
    }

    override func scrollLineDown(_ sender: Any?) { keyboardScrolles += 1 }
    override func scrollPageDown(_ sender: Any?) { keyboardScrolles += 1 }
}