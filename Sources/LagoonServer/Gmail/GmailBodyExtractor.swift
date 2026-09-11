import Foundation

/// Best-effort plain-text extraction from a Gmail `format=full` MIME payload.
///
/// Gmail base64url-encodes body bytes and, for oversized messages, omits
/// `body.data` entirely (only an `attachmentId` is returned). This extractor
/// never throws: a missing, undecodable or oversized body degrades to a shorter
/// string (possibly "") rather than failing the request.
///
/// ponytail: plain text is enough for M1 (read + summarize). Rich HTML
/// rendering, inline images and attachment parsing are out of scope.
public enum GmailBodyExtractor {
    /// Upper bound on the bytes we decode per message. A 4 MiB text body is
    /// far larger than anything the UI or an LLM prompt needs; beyond this we
    /// truncate instead of risking unbounded memory.
    public static let maxDecodedBytes = 4 * 1024 * 1024

    /// Plain-text body: prefer `text/plain` anywhere in the MIME tree, fall
    /// back to stripping `text/html`, then to any body bytes on the root part.
    public static func plainText(from payload: RawGmailMessage.Payload?) -> String {
        guard let payload else { return "" }

        if let part = findPart(payload, mimeType: "text/plain"),
           let text = decodeBody(part) {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let part = findPart(payload, mimeType: "text/html"),
           let html = decodeBody(part) {
            return stripHTML(html)
        }
        // Single-part payloads sometimes omit mimeType but still carry bytes.
        if let html = decodeBody(payload) {
            return stripHTML(html)
        }
        return ""
    }

    // MARK: - MIME tree

    /// Depth-first search for the first part with `mimeType` that actually
    /// carries body bytes. Nested multipart/alternative and multipart/related
    /// trees are walked in order, so the first text/plain wins.
    static func findPart(
        _ part: RawGmailMessage.Payload,
        mimeType: String
    ) -> RawGmailMessage.Payload? {
        if part.mimeType?.lowercased() == mimeType, part.body?.data != nil {
            return part
        }
        for child in part.parts ?? [] {
            if let found = findPart(child, mimeType: mimeType) {
                return found
            }
        }
        return nil
    }

    /// Decode a part's base64url bytes to text.
    ///
    /// UTF-8 is required unless the part declares a single-byte Latin-1
    /// charset. An earlier version fell back to Latin-1 for *any* non-UTF-8
    /// byte string, which turned undecodable garbage into body text — and that
    /// text is what reaches the LLM prompt. Undecodable bytes now return nil,
    /// so `plainText` degrades to "" instead of inventing characters.
    static func decodeBody(_ part: RawGmailMessage.Payload) -> String? {
        guard let encoded = part.body?.data else { return nil }
        guard let decoded = base64URLDecode(encoded) else { return nil }
        let capped = Data(decoded.prefix(maxDecodedBytes))
        if let utf8 = String(data: capped, encoding: .utf8) { return utf8 }
        guard let charset = declaredCharset(part), latin1Charsets.contains(charset) else {
            return nil
        }
        return String(data: capped, encoding: .isoLatin1)
    }

    /// Charsets we decode as single-byte Latin-1 when the bytes are not valid
    /// UTF-8. Anything else is refused rather than guessed.
    static let latin1Charsets: Set<String> = [
        "iso-8859-1", "iso8859-1", "latin-1", "latin1", "us-ascii"
    ]

    /// `charset=` from the part's own Content-Type header, lowercased. Gmail's
    /// `format=full` carries per-part headers, so the declared charset is
    /// usually available; when it is not, we refuse to guess.
    static func declaredCharset(_ part: RawGmailMessage.Payload) -> String? {
        guard let header = part.headers?.first(where: {
            $0.name.caseInsensitiveCompare("content-type") == .orderedSame
        }) else { return nil }
        for parameter in header.value.split(separator: ";").dropFirst() {
            let pair = parameter.split(separator: "=", maxSplits: 1)
            guard pair.count == 2,
                  pair[0].trimmingCharacters(in: .whitespaces)
                      .caseInsensitiveCompare("charset") == .orderedSame
            else { continue }
            let value = pair[1]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                .lowercased()
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// Gmail uses URL-safe base64 (`-`/`_`) and often omits `=` padding.
    static func base64URLDecode(_ value: String) -> Data? {
        var normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Reject padding-only input: `Data(base64Encoded: "====")` returns a
        // single NUL byte instead of nil, which would surface as "\0" body text.
        guard normalized.contains(where: { $0 != "=" }) else { return nil }
        let remainder = normalized.count % 4
        if remainder > 0 {
            normalized += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: normalized)
    }

    // MARK: - HTML → text

    /// Remove scripts/styles/tags, decode entities, collapse whitespace.
    /// The implementation moved to `HTMLText` so the IMAP MIME parser can reuse
    /// it; this stays as the Gmail-facing name.
    static func stripHTML(_ html: String) -> String {
        HTMLText.strip(html)
    }

    /// Named entities plus numeric `&#123;` / `&#x1F600;` forms. Unknown
    /// entities are left untouched.
    static func decodeHTMLEntities(_ value: String) -> String {
        HTMLText.decodeEntities(value)
    }

    static func collapseWhitespace(_ value: String) -> String {
        HTMLText.collapseWhitespace(value)
    }
}
