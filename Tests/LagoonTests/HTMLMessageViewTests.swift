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
}

/// Test-local binding storage for the measurement test.
private final class HeightBox {
    var value: CGFloat = 0
}

/// Test double that records wheel events reaching it via the responder
/// chain — stands in for the outer SwiftUI ScrollView in the app.
private final class ScrollCaptureView: NSView {
    var captured = false
    override func scrollWheel(with event: NSEvent) {
        captured = true
        super.scrollWheel(with: event)
    }
}