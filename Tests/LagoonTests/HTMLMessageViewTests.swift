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
        // `?? "undefined"` made this pass whenever the probe itself threw,
        // so the value has to be unwrapped rather than defaulted.
        guard let probe else {
            return XCTFail("the security probe never evaluated; the assertion below would pass vacuously")
        }
        XCTAssertEqual(probe as? String, "undefined", "page script ran — the security posture changed")
    }

    /// A remote `<img>` in a newsletter is a tracking pixel: it tells the
    /// sender the reader's IP, the exact open time, and a stable
    /// cookie/ETag identifier. `baseURL: nil` does not stop it (that only
    /// stops *relative* URLs from resolving), and the navigation delegate
    /// never sees subresources at all — so the content rule list is the only
    /// thing standing between opening a message and reporting that it was
    /// opened.
    func test_remoteSubresourcesAreBlocked() async throws {
        let compiled = await HTMLMessageView.remoteContentRuleList()
        let rules = try XCTUnwrap(
            compiled,
            "the remote-content rule list failed to compile, so nothing is blocked"
        )
        let config = WKWebViewConfiguration()
        config.userContentController.add(rules)
        // JavaScript on purpose: this is a harness observing the network from
        // inside the page, not mail being rendered.
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .init(x: 0, y: 0, width: 400, height: 300), configuration: config)

        let html = """
        <html><body>
          <img id="pixel" src="https://tracker.invalid/pixel.gif">
          <script>
            window.__lagoonResult = "pending";
            document.getElementById("pixel").addEventListener("load", function () {
              window.__lagoonResult = "loaded";
            });
            document.getElementById("pixel").addEventListener("error", function () {
              window.__lagoonResult = "blocked";
            });
          </script>
        </body></html>
        """
        await webView.loadHTMLString(html, baseURL: nil)

        var result: String?
        let deadline = Date().addingTimeInterval(10)
        while result == nil, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
            result = try? await webView.evaluateJavaScript("window.__lagoonResult ?? null") as? String
        }
        XCTAssertEqual(
            result, "blocked",
            "a remote image loaded; opening a message is acting as a read receipt"
        )
    }

    /// The same guarantee, in the order the app actually performs it.
    /// `test_remoteSubresourcesAreBlocked` adds the rule list to a
    /// `WKWebViewConfiguration` *before* the web view exists; production adds
    /// it to `webView.configuration.userContentController` *after* the web
    /// view is built and only then calls `loadHTMLString`. Two wirings, one
    /// green test — which says nothing about the path the app runs. This one
    /// mirrors production exactly, because the tracking pixel fires during
    /// the first layout pass, not after it.
    func test_ruleListAddedAfterConstructionStillBlocks() async throws {
        let compiled = await HTMLMessageView.remoteContentRuleList()
        let rules = try XCTUnwrap(
            compiled,
            "the remote-content rule list failed to compile, so nothing is blocked"
        )
        // Construct first, add second — the production order.
        let webView = WKWebView(frame: .init(x: 0, y: 0, width: 400, height: 300))
        webView.configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        webView.configuration.userContentController.add(rules)

        let html = """
        <html><body>
          <img id="pixel" src="https://tracker.invalid/pixel.gif">
          <script>
            window.__lagoonResult = "pending";
            document.getElementById("pixel").addEventListener("load", function () {
              window.__lagoonResult = "loaded";
            });
            document.getElementById("pixel").addEventListener("error", function () {
              window.__lagoonResult = "blocked";
            });
          </script>
        </body></html>
        """
        await webView.loadHTMLString(html, baseURL: nil)

        var result: String?
        let deadline = Date().addingTimeInterval(10)
        while result == nil, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
            result = try? await webView.evaluateJavaScript("window.__lagoonResult ?? null") as? String
        }
        XCTAssertEqual(
            result, "blocked",
            "adding the rule list after the WKWebView exists does not block subresources; "
                + "the production wiring is unprotected even though the config-first test passes"
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
    /// The loop must stop on its own, not poll forever.
    ///
    /// This is a correctness test, so it may not encode the machine's speed.
    /// It used to `pump(for: 1.5)` and then assert a height had been
    /// committed; on the first CI run that ever reached the test stage the
    /// WebView had not finished loading within that fixed window, so no
    /// sample landed (box.value was still 0), and the follow-up
    /// `pump(for: 1.0)` observed the late `didFinish` commit and reported it
    /// as "the loop never stopped". Both failures were the harness racing the
    /// page load, not a defect in the loop.
    ///
    /// Waiting for `document.readyState == "complete"` removes the race: the
    /// loop is only allowed to start once there is a document to measure.
    @MainActor
    func test_measurementLoopStops() async {
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
        // Let the document finish loading before the loop is armed, so the
        // fixed-length waits below measure the loop rather than the loader.
        await waitUntil { await Self.documentReady(of: webView) }
        coordinator.startMeasuring(on: webView)

        // Poll for the first committed height instead of assuming a duration.
        await waitUntil { box.value > 500 }
        let settled = box.value
        XCTAssertGreaterThan(settled, 500, "sanity: the loop sampled at all")

        // The burst (2 iterations) and heartbeat (2 iterations) are both
        // configured below to finish in tens of milliseconds, so once a
        // height has landed the loop is already done. Wait a moment longer
        // than the whole schedule and require that nothing moved again.
        pump(for: 0.5)
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
    ///
    /// Opt-in, because a real `NSScrollView` will not act on a synthetic
    /// `NSEvent` that belongs to no window — and `NSEvent.window` is get-only
    /// in Swift, so the event cannot be bound to the window under test. The
    /// alternatives (posting a real `CGEvent`) need Accessibility
    /// permission, which a headless `swift test` does not have. It fails
    /// identically on an untouched checkout, so it is not a regression
    /// signal — only a permanently-red line, which is worse than none.
    ///
    /// Run it where the contract actually matters:
    ///     LAGOON_GUI_TESTS=1 swift test --filter test_scrollWheelMovesRealSwiftUIScrollView
    @MainActor
    func test_scrollWheelMovesRealSwiftUIScrollView() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["LAGOON_GUI_TESTS"] == "1",
            "needs a real window; set LAGOON_GUI_TESTS=1 at a desktop"
        )
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
        let enclosing = try XCTUnwrap(scrollView, "could not find the enclosing SwiftUI ScrollView")
        let before = enclosing.contentView.bounds.origin.y
        webView.scrollWheel(with: Self.wheelEvent)
        pump(for: 0.2)
        XCTAssertGreaterThan(
            enclosing.contentView.bounds.origin.y, before,
            "the wheel never reached the real outer ScrollView"
        )
    }

    // The "does a wheel event move a *real* SwiftUI ScrollView" check that
    // used to live here is gone on purpose. It needs AppKit to route a
    // synthetic scroll event through a live on-screen window, which a
    // headless `swift test` process never gets: `orderFront` succeeds, the
    // window reports itself visible, and nothing is ever delivered — it
    // failed on `ea4118b` too, and no code change here moves it. The
    // production logic it guarded (`PassThroughScrollWebView.scrollWheel`
    // handing off to `nextResponder`) is covered deterministically by
    // `test_scrollWheel_forwardsUpTheResponderChain` and
    // `test_scrollWheel_fallbackStopsForwarding` above. Confirming the real
    // scroller end-to-end is a manual check at a real desktop.

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

    // MARK: - Navigation policy (F32)

    /// A sender-controlled `<meta http-equiv="refresh">` must not reach the
    /// user's real browser. Before the fix, every http(s) navigation — user
    /// click, meta refresh, iframe, redirect alike — was handed to
    /// `NSWorkspace.shared.open`, so `content="0;url=…"` turned "open a
    /// message" into an outbound request carrying the user's IP, the exact
    /// open time and their logged-in browser context. Meta refresh arrives
    /// as `.other`, never `.linkActivated`.
    func test_navigationPolicy_metaRefreshDoesNotOpenTheBrowser() {
        let url = URL(string: "https://tracker.invalid/px.gif")!

        XCTAssertEqual(
            HTMLMessageView.Coordinator.navigationPolicy(
                for: url, isMainFrame: true, navigationType: .other
            ),
            .cancel,
            "a meta refresh is not a user gesture; opening it hands the sender a read receipt"
        )
    }

    /// The same rule covers redirects, JS navigation and form posts, plus
    /// clicks inside a sub-frame.
    func test_navigationPolicy_onlyUserActivatedMainFrameLinksOpen() {
        let url = URL(string: "https://example.com/x")!
        let policy: (URL?, Bool, WKNavigationType) -> HTMLMessageView.Coordinator.NavigationPolicy
            = HTMLMessageView.Coordinator.navigationPolicy

        XCTAssertEqual(policy(url, true, .linkActivated), .openExternally(url))
        // Server-driven, not clicked.
        XCTAssertEqual(policy(url, true, .formSubmitted), .cancel)
        XCTAssertEqual(policy(url, true, .formResubmitted), .cancel)
        XCTAssertEqual(policy(url, true, .backForward), .cancel)
        XCTAssertEqual(policy(url, true, .reload), .cancel)
        // A click inside an iframe: main frame of the child, not of the mail.
        XCTAssertEqual(policy(url, false, .linkActivated), .cancel)
        XCTAssertEqual(
            policy(URL(string: "http://tracker.invalid/")!, true, .other),
            .cancel
        )
    }

    /// `about:` / `data:` / `blob:` are the document's own plumbing — the
    /// allowlist has to keep working or nothing renders at all.
    func test_navigationPolicy_allowsTheDocumentsOwnSchemes() {
        let policy: (URL?, Bool, WKNavigationType) -> HTMLMessageView.Coordinator.NavigationPolicy
            = HTMLMessageView.Coordinator.navigationPolicy

        for raw in ["about:blank", "data:text/html,x", "blob:http://x/y"] {
            XCTAssertEqual(policy(URL(string: raw), true, .other), .allow, raw)
        }
        XCTAssertEqual(policy(nil, true, .other), .allow)
    }

    /// The mail document never leaves the WebView, whatever the sender put
    /// in it. This is *not* the security assertion — before the fix the
    /// delegate also cancelled, so a live WebView stayed put either way; the
    /// difference was that `NSWorkspace.shared.open` had already fired. That
    /// half is `test_navigationPolicy_metaRefreshDoesNotOpenTheBrowser`.
    /// What this pins is the other half: a meta refresh must never be
    /// answered `.allow`, or the tracker document replaces the mail.
    @MainActor
    func test_metaRefreshDoesNotNavigateTheWebView() async throws {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .init(x: 0, y: 0, width: 400, height: 300), configuration: config)
        let coordinator = HTMLMessageView.Coordinator(contentHeight: .constant(0))
        webView.navigationDelegate = coordinator
        defer { webView.navigationDelegate = nil }

        // 1s delay: a `content="0"` refresh is the classic open-pixel timing
        // and WebKit may defer it, which would make the test vacuous.
        let html = """
        <html><head><meta http-equiv="refresh" content="1;url=https://tracker.invalid/px.gif"></head>
        <body><p id="marker">original document</p></body></html>
        """
        // No `await`: this test is `@MainActor` and `loadHTMLString` is the
        // plain fire-and-forget call (it returns a discarded `WKNavigation?`
        // and has no async overload), so the marker would only name an
        // actor hop that never happens. Neither form awaits the load — the
        // 300ms below is what lets it commit.
        webView.loadHTMLString(html, baseURL: nil)
        // The document the mail actually loaded: `loadHTMLString` lands on
        // about:blank, and that — not the tracker's URL — is the baseline.
        try? await Task.sleep(nanoseconds: 300_000_000)
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
        let loadedURL = webView.url
        let loadedTitle = webView.title ?? ""

        // Well past the refresh deadline.
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.2))

        XCTAssertEqual(
            webView.url, loadedURL,
            "the document navigated away; the meta refresh was not cancelled"
        )
        XCTAssertNotEqual(loadedURL?.absoluteString, "https://tracker.invalid/px.gif")
        XCTAssertEqual(webView.title ?? "", loadedTitle, "the tracker document replaced the mail")
    }

    /// The rule list is the subresource layer; the delegate is the
    /// navigation layer. Both have to exist, and the navigation one has to
    /// name documents explicitly so a future `resource-type` filter cannot
    /// quietly reopen the hole. (`WKContentRuleList` exposes its compiled
    /// rules nowhere public, so this asserts the source JSON; that it still
    /// compiles is covered by `test_remoteSubresourcesAreBlocked`.)
    func test_ruleListNamesDocumentsExplicitly() throws {
        let parsed = try JSONSerialization.jsonObject(
            with: Data(HTMLMessageView.ruleListJSON.utf8)
        ) as? [[String: Any]]
        let rules = try XCTUnwrap(parsed, "the rule list JSON must be a rule array")
        XCTAssertEqual(
            rules.compactMap { ($0["trigger"] as? [String: Any])?["url-filter"] as? String },
            ["^https?:", "^https?:", "^ftp:", "^file:"]
        )
        let documentRule = try XCTUnwrap(
            rules.first { ($0["trigger"] as? [String: Any])?["url-filter"] as? String == "^https?:" }
        )
        let resourceTypes = try XCTUnwrap(
            (documentRule["trigger"] as? [String: Any])?["resource-type"] as? [String]
        )
        XCTAssertEqual(
            resourceTypes, ["document"],
            "the main-frame navigation must be named in the rule list too"
        )
    }

    /// The rule list is compiled for real by the app, and one bad
    /// `resource-type` spelling fails the *whole* list — taking the
    /// subresource blocks down with it. This is the guard for that.
    func test_ruleListStillCompiles() async throws {
        let compiled = await HTMLMessageView.remoteContentRuleList()
        XCTAssertNotNil(compiled, "the remote-content rule list failed to compile, so nothing is blocked")
    }

    // MARK: - updateNSView cost (F27)

    /// The reload guard must be *exact*: it decides whether the WebView is
    /// reloaded, and "same shape, different bytes" has to count as a change.
    ///
    /// This replaces a pair of wall-clock tests that could not survive CI.
    /// The first asserted "rebuild the document in under 30ms" and measured
    /// 3ms locally against 242ms on the runner. The second compared the
    /// rebuild against the expensive operation it replaced, on the theory
    /// that a ratio cancels machine speed — it does not: solving the two runs
    /// for the two unknowns shows the split case only slows 2.6x on the
    /// runner while the rebuild slows ~105x, because one is bound by memory
    /// bandwidth and the other by allocation. A ratio between operations with
    /// different bottlenecks is not machine-independent, and the gate failed
    /// again (0.025 locally, 1.018 on the runner).
    ///
    /// What the guard actually promises is a *semantic* property, so that is
    /// what gets asserted here — no clocks involved. The performance intent is
    /// still recorded in `updateNSView`'s comment and in the review that
    /// removed the `components(separatedBy:)` count; verifying it needs a
    /// quiet machine, not a shared runner, and is called out as such below.
    func test_theReloadGuardDistinguishesSameShapeDifferentBytes() {
        let (html, attachments) = Self.benchmarkEmail()

        // Calls the production comparison — the test must not re-implement
        // it, or a regression in `HTMLMessageView` would leave the test green.
        func guardSaysUnchanged(_ html2: String, _ attachments2: [String: Data]) -> Bool {
            !HTMLMessageView.needsReload(
                loadedHTML: html,
                loadedAttachments: attachments,
                newHTML: html2,
                newAttachments: attachments2
            )
        }

        XCTAssertTrue(
            guardSaysUnchanged(html, attachments),
            "identical inputs must skip the reload"
        )

        // Never-loaded must not look like an empty document.
        XCTAssertTrue(
            HTMLMessageView.needsReload(
                loadedHTML: nil,
                loadedAttachments: [:],
                newHTML: "",
                newAttachments: [:]
            ),
            "an empty email still has to render on first load"
        )

        // Same document, one attachment swapped under a reused Content-ID.
        // The `cid`-count guard this replaced could not see this: the count is
        // unchanged, so it reported "nothing to do" while the picture on
        // screen was stale. This is the regression the exact compare exists
        // for, and it is invisible to any timing assertion.
        var swapped = attachments
        let firstKey = try! XCTUnwrap(attachments.keys.sorted().first)
        swapped[firstKey] = Data(repeating: 0xAB, count: 350_000)
        XCTAssertEqual(
            swapped.count, attachments.count,
            "sanity: the swap must not change how many attachments there are"
        )
        XCTAssertFalse(
            guardSaysUnchanged(html, swapped),
            "an attachment swapped under a reused Content-ID must still reload"
        )

        // Same attachments, one byte of markup different.
        XCTAssertFalse(
            guardSaysUnchanged(html + "<!-- -->", attachments),
            "a changed document must reload"
        )
    }

    /// The reload guard runs on every SwiftUI body invalidation, so it has to
    /// be far cheaper than the pipeline it skips — otherwise the guard is what
    /// causes the stutter rather than avoiding it.
    ///
    /// Opt-in, following `test_scrollWheelMovesRealSwiftUIScrollView`: the
    /// comparison is a memcmp over ~7MB and the pipeline is allocation-bound,
    /// so the two respond to a loaded machine very differently (measured
    /// 2.6x vs ~105x slowdown on a shared runner). No threshold that works on
    /// a quiet laptop also works there, and a gate that fails on an untouched
    /// checkout is only a permanently-red line, which is worse than none.
    ///
    /// Run it where the numbers mean something:
    ///     LAGOON_PERF_TESTS=1 swift test --filter test_theReloadGuardIsFarCheaperThanThePipeline
    func test_theReloadGuardIsFarCheaperThanThePipeline() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["LAGOON_PERF_TESTS"] == "1",
            "timing needs a quiet machine; set LAGOON_PERF_TESTS=1 to run it"
        )
        let (html, attachments) = Self.benchmarkEmail()

        func best(_ samples: Int, _ body: () -> Void) -> Double {
            var fastest = Double.infinity
            for _ in 0..<samples {
                let start = Date()
                body()
                fastest = min(fastest, Date().timeIntervalSince(start) * 1000)
            }
            return fastest
        }

        let guardCost = best(50) {
            _ = html == html
            _ = attachments == attachments
        }
        let pipelineCost = best(5) {
            _ = HTMLMessageView.injectFluidCSS(
                into: HTMLMessageView.resolveCidReferences(in: html, with: attachments)
            )
        }

        XCTAssertLessThan(
            guardCost, pipelineCost,
            "the guard (\(guardCost)ms) costs as much as the work it exists to skip (\(pipelineCost)ms)"
        )
    }

    /// A 5MB newsletter with 15 inline `cid:` images — the shape that made
    /// the old pipeline cost ~120ms per SwiftUI body invalidation.
    private static func benchmarkEmail() -> (String, [String: Data]) {
        var html = "<html><head></head><body>"
        var attachments: [String: Data] = [:]
        for index in 0..<15 {
            let key = "cid\(index)@example.com"
            attachments[key] = Data(repeating: UInt8(index), count: 350_000)
            html += "<p>row \(index)</p><img src=\"cid:\(key)\">"
        }
        html += "</body></html>"
        return (html, attachments)
    }

    /// The new `injectFluidCSS` locates `<head>` once and splices instead of
    /// rewriting the string. Same bytes out, on every branch.
    func test_injectFluidCSS_splicePreservesEveryBranch() {
        let css = HTMLMessageView.fluidCSS

        let withHead = "<html><HEAD></HEAD><body>hi</body></html>"
        XCTAssertEqual(
            HTMLMessageView.injectFluidCSS(into: withHead),
            withHead.replacingOccurrences(
                of: "<HEAD>", with: "<HEAD>\n\(css)", options: .caseInsensitive
            )
        )

        let withHtmlOnly = "<HTML lang='zh'><body>hi</body></HTML>"
        XCTAssertEqual(
            HTMLMessageView.injectFluidCSS(into: withHtmlOnly),
            "<HTML lang='zh'><head>\n\(css)</head><body>hi</body></HTML>",
            "the injected head must go after the whole <html …> tag, not swallow its attributes"
        )

        let fragment = "<p>naked</p>"
        XCTAssertEqual(
            HTMLMessageView.injectFluidCSS(into: fragment),
            "<html><head>\n\(css)</head><body>\(fragment)</body></html>"
        )
    }

    /// Empty document: the guard's cache starts `nil` precisely so this
    /// still renders the wrapper instead of being mistaken for "unchanged".
    func test_emptyEmailStillGetsTheDocumentWrapper() {
        let out = HTMLMessageView.injectFluidCSS(into: "")
        XCTAssertTrue(out.contains("max-width: 100%"))
        XCTAssertTrue(out.contains("<body></body>"))
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