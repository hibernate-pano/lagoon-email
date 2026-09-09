import XCTest
@testable import LagoonServer

/// Covers `GmailBodyExtractor` (Sources/LagoonServer/Gmail/GmailBodyExtractor.swift):
/// MIME tree walking, HTML→text fallback, entity decoding, whitespace collapse
/// and the "never throws, degrade to a string" contract.
final class GmailBodyExtractorTests: XCTestCase {

    // MARK: - Helpers

    private func part(
        _ mimeType: String?,
        _ data: String?,
        parts: [RawGmailMessage.Payload]? = nil,
        bodyPresent: Bool = true,
        headers: [RawGmailMessage.Header]? = nil
    ) -> RawGmailMessage.Payload {
        RawGmailMessage.Payload(
            headers: headers,
            mimeType: mimeType,
            body: bodyPresent ? RawGmailMessage.Body(data: data, size: nil) : nil,
            parts: parts
        )
    }

    private func base64(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
    }

    /// URL-safe, padding-stripped base64, exactly how Gmail emits body bytes.
    private func base64URL(_ text: String) -> String {
        base64(text)
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - MIME tree preference

    /// A nested text/plain part wins even when a text/html sibling comes first.
    func test_prefersNestedPlainOverHTML() {
        let payload = part("multipart/alternative", nil, parts: [
            part("text/html", base64URL("<p>Hello html</p>")),
            part("text/plain", base64URL("Hello plain"))
        ])
        XCTAssertEqual(GmailBodyExtractor.plainText(from: payload), "Hello plain")
    }

    /// A text/plain part nested several levels deep is still found.
    func test_prefersDeeplyNestedPlain() {
        let payload = part("multipart/mixed", nil, parts: [
            part("multipart/alternative", nil, parts: [
                part("text/html", base64URL("<b>html</b>")),
                part("text/plain", base64URL("deep plain"))
            ])
        ])
        XCTAssertEqual(GmailBodyExtractor.plainText(from: payload), "deep plain")
    }

    /// No text/plain anywhere → strip the text/html part.
    func test_fallsBackToHTMLWhenNoPlain() {
        let payload = part("text/html", base64URL("<p>Hello <b>world</b></p>"))
        XCTAssertEqual(GmailBodyExtractor.plainText(from: payload), "Hello world")
    }

    /// Single-part payload with no mimeType but bytes → HTML-strip fallback.
    func test_rootPartWithoutMimeType_usesFallback() {
        let payload = part(nil, base64URL("<p>Bare root</p>"))
        XCTAssertEqual(GmailBodyExtractor.plainText(from: payload), "Bare root")
    }

    /// A text/plain part with `body.data == nil` (Gmail oversized/attachment-only)
    /// is skipped in favour of a usable text/html sibling.
    func test_plainWithoutData_fallsThroughToHTML() {
        let payload = part("multipart/alternative", nil, parts: [
            part("text/plain", nil),  // data omitted, e.g. oversized
            part("text/html", base64URL("<p>fallback</p>"))
        ])
        XCTAssertEqual(GmailBodyExtractor.plainText(from: payload), "fallback")
    }

    // MARK: - HTML → text

    func test_removesScriptAndStyleContent() {
        let html = """
        <html><head><style>.a { color: red; }</style></head>
        <body><script>alert('pwned')</script><p>Visible text</p></body></html>
        """
        let out = GmailBodyExtractor.plainText(from: part("text/html", base64URL(html)))
        XCTAssertEqual(out, "Visible text")
        XCTAssertFalse(out.contains("pwned"))
        XCTAssertFalse(out.contains("color"))
    }

    func test_decodesNamedEntities() {
        let html = "Tom &amp; Jerry &lt;3 &gt; 2 &quot;hi&quot;&nbsp;there"
        let out = GmailBodyExtractor.plainText(from: part("text/html", base64URL(html)))
        XCTAssertEqual(out, "Tom & Jerry <3 > 2 \"hi\" there")
    }

    func test_decodesNumericEntities() {
        let html = "It&#39;s &#x27;fine&#x27;"
        let out = GmailBodyExtractor.plainText(from: part("text/html", base64URL(html)))
        XCTAssertEqual(out, "It's 'fine'")
    }

    func test_collapsesWhitespaceInHTML() {
        let html = "<div>alpha</div>\n\n   <div>beta\t gamma</div>"
        let out = GmailBodyExtractor.plainText(from: part("text/html", base64URL(html)))
        XCTAssertEqual(out, "alpha beta gamma")
    }

    func test_collapseWhitespace_helper() {
        XCTAssertEqual(GmailBodyExtractor.collapseWhitespace("a\n\n   b\t c  "), "a b c")
    }

    /// text/plain is trimmed but internal whitespace is preserved (only the
    /// HTML path collapses).
    func test_trimsPlainText() {
        let out = GmailBodyExtractor.plainText(
            from: part("text/plain", base64URL("\n   Hello\n\nWorld  \n"))
        )
        XCTAssertEqual(out, "Hello\n\nWorld")
    }

    // MARK: - base64url

    func test_base64URLDecode_missingPadding() {
        // "Hello, World!" is 13 bytes → standard base64 needs "==" padding.
        XCTAssertEqual(base64("Hello, World!"), "SGVsbG8sIFdvcmxkIQ==")
        let decoded = GmailBodyExtractor.base64URLDecode("SGVsbG8sIFdvcmxkIQ")
        XCTAssertEqual(decoded, Data("Hello, World!".utf8))
    }

    func test_base64URLDecode_urlSafeChars() {
        // 0xFF 0xFF 0xFE → standard "///+", URL-safe "___-".
        let decoded = GmailBodyExtractor.base64URLDecode("___-")
        XCTAssertEqual(decoded, Data([0xFF, 0xFF, 0xFE]))
    }

    func test_base64URLDecode_plainTextRoundTrip() {
        let text = "Subject: café — 日本語 ✉"
        let url = base64URL(text)
        let decoded = GmailBodyExtractor.base64URLDecode(url)
        XCTAssertEqual(decoded.flatMap { String(data: $0, encoding: .utf8) }, text)
    }

    // MARK: - Degradation contract (never throws)

    func test_nilPayload_returnsEmpty() {
        XCTAssertEqual(GmailBodyExtractor.plainText(from: nil), "")
    }

    func test_missingBodyData_returnsEmpty() {
        // Gmail omits body.data for oversized messages (attachmentId only).
        let payload = part("text/plain", nil, bodyPresent: true)
        XCTAssertEqual(GmailBodyExtractor.plainText(from: payload), "")
    }

    func test_nilBody_returnsEmpty() {
        let payload = part("text/plain", nil, bodyPresent: false)
        XCTAssertEqual(GmailBodyExtractor.plainText(from: payload), "")
    }

    func test_malformedBase64_returnsEmpty() {
        let payload = part("text/plain", "@@@ not base64 @@@")
        XCTAssertEqual(GmailBodyExtractor.plainText(from: payload), "")
    }

    func test_malformedBase64_doesNotThrow() {
        // Explicitly exercise the no-throw contract for garbage in every slot.
        for garbage in ["", "!!!!", "a b c", "\u{FFFD}\u{FFFD}", "@@@ nope @@@", "not-base64-"] {
            let payload = part("text/plain", garbage)
            XCTAssertEqual(
                GmailBodyExtractor.plainText(from: payload), "",
                "expected \"\" for malformed base64 \(String(reflecting: garbage))"
            )
        }
    }

    /// Regression: an all-padding base64url string must be rejected, not
    /// decoded to a NUL byte. `Data(base64Encoded: "====")` returns
    /// `Data([0x00])` on this platform, so `base64URLDecode`
    /// (Sources/LagoonServer/Gmail/GmailBodyExtractor.swift) guards against
    /// padding-only input; `plainText` then yields "" per its contract.
    func test_allPaddingBase64_isRejected() {
        for input in ["=", "==", "===", "====", "  ==  "] {
            XCTAssertNil(
                GmailBodyExtractor.base64URLDecode(input),
                "padding-only input must not decode: \(String(reflecting: input))"
            )
            XCTAssertEqual(
                GmailBodyExtractor.plainText(from: part("text/plain", input)), "",
                "padding-only body must yield empty text: \(String(reflecting: input))"
            )
        }
    }

    func test_oversizedBody_isCappedNotUnbounded() {
        // decodeBody caps decoded bytes at maxDecodedBytes (4 MiB) and never
        // returns the whole payload.
        let huge = String(repeating: "a", count: GmailBodyExtractor.maxDecodedBytes + 1_024)
        let payload = part("text/plain", base64URL(huge))
        let out = GmailBodyExtractor.plainText(from: payload)
        XCTAssertEqual(out.count, GmailBodyExtractor.maxDecodedBytes)
    }

    // MARK: - Charset handling

    /// "not-base64-" is valid base64url alphabet-wise and decodes to 8 bytes
    /// that are not valid UTF-8. Before the charset fix the extractor fell back
    /// to Latin-1 and returned garbage ("~m«ë…") as body text — which then
    /// reached the LLM prompt. It must now degrade to "".
    func test_nonUTF8Bytes_withoutDeclaredCharset_returnsEmpty() {
        XCTAssertNotNil(
            GmailBodyExtractor.base64URLDecode("not-base64-"),
            "sanity: the input is valid base64url, so the decoder is not the guard"
        )
        let payload = part("text/plain", "not-base64-")
        XCTAssertEqual(GmailBodyExtractor.plainText(from: payload), "")
    }

    /// Regression guard for the fix: a genuinely Latin-1 body must still
    /// decode, because the part declares that charset.
    func test_declaredLatin1Charset_stillDecodes() {
        let latin1 = Data([0x63, 0x61, 0x66, 0xE9])  // "café" in ISO-8859-1
        let payload = part(
            "text/plain",
            latin1.base64EncodedString(),
            headers: [.init(name: "Content-Type", value: "text/plain; charset=iso-8859-1")]
        )
        XCTAssertEqual(GmailBodyExtractor.plainText(from: payload), "café")
    }

    /// A charset we do not understand is refused rather than guessed.
    func test_nonUTF8Bytes_withUnknownDeclaredCharset_returnsEmpty() {
        let payload = part(
            "text/plain",
            "not-base64-",
            headers: [.init(name: "Content-Type", value: "text/plain; charset=shift_jis")]
        )
        XCTAssertEqual(GmailBodyExtractor.plainText(from: payload), "")
    }

    func test_declaredCharset_parsesQuotedUnquotedAndMissing() {
        func payload(_ contentType: String?) -> RawGmailMessage.Payload {
            part(
                "text/plain",
                "",
                headers: contentType.map { [RawGmailMessage.Header(name: "Content-Type", value: $0)] }
            )
        }
        XCTAssertEqual(
            GmailBodyExtractor.declaredCharset(payload("text/plain; charset=\"ISO-8859-1\"")),
            "iso-8859-1"
        )
        XCTAssertEqual(
            GmailBodyExtractor.declaredCharset(payload("text/plain;charset=utf-8")),
            "utf-8"
        )
        XCTAssertNil(GmailBodyExtractor.declaredCharset(payload("text/plain")))
        XCTAssertNil(GmailBodyExtractor.declaredCharset(payload(nil)))
    }
}
