import SwiftUI
import WebKit
import LagoonKit

/// WKWebView that forwards scroll gestures up the responder chain, making
/// the outer SwiftUI ScrollView the single scroller. Size measurement is
/// the primary path (the frame matches content, so there is nothing to
/// scroll inside); this subclass is the guarantee that the floor height
/// shown *before* measurement never becomes a hidden nested scroller —
/// hiding the scrollbar indicator alone does not block the wheel.
///
/// `forwardsScrollWheel = false` restores stock behaviour, used by
/// `HTMLMessageView.restoreEmbeddedScrolling` when height measurement
/// fails permanently: content then degrades to visible internal scrolling
/// instead of clipping behind an invisible wall.
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

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // M1.6: mail has no legitimate need for JS. Disabling is the only
        // way to neutralize a `<script>` tag or `javascript:` href.
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = PassThroughScrollWebView(frame: .zero, configuration: config)
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        // Single-scroller contract, asserted once here: gestures pass
        // through to the outer SwiftUI ScrollView (subclass) and the
        // internal bar indicators are hidden. With the parent sizing the
        // frame to measured content there is then nothing inside to
        // scroll at all — until measurement fails, which is what the
        // restore fallback in `didFinish` is for.
        Self.disableEmbeddedScrolling(in: view)
        let coordinator = context.coordinator
        view.onWidthChange = { [weak view] in
            guard let view else { return }
            coordinator.startMeasuring(on: view)
        }
        return view
    }

    /// Hides the WebView's internal scrollbar *indicators*. Hiding the bar
    /// does not block the gesture — blocking is the subclass's job — the
    /// two together are the single-scroller contract. Asserted once at
    /// `makeNSView`: re-asserting later would fight the measurement-failure
    /// fallback in `restoreEmbeddedScrolling` (indicators off + gestures
    /// no longer forwarded = scrolling with no visible bar, again).
    static func disableEmbeddedScrolling(in webView: WKWebView) {
        guard let scrollView = Coordinator.findScrollView(in: webView) else { return }
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
    }

    /// Escape hatch for permanent height-measurement failure: gestures stop
    /// passing through and the vertical bar reappears, so content stays
    /// reachable instead of clipped at the floor.
    static func restoreEmbeddedScrolling(in webView: WKWebView) {
        if let view = webView as? PassThroughScrollWebView {
            view.forwardsScrollWheel = false
        }
        guard let scrollView = Coordinator.findScrollView(in: webView) else { return }
        scrollView.hasVerticalScroller = true
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
        /// still grow — stopping after a few stable polls clipped
        /// late-loading images. The loop therefore runs a fixed ~10s
        /// window (40 × 250ms) after a 150ms debounce; a window resize
        /// reflows the document and `onWidthChange` restarts the window.
        func startMeasuring(on webView: WKWebView) {
            measureTask?.cancel()
            measureTask = Task { @MainActor [weak webView] in
                // Debounce: a live resize delivers one layout() per frame —
                // wait for the burst to settle before the first sample.
                try? await Task.sleep(nanoseconds: 150_000_000)
                for _ in 0..<40 {
                    guard !Task.isCancelled, let webView else { return }
                    if let height = await Self.documentHeight(of: webView), height > 1,
                       abs(self.contentHeight.wrappedValue - height) > 0.5 {
                        self.contentHeight.wrappedValue = height
                    }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
        }

        /// `scrollHeight` of the taller of documentElement/body, or nil on
        /// any evaluation failure (empty document before the first load,
        /// unresponsive page process) — the caller treats nil as "not
        /// measured yet" and keeps polling.
        private static func documentHeight(of webView: WKWebView) async -> CGFloat? {
            let expression = "Math.max(document.documentElement?.scrollHeight ?? 0, document.body?.scrollHeight ?? 0)"
            guard let result = try? await webView.evaluateJavaScript(expression) else { return nil }
            return (result as? NSNumber).map { CGFloat($0.doubleValue) }
        }

        /// Depth-first search for the first `NSScrollView` under `view`.
        /// The class is private to WebKit, so there is no API for this;
        /// the nesting has been stable across macOS 11–15. If a future OS
        /// hides it, the search returns nil and the caller keeps whatever
        /// height it last had — the body renders at its previous size
        /// rather than crashing or collapsing.
        fileprivate static func findScrollView(in view: NSView) -> NSScrollView? {
            if let scrollView = view as? NSScrollView { return scrollView }
            for subview in view.subviews {
                if let found = findScrollView(in: subview) { return found }
            }
            return nil
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

        /// `loadHTMLString` swaps in a fresh document view, so the height
        /// observer has to be re-attached after every navigation. The
        /// first `reportHeight()` fires here; later ones come from the
        /// frame-changed notifications as images decode and fonts settle.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            startMeasuring(on: webView)
            // Measurement can fail permanently (evaluateJavaScript never
            // answers: empty document, unresponsive page process). The
            // outer frame would then sit on the floor with gestures passing
            // through — invisible clipping, worse than the original
            // nested scrollbar. After a grace period with no height,
            // restore the WebView's own scrolling: ugly, but visible.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak webView] in
                guard let webView, self.contentHeight.wrappedValue <= 1 else { return }
                HTMLMessageView.restoreEmbeddedScrolling(in: webView)
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

    func updateNSView(_ webView: WKWebView, context: Context) {
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
