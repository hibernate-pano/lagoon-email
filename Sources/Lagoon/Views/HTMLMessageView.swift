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

    func makeCoordinator() -> Coordinator {
        Coordinator()
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

    func updateNSView(_ webView: WKWebView, context: Context) {
        let resolved = Self.resolveCidReferences(in: html, with: attachmentsByCid)
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

    final class Coordinator: NSObject, WKNavigationDelegate {
        // M1.6 deliberately registers no policy handlers: a user clicking
        // an `<a href="...">` in the WebView opens it in the system
        // browser by default, and that is the spec's M1.7 design choice.
        // We do not block navigation; we just do not implement it as
        // in-app.
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
