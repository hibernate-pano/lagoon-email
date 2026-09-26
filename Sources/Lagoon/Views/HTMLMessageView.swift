import SwiftUI
import WebKit
import LagoonKit

/// Single-scroller contract, in full:
/// - gestures pass through to the outer SwiftUI ScrollView (this subclass)
/// - the frame is sized to the measured document height, so there is
///   nothing left to scroll inside the WebView
/// - if measurement fails, `forwardsScrollWheel` is set back to `false`
///   and the WebView's own scrolling takes over (see
///   `HTMLMessageView.Coordinator.startMeasuring`) — the *only* fallback,
///   and it is reversible: the next real height sample re-arms forwarding.
///
/// There is deliberately no scrollbar manipulation. Hiding an internal bar
/// never blocked anything: on every OS the app ships on (probed on macOS
/// 27.2) the WebView's hierarchy is `WKWebView → WKFlippedView` with no
/// `NSScrollView` anywhere, so any code reaching for the private scroller
/// silently no-ops. Blocking nested scrolling was always the wheel's job.
final class PassThroughScrollWebView: WKWebView {
    var forwardsScrollWheel = true
    /// Fired when this view's width changes. A window resize reflows the
    /// document, so its height changes with it and the parent's frame must
    /// follow — measurement polling otherwise only runs right after a load.
    var onWidthChange: (() -> Void)?
    private var lastMeasuredWidth: CGFloat = 0

