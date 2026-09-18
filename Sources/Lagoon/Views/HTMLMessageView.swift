import SwiftUI
import WebKit
import LagoonKit

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
    /// internally, so a long email lived in a 200pt-tall box with its own
    /// scrollbar while the surrounding page had empty space below. The
    /// observed `NSScrollView.contentSize` is the document size, which is
    /// what the outer SwiftUI `ScrollView` needs to lay out the whole
    /// message (metadata + body + attachments) as one scrollable column.
    @Binding var contentHeight: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(contentHeight: $contentHeight)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // M1.6: mail has no legitimate need for JS. Disabling is the only
        // way to neutralize a `<script>` tag or `javascript:` href.
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        return view
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
        private var frameObserver: NSObjectProtocol?
        private weak var observedDocumentView: NSView?

        init(contentHeight: Binding<CGFloat>) {
            self.contentHeight = contentHeight
            super.init()
        }

        /// SwiftUI asks for the height; WebKit owns it. We bridge them by
        /// watching the WebView's internal document view's frame.
        ///
        /// macOS does not expose `WKWebView.scrollView` (that is the iOS
        /// surface) and `NSScrollView.contentSize` is the *visible* area,
        /// not the document size, so neither helps. The document view's
        /// frame is the rendered document height — exactly what the outer
        /// SwiftUI `ScrollView` needs to lay the whole message out as one
        /// column.
        ///
        /// Re-attached after every navigation because `loadHTMLString`
        /// replaces the document view.
        func observeDocumentHeight(of webView: WKWebView) {
            guard let scrollView = Self.findScrollView(in: webView),
                  let documentView = scrollView.documentView
            else { return }
            if observedDocumentView === documentView { return }
            if let frameObserver {
                NotificationCenter.default.removeObserver(frameObserver)
            }
            observedDocumentView = documentView
            documentView.postsFrameChangedNotifications = true
            frameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: documentView,
                queue: .main
            ) { [weak self] _ in
                // `queue: .main` guarantees the main thread; hopping
                // through a MainActor task keeps the compiler happy
                // without `assumeIsolated`'s hard crash if that ever
                // stops being true.
                Task { @MainActor in
                    self?.reportHeight()
                }
            }
            reportHeight()
        }

        private func reportHeight() {
            guard let documentView = observedDocumentView else { return }
            // A document laid out at zero width reports a nonsense height
            // (one character per line). Wait for SwiftUI to give the
            // WebView a real width; the frame-changed notification fires
            // again once it does.
            guard documentView.frame.width > 50 else { return }
            let height = documentView.frame.height
            guard height > 1 else { return }
            if abs(contentHeight.wrappedValue - height) > 0.5 {
                contentHeight.wrappedValue = height
            }
        }

        /// Depth-first search for the first `NSScrollView` under `view`.
        /// The class is private to WebKit, so there is no API for this;
        /// the nesting has been stable across macOS 11–15. If a future OS
        /// hides it, the search returns nil and the caller keeps whatever
        /// height it last had — the body renders at its previous size
        /// rather than crashing or collapsing.
        private static func findScrollView(in view: NSView) -> NSScrollView? {
            if let scrollView = view as? NSScrollView { return scrollView }
            for subview in view.subviews {
                if let found = findScrollView(in: subview) { return found }
            }
            return nil
        }

        deinit {
            if let frameObserver {
                NotificationCenter.default.removeObserver(frameObserver)
            }
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
            observeDocumentHeight(of: webView)
        }
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let resolved = Self.resolveCidReferences(in: html, with: attachmentsByCid)
        // Avoid reloading on every SwiftUI body invalidation: the WebView
        // already holds the rendered page, and reloading blows away
        // selection, scroll position, and any in-flight image loads.
        let nextCidCount = resolved.components(separatedBy: "data:").count - 1
        if resolved == context.coordinator.html,
           nextCidCount == context.coordinator.resolvedCidCount {
            return
        }
        context.coordinator.html = resolved
        context.coordinator.resolvedCidCount = nextCidCount
        webView.loadHTMLString(resolved, baseURL: nil)
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