    override func layout() {
        super.layout()
        if bounds.width > 50, abs(bounds.width - lastMeasuredWidth) > 0.5 {
            lastMeasuredWidth = bounds.width
            onWidthChange?()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if forwardsScrollWheel, let next = nextResponder {
            next.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    // MARK: - Keyboard scrolling (same contract as the wheel)
    //
    // With the frame sized to content there is nothing to scroll inside
    // the WebView, so arrow keys / PageDown delivered to the focused
    // WebView would move nothing and swallow the gesture. A keyboard user
    // would have no path to the tail of a long message — the one case the
    // change set exists to prevent. Forward instead, exactly like the
    // wheel: next responder first, stock behaviour in fallback mode.
    override func scrollLineDown(_ sender: Any?) {
        forwardKeyboardScroll(fallback: { super.scrollLineDown(sender) }) { $0.scrollLineDown(sender) }
    }

    override func scrollLineUp(_ sender: Any?) {
        forwardKeyboardScroll(fallback: { super.scrollLineUp(sender) }) { $0.scrollLineUp(sender) }
    }

    override func scrollPageDown(_ sender: Any?) {
        forwardKeyboardScroll(fallback: { super.scrollPageDown(sender) }) { $0.scrollPageDown(sender) }
    }

    override func scrollPageUp(_ sender: Any?) {
        forwardKeyboardScroll(fallback: { super.scrollPageUp(sender) }) { $0.scrollPageUp(sender) }
    }

    override func scrollToEndOfDocument(_ sender: Any?) {
        forwardKeyboardScroll(fallback: { super.scrollToEndOfDocument(sender) }) {
            $0.scrollToEndOfDocument(sender)
        }
    }

    override func scrollToBeginningOfDocument(_ sender: Any?) {
        forwardKeyboardScroll(fallback: { super.scrollToBeginningOfDocument(sender) }) {
            $0.scrollToBeginningOfDocument(sender)
        }
    }

    /// Hands a keyboard scroll action to the next responder (the outer
    /// scroller) while forwarding is on; in fallback mode the WebView keeps
    /// the gesture and scrolls itself.
    private func forwardKeyboardScroll(
        fallback: () -> Void,
        _ action: (NSResponder) -> Void
    ) {
        guard forwardsScrollWheel, let next = nextResponder else {
            fallback()
            return
        }
        action(next)
    }
}

/// Renders an HTML email body inside a sandboxed `WKWebView` (spec §3.3).
///
/// **Security:**
/// - `allowsContentJavaScript = false` — mail should not run JS.
/// - `loadHTMLString(_:baseURL: nil)` — no origin, so relative URLs cannot
///   resolve to file:// or any other scheme. `https://` and other
///   absolute URLs still load if the user happens to click them; with
///   JavaScript disabled and `WKURLSchemeHandler` not registered, the
///   practical risk is "an image fails to load" rather than code execution.
///
/// **Inline images:** HTML references `cid:` URIs. The client passes
/// `attachmentsByCid` (keyed by the raw `Content-ID` value, with `<>`
/// stripped) and the view replaces each `src="cid:..."` with a data URL
/// before handing the string to WebKit. Unresolvable `cid:` references
/// are left untouched — the browser renders a broken-image glyph, which
/// is the right answer for an email whose server has dropped the part.
struct HTMLMessageView: NSViewRepresentable {
    let html: String
    let attachmentsByCid: [String: Data]
    /// The rendered document height, reported back so the parent can size
    /// this view to its content.
    ///
    /// `WKWebView` has no intrinsic content size: left to itself it
    /// collapses to whatever `minHeight` the caller set and scrolls
    /// internally, so a long email lived in a floor-height box with its own
    /// scrollbar while the surrounding page had empty space below. The
    /// Coordinator polls `scrollHeight` via `startMeasuring` and writes the
    /// document height here — what the outer SwiftUI `ScrollView` needs to
    /// lay out the whole message (metadata + body + attachments) as one
    /// scrollable column.
    @Binding var contentHeight: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(contentHeight: $contentHeight)
    }

    // `PassThroughScrollWebView`, not `WKWebView`: the single-scroller
    // contract lives in the subclass, so the teardown hook has to be able
    // to detach the width-change closure without a cast.
    func makeNSView(context: Context) -> PassThroughScrollWebView {
        let config = WKWebViewConfiguration()
        // M1.6: mail has no legitimate need for JS. Disabling is the only
        // way to neutralize a `<script>` tag or `javascript:` href.
        // It does NOT block our own `evaluateJavaScript` measurement calls
        // (probed on macOS 27.2, and locked by
        // `test_evaluateJavaScriptWorksWithContentJavaScriptDisabled`).
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = PassThroughScrollWebView(frame: .zero, configuration: config)
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        // Single-scroller contract, asserted here and nowhere else: the
        // subclass forwards wheel + keyboard scroll to the outer SwiftUI
        // ScrollView. Nothing about the internal bar is touched — see
        // `PassThroughScrollWebView`'s doc comment for why that code is
        // gone rather than merely unused.
        let coordinator = context.coordinator
        view.onWidthChange = { [weak view] in
            guard let view else { return }
            coordinator.startMeasuring(on: view)
        }
        return view
    }

    /// Teardown. Both hooks the old code was missing: the polling task is
    /// unstructured and strongly captures the coordinator (hence the
    /// `contentHeight` binding), so without this it can outlive the view,
    /// and `onWidthChange` would keep a fired closure attached to a view
    /// SwiftUI no longer owns.
    static func dismantleNSView(_ webView: PassThroughScrollWebView, coordinator: Coordinator) {
        webView.onWidthChange = nil
        webView.navigationDelegate = nil
        coordinator.cancelMeasurement()
    }

    /// Reload the WebView when the underlying HTML or inline-image map
    /// changes. SwiftUI's `updateNSView` is the only place where the new
    /// values land — if we just `loadHTMLString` on every redraw, the
    /// selection state and scroll position reset. `Coordinator.html` is
    /// our cache of the last value; only reload when the bytes actually
    /// differ. The image map is harder (Data is non-Equatable enough that
    /// we'd need a per-attachment signature) so we accept a reload whenever
    /// the *count* of resolved cid: references grows.
    final class Coordinator: NSObject, WKNavigationDelegate {
        var html: String = ""
        var resolvedCidCount: Int = 0
        private let contentHeight: Binding<CGFloat>
        private var measureTask: Task<Void, Never>?
        private var fallbackTask: Task<Void, Never>?

        /// Bursty phase: 40 samples × 250ms ≈ 10s, stopped early once the
        /// height settles (3 consecutive identical samples).
        /// `var`, not `let`, so tests can shrink the schedule instead of
        /// sleeping 40 seconds; production never writes them.
        static var burstIterations = 40
        static var burstInterval: UInt64 = 250_000_000
        static let debounce: UInt64 = 150_000_000
        static let stableSampleLimit = 3
        /// A height that is not *more* than the viewport by this margin is
        /// treated as "not measured" — see `isMeasured`.
        static let viewportEpsilon: CGFloat = 8
        /// Slow-growth tail: a heartbeat well past the burst window
        /// (late CDN images, web fonts, `loading=lazy`, `didFinish` before
        /// image decode settles). Bounded so it cannot run forever.
        static var heartbeatIterations = 15
        static var heartbeatInterval: UInt64 = 2_000_000_000
        /// How long after `didFinish` we wait for a usable height before
        /// handing scrolling back to the WebView.
        static var fallbackGraceSeconds: Double = 1.0

        init(contentHeight: Binding<CGFloat>) {
            self.contentHeight = contentHeight
            super.init()
        }

        /// SwiftUI asks for the height; WebKit owns it. We bridge them by
        /// asking the page for `scrollHeight` through `evaluateJavaScript`.
        ///
        /// The previous channel — DFS for the WebView's private
        /// `NSScrollView` and observing its document view's frame — worked
        /// through macOS 15, but on macOS 26/27 that hierarchy is gone
        /// (probed: `WKWebView → WKFlippedView`, no scroll view), so
        /// measurement silently never ran and every body collapsed to the
        /// 80pt floor with the fallback inner scrollbar restored. The JS
        /// expression is a fixed trusted string; `allowsContentJavaScript
        /// = false` still blocks the page's own scripts (probed: page-set
        /// globals stay `undefined` while this API call answers).
        ///
        /// Polled rather than one-shot: images decode and fonts settle
        /// after `didFinish`, so a height that stops changing early can
        /// still grow — stopping after a few polls clipped late-loading
        /// images. Two bounded phases:
        ///
        /// 1. **Burst** — 150ms debounce, then 40 samples 250ms apart
        ///    (~10s), ending early once 3 consecutive samples agree.
        ///    A window resize reflows the document and `onWidthChange`
        ///    restarts the whole thing.
        /// 2. **Heartbeat** — the burst used to be the *end* of
        ///    measurement, so anything that grew after ~10s (slow CDN
        ///    image, web font, `loading=lazy`) stayed short forever, and
        ///    because the wheel is forwarded to an outer scroller with
        ///    nothing left to scroll, the tail of the email was
        ///    unreachable. The heartbeat samples every 2s for 15 more
        ///    iterations (~30s) and stops as soon as it is cancelled
        ///    (teardown, reload, resize).
        func startMeasuring(on webView: WKWebView) {
            measureTask?.cancel()
            measureTask = Task { @MainActor [weak webView] in
                // Debounce: a live resize delivers one layout() per frame —
                // wait for the burst to settle before the first sample.
                try? await Task.sleep(nanoseconds: Self.debounce)
                var stableRun = 0
                var last: CGFloat = 0
                for _ in 0..<Self.burstIterations {
                    guard !Task.isCancelled, let webView else { return }
                    if let height = await Self.measuredHeight(of: webView) {
                        stableRun = abs(height - last) <= 0.5 ? stableRun + 1 : 0
                        last = height
                        self.commit(height, to: webView)
                    }
                    if stableRun >= Self.stableSampleLimit { break }
                    try? await Task.sleep(nanoseconds: Self.burstInterval)
                }
                for _ in 0..<Self.heartbeatIterations {
                    try? await Task.sleep(nanoseconds: Self.heartbeatInterval)
                    guard !Task.isCancelled, let webView else { return }
                    guard let height = await Self.measuredHeight(of: webView) else { continue }
                    self.commit(height, to: webView)
                }
            }
        }

        /// Cancels the polling task and the pending fallback check. Called
        /// from `dismantleNSView` (and implicitly by `startMeasuring`,
        /// which cancels before re-arming).
        func cancelMeasurement() {
            measureTask?.cancel()
            measureTask = nil
            fallbackTask?.cancel()
            fallbackTask = nil
        }

        /// `scrollHeight` of the taller of documentElement/body, accepted
        /// only when it is *bigger than the viewport*.
        ///
        /// The old filter was `height > 1`, which is nearly no filter at
        /// all: an email with `body { overflow: hidden }` or
        /// `html { height: 100% }` measures exactly the viewport, which
        /// is > 1, so a *wrong* measurement was written into the binding,
        /// the parent clamped it to the 80pt floor, and the wheel was
        /// forwarded away — the email tail clipped behind an invisible
        /// wall. Samples equal to the frame are "not measured" and are
        /// dropped, so the parent keeps showing the pre-measurement floor
        /// and the fallback below takes over.
        private static func measuredHeight(of webView: WKWebView) async -> CGFloat? {
            let expression = "Math.max(document.documentElement?.scrollHeight ?? 0, document.body?.scrollHeight ?? 0)"
            guard let result = try? await webView.evaluateJavaScript(expression) else { return nil }
            guard let height = (result as? NSNumber).map({ CGFloat($0.doubleValue) }),
                  isMeasured(height, frameHeight: webView.bounds.height)
            else { return nil }
            return height
        }

        /// "Measured" means *taller than what the frame already is*. A
        /// value within `viewportEpsilon` of the frame height is the
        /// viewport reporting itself, not a document height.
        static func isMeasured(_ height: CGFloat, frameHeight: CGFloat) -> Bool {
            height > frameHeight + viewportEpsilon
        }

        /// Writes a real height back to the parent and re-arms gesture
        /// forwarding.
        ///
        /// The re-arm matters because the fallback is one-way unless
        /// something undoes it: a single 1s grace trip (page-process
        /// stall, empty document) latched `forwardsScrollWheel = false`,
        /// and a later successful measurement left the WebView with its
        /// own scroller inside a frame that already matched its content —
        /// the nested scroll box this design removed, with no way back.
        /// Any committed height means the frame matches content again, so
        /// forwarding must go back on.
        @discardableResult
        func commit(_ height: CGFloat, to webView: WKWebView) -> Bool {
            // Re-arm on *any* accepted sample, even one that does not move
            // the binding: a same-height sample still means the frame
            // matches content, so the WebView must not keep its own
            // scroller.
            if let passthrough = webView as? PassThroughScrollWebView {
                passthrough.forwardsScrollWheel = true
            }
            guard abs(contentHeight.wrappedValue - height) > 0.5 else { return false }
            contentHeight.wrappedValue = height
            return true
        }

        /// Open links in the user's default browser instead of navigating
        /// the WebView. We still allow the *initial* `loadHTMLString` (no
        /// real `request`, no decision to make) but anything after that
        /// — clicks, redirects, programmatic navigation — gets handed off
        /// to `NSWorkspace`.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            // The `loadHTMLString(_:baseURL:)` we use in `updateNSView` does
            // not produce a navigation action — it sets content directly —
            // so any action reaching here is a real user gesture.
            if let url = navigationAction.request.url,
               let scheme = url.scheme?.lowercased(),
               scheme == "http" || scheme == "https" {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            // About: / data: / blob: etc.: let the WebView handle them
            // (mostly no-ops).
            decisionHandler(.allow)
        }

        /// `loadHTMLString` swaps in a fresh document view, so measurement
        /// restarts here for every navigation. The first honest sample
        /// lands after the 150ms debounce; later ones come from the
        /// polling loop as images decode and fonts settle.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            startMeasuring(on: webView)
            // Measurement can fail permanently (evaluateJavaScript never
            // answers: empty document, unresponsive page process). The
            // outer frame would then sit on the floor with gestures passing
            // through — invisible clipping, worse than the original nested
            // scrollbar. After a grace period with no *usable* height,
            // hand scrolling back to the WebView: ugly, but visible.
            // "Usable" means taller than the frame, not merely > 0 — a
            // viewport-height sample is a wrong measurement, not a
            // measurement (see `isMeasured`).
            fallbackTask?.cancel()
            fallbackTask = Task { @MainActor [weak webView] in
                try? await Task.sleep(nanoseconds: UInt64(Self.fallbackGraceSeconds * 1_000_000_000))
                guard !Task.isCancelled, let webView else { return }
                guard !Self.isMeasured(
                    self.contentHeight.wrappedValue,
                    frameHeight: webView.bounds.height
                ) else { return }
                (webView as? PassThroughScrollWebView)?.forwardsScrollWheel = false
            }
        }
    }

    /// CSS injected into every HTML email so it lays out fluidly inside the
    /// reading column instead of sticking to whatever intrinsic width the
    /// sender picked. Without this, an email designed for a 600pt Outlook
    /// window renders as a narrow strip in a 900pt column — the page looks
    /// "disjointed" with empty space on both sides. With this, the body
    /// fills the WebView's width; tables and images shrink when the column
    /// narrows and grow up to the column width on wide windows.
    ///
    /// `!important` is the only way to win against senders that hardcode
    /// widths on their root `<table>` (most transactional / newsletter HTML
    /// does this).
    static let fluidCSS = """
    <style>
      html, body { margin: 0; padding: 0; max-width: 100%; }
      body { word-wrap: break-word; overflow-wrap: break-word; -webkit-text-size-adjust: 100%; }
      table { max-width: 100% !important; }
      img, video { max-width: 100% !important; height: auto !important; }
      pre { white-space: pre-wrap; word-wrap: break-word; }
    </style>
    """

    func updateNSView(_ webView: PassThroughScrollWebView, context: Context) {
        let resolved = Self.resolveCidReferences(in: html, with: attachmentsByCid)
        // Inject the fluid CSS into the head — or wrap a minimal head around
        // documents that have no `<head>` at all (rare but legal HTML).
        let withCSS = Self.injectFluidCSS(into: resolved)
        // Avoid reloading on every SwiftUI body invalidation: the WebView
        // already holds the rendered page, and reloading blows away
        // selection, scroll position, and any in-flight image loads.
        let nextCidCount = withCSS.components(separatedBy: "data:").count - 1
        if withCSS == context.coordinator.html,
           nextCidCount == context.coordinator.resolvedCidCount {
            return
        }
        context.coordinator.html = withCSS
        context.coordinator.resolvedCidCount = nextCidCount
        webView.loadHTMLString(withCSS, baseURL: nil)
        // Measurement starts in `didFinish`, not here: until the load
        // commits, `scrollView.documentView` is still the previous
        // document (or the blank first-load one), so an early observation
        // would attach to the wrong view and report a useless height.
    }

    /// Prepends `fluidCSS` to whatever `<head>` (or implicit head) the email
    /// ships with. We don't try to *replace* sender styles — Mail.app and
    /// the bug ticket both lose information when we do; we just add our
    /// fluid overrides on top.
    static func injectFluidCSS(into html: String) -> String {
        let css = fluidCSS
        if html.range(of: "<head>", options: .caseInsensitive) != nil {
            return html.replacingOccurrences(
                of: "<head>",
                with: "<head>\n\(css)",
                options: .caseInsensitive
            )
        }
        if html.range(of: "<html", options: .caseInsensitive) != nil {
            return html.replacingOccurrences(
                of: "<html",
                with: "<html><head>\n\(css)</head>",
                options: .caseInsensitive
            )
        }
        // No <html> / <head> at all: wrap so our CSS still applies. The
        // sender's body text lands inside our wrapper.
        return "<html><head>\n\(css)</head><body>\(html)</body></html>"
    }

    /// Replaces `src="cid:xxx"` with `src="data:<mime>;base64,<bytes>"`.
    /// Case-insensitive on both the `Content-ID` key and the `cid:` ref so
    /// senders that differ in capitalization (a common GMail quirk) still
    /// resolve.
    static func resolveCidReferences(in html: String, with map: [String: Data]) -> String {
        guard !map.isEmpty else { return html }
        // Lower-cased lookup, built once.
        let lowercased = Dictionary(uniqueKeysWithValues: map.map { ($0.key.lowercased(), $0.value) })
        // The `cid:` scheme permits alphanumerics and `._%-`. RFC 2392; in
        // practice senders do not escape the value.
        let pattern = #"src\s*=\s*["']cid:([^"'>\s]+)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return html
        }
        let ns = html as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        var output = ""
        var cursor = html.startIndex
        regex.enumerateMatches(in: html, options: [], range: fullRange) { match, _, _ in
            guard let match,
                  match.numberOfRanges >= 2,
                  let full = Range(match.range, in: html),
                  let idRange = Range(match.range(at: 1), in: html)
            else { return }
            output += html[cursor..<full.lowerBound]
            let key = String(html[idRange]).lowercased()
            if let data = lowercased[key] {
                let mime = Self.guessMimeType(forCid: key) ?? "application/octet-stream"
                let b64 = data.base64EncodedString()
                output += "src=\"data:\(mime);base64,\(b64)\""
            } else {
                output += String(html[full])
            }
            cursor = full.upperBound
        }
        output += html[cursor...]
        return output
    }

    /// Best-effort MIME guess for inline images when we have no other
    /// metadata. The Content-ID itself doesn't carry the type; the
    /// attachment list does. We fall back to `image/*` based on the
    /// disposition hint the body parser set.
    private static func guessMimeType(forCid _: String) -> String? {
        // Without a richer data structure, we cannot look up the real mime
        // type from the Content-ID alone. Callers that care about precise
        // rendering should pass an explicit mime mapping; the WKWebView
        // is permissive enough to sniff from the data URL bytes when needed.
        nil
    }
}

/// Convenience: loadable resource lookup keyed by Content-ID, used by
/// the detail view to collect inline images for `HTMLMessageView`.
extension MessageBody {
    /// Attachment ids that the HTML body is likely to reference via
    /// `cid:` — image-shaped, inline-disposition. The view then fetches
    /// their bytes in parallel and the WebView replaces the references.
    var inlineImageAttachments: [Attachment] {
        attachments.filter { $0.disposition == .inline && $0.mimeType.hasPrefix("image/") }
    }
}
