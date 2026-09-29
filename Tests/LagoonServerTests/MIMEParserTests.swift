import XCTest
import Foundation
@testable import LagoonServer

/// `MIMEParser` against realistic fixtures: GBK RFC2047 headers, nested
/// multipart, base64 / quoted-printable bodies — plus the malformed inputs a
/// real mailbox throws at the parser.
final class MIMEParserTests: XCTestCase {
    private func fixture(_ name: String, file: StaticString = #filePath) throws -> Data {
        let url = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/mime/\(name).eml")
        return try Data(contentsOf: url)
    }

    // MARK: - Headers

    func test_rfc2047_gbkSubject_decodesToChinese() throws {
        let raw = try fixture("rfc2047-gbk")
        let headers = MIMEParser.decodeHeaders(raw)
        XCTAssertEqual(headers["subject"], "项目周报：本周进度")
        XCTAssertEqual(headers["from"], "张三 <zhangsan@qq.com>")
    }

    func test_decodeHeaders_unfoldsContinuationLines() {
        let raw = Data("Subject: one\r\n two\r\nFrom: a@b\r\n\r\nbody".utf8)
        let headers = MIMEParser.decodeHeaders(raw)
        XCTAssertEqual(headers["subject"], "one two")
        XCTAssertEqual(headers["from"], "a@b")
    }

    /// A header that is already UTF-8 (no RFC2047) must survive untouched:
    /// decoding the header block must not mangle raw bytes.
    func test_decodeHeaders_rawUTF8Header_survives() {
        let raw = Data("Subject: 项目周报\r\n\r\n".utf8)
        XCTAssertEqual(MIMEParser.decodeHeaders(raw)["subject"], "项目周报")
    }

    /// RFC 2047 §6.2: whitespace between two adjacent encoded words is
    /// decoration for folding, not content.
    func test_decodeRFC2047_adjacentEncodedWords_joinWithoutSpace() {
        XCTAssertEqual(
            MIMEParser.decodeRFC2047("=?UTF-8?B?5L2g5aW9?= =?UTF-8?B?5LiW55WM?="),
            "你好世界"
        )
        XCTAssertEqual(MIMEParser.decodeRFC2047("Hello =?UTF-8?Q?World?=!"), "Hello World!")
        XCTAssertEqual(MIMEParser.decodeRFC2047("no encoded words"), "no encoded words")
    }

    // MARK: - Bodies

    func test_multipartAlternative_prefersPlainTextOverHTML() throws {
        let text = MIMEParser.plainText(from: try fixture("multipart-alternative"))
        XCTAssertTrue(text.contains("纯文本版本"))
        XCTAssertFalse(text.contains("<p>"))
        XCTAssertFalse(text.contains("HTML 版本"))
    }

    func test_multipartAlternative_htmlOnly_fallsBackToStrippedText() {
        let raw = Data(
            "Content-Type: text/html; charset=UTF-8\r\n\r\n<body><p>只有 HTML</p><p>第二段</p></body>".utf8
        )
        XCTAssertEqual(MIMEParser.plainText(from: raw), "只有 HTML 第二段")
    }

    func test_base64QuotedPrintable_decodesBothParts() throws {
        let base64Text = MIMEParser.plainText(from: try fixture("base64"))
        XCTAssertEqual(base64Text, "第一段：base64 编码正文。")

        let quotedPrintable = try fixture("quoted-printable")
        XCTAssertEqual(MIMEParser.plainText(from: quotedPrintable), "第二段：软换行已合并。")
        XCTAssertEqual(
            MIMEParser.decodeHeaders(quotedPrintable)["subject"],
            "QP 测试",
            "Q-encoding turns `_` into a space"
        )
    }

    func test_nestedMixed_findsInnermostTextAndSkipsAttachment() throws {
        let text = MIMEParser.plainText(from: try fixture("nested-mixed"))
        XCTAssertEqual(text, "最内层纯文本")
        XCTAssertFalse(text.contains("HTML"))
        XCTAssertFalse(text.contains("JVBERi0"), "attachment bytes are not body text")
    }

    /// Truncated and malformed input must degrade, never throw — the type is
    /// non-throwing on purpose, these assertions pin the degradation.
    func test_malformed_truncatedMime_returnsPartialTextWithoutThrowing() throws {
        let full = try fixture("nested-mixed")
        let truncated = Data(full.prefix(full.count / 2))
        XCTAssertFalse(MIMEParser.plainText(from: truncated).contains("<p>"))

        // Headers and no blank line: no body to extract.
        XCTAssertEqual(MIMEParser.plainText(from: Data("Subject: hi\r\nFrom: a@b".utf8)), "")

        // Unterminated boundary: the first part is still recoverable.
        // Split from the literal: the concatenation alone blows the type checker.
        let unterminatedRaw = "Content-Type: multipart/mixed; boundary=\"b\"\r\n"
            + "\r\n"
            + "--b\r\n"
            + "Content-Type: text/plain; charset=UTF-8\r\n"
            + "\r\n"
            + "部分正文"
        let unterminated = Data(unterminatedRaw.utf8)
        XCTAssertTrue(MIMEParser.plainText(from: unterminated).contains("部分正文"))

        XCTAssertEqual(MIMEParser.plainText(from: Data([0xFF, 0xFE, 0x00, 0x01])), "")
    }

    // MARK: - Charsets

    func test_charset_gb2312_mapsToGB18030Decoder() {
        XCTAssertEqual(
            MIMEParser.decodeCharset(Data([0xD6, 0xD0, 0xCE, 0xC4]), charset: "gb2312"),
            "中文"
        )
        XCTAssertEqual(
            MIMEParser.decodeCharset(Data([0xE4, 0xB8, 0xAD]), charset: "UTF-8"),
            "中"
        )
        XCTAssertEqual(MIMEParser.decodeCharset(Data("plain".utf8), charset: nil), "plain")
        // Unknown charset, undecodable bytes: byte-preserving Latin-1, never a
        // crash and never an empty string.
        XCTAssertFalse(
            MIMEParser.decodeCharset(Data([0x81, 0x40, 0xFF]), charset: "x-made-up").isEmpty
        )
    }

    /// The `BODY[]<0.N>` window can end mid multi-byte sequence. Strict UTF-8
    /// then fails for the whole buffer; without the tolerant path the entire
    /// Chinese body was decoded as Latin-1 mojibake.
    func test_charset_truncatedUTF8Tail_decodesReadableChineseNotLatin1() {
        let full = String(repeating: "这是一封测试邮件的正文内容。", count: 20)
        var bytes = Data(full.utf8)
        bytes.removeLast() // drop the last byte, cutting the final 3-byte scalar

        let decoded = MIMEParser.decodeCharset(bytes, charset: nil)

        XCTAssertTrue(decoded.hasPrefix("这是一封测试邮件的正文内容"), "got: \(decoded.prefix(20))")
        XCTAssertTrue(decoded.contains("\u{FFFD}"), "the truncated tail is marked, not invented")
        for signature in ["Ã", "å", "ä", "æ", "ç", "é", "è"] {
            XCTAssertFalse(decoded.contains(signature), "Latin-1 mojibake leaked: \(signature)")
        }
    }

    /// A valid UTF-8 buffer must still take the strict path: the tolerance is
    /// only for truncated input.
    func test_charset_validUTF8_keepsStrictResult() {
        let body = "合法的 UTF-8 正文：你好，世界。"
        let decoded = MIMEParser.decodeCharset(Data(body.utf8), charset: "utf-8")
        XCTAssertEqual(decoded, body)
        XCTAssertFalse(decoded.contains("\u{FFFD}"))
    }

    /// Genuine Latin-1 (no charset declaration) must still fall through to the
    /// Latin-1 fallback: each non-ASCII byte becomes a replacement scalar,
    /// which is far above the 1% tolerance, so the tolerant UTF-8 result is
    /// rejected.
    func test_charset_latin1Bytes_noCharset_keepsLatin1Fallback() {
        let short = Data([0x63, 0x61, 0x66, 0xE9]) // "caf" + é
        XCTAssertEqual(MIMEParser.decodeCharset(short, charset: nil), "café")

        // Even a long run of Latin-1 keeps the fallback: 200/200 replacements.
        let long = Data(repeating: 0xE9, count: 200)
        let decoded = MIMEParser.decodeCharset(long, charset: nil)
        XCTAssertEqual(decoded.count, 200)
        XCTAssertEqual(decoded.first, "é")
    }

    /// An explicit `gb18030`/`gbk` declaration is untouched by the UTF-8
    /// tolerance.
    func test_charset_explicitGB18030_unaffectedByUTF8Tolerance() {
        let bytes = Data([0xD6, 0xD0, 0xCE, 0xC4])
        XCTAssertEqual(MIMEParser.decodeCharset(bytes, charset: "gb18030"), "中文")
        XCTAssertEqual(MIMEParser.decodeCharset(bytes, charset: "GBK"), "中文")
    }

    func test_decodeQuotedPrintable_softBreakAndInvalidEscape() {
        let encoded = Data("line one=\r\nline two=0A=3Dend=ZZ".utf8)
        XCTAssertEqual(
            String(decoding: MIMEParser.decodeQuotedPrintable(encoded), as: UTF8.self),
            "line oneline two\n=end=ZZ"
        )
    }

    // MARK: - M1.6 parse() surface (attachments + html)

    /// `multipart/mixed` with a text body and a PDF attachment. The PDF lands
    /// in `attachments` (not silently dropped like in v0.2.0), with a stable
    /// IMAP part-path id and the original filename from Content-Disposition.
    func test_parse_multipartMixed_textAndPdfAttachment_listsAttachment() {
        let pdfBytes = Data("%PDF-1.4 fake body".utf8)
        let pdfBase64 = pdfBytes.base64EncodedString()
        let raw = """
        Content-Type: multipart/mixed; boundary="b"

        --b
        Content-Type: text/plain; charset=UTF-8

        See attached PDF for details.
        --b
        Content-Type: application/pdf
        Content-Disposition: attachment; filename="report.pdf"
        Content-Transfer-Encoding: base64

        \(pdfBase64)
        --b--
        """.replacingOccurrences(of: "\n", with: "\r\n")
        let message = Data(raw.utf8)

        let parsed = MIMEParser.parse(message: message, decodeAttachmentBytes: true)
        XCTAssertEqual(parsed.text, "See attached PDF for details.")
        XCTAssertNil(parsed.html)
        XCTAssertEqual(parsed.attachments.count, 1)
        let att = parsed.attachments[0]
        XCTAssertEqual(att.id, "1.2")
        XCTAssertEqual(att.filename, "report.pdf")
        XCTAssertEqual(att.mimeType, "application/pdf")
        XCTAssertEqual(att.disposition, .attachment)
        XCTAssertEqual(att.size, pdfBytes.count)
        XCTAssertEqual(att.data, pdfBytes)
        XCTAssertNil(att.contentId)
        XCTAssertFalse(parsed.hasMore)
    }

    /// `multipart/related` HTML with a Content-ID-tagged inline image. The
    /// image surfaces in `attachments` with `disposition = .inline` and a
    /// `contentId` the client will later match against `cid:...` HTML refs.
    func test_parse_multipartRelated_htmlWithInlineImage_cidMatchesContentId() {
        // 1x1 transparent PNG.
        let pngBytes = Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
            0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
            0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x62, 0x00, 0x01, 0x00, 0x00,
            0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
            0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
        ])
        let pngBase64 = pngBytes.base64EncodedString()
        let raw = """
        Content-Type: multipart/related; boundary="r"

        --r
        Content-Type: text/html; charset=UTF-8

        <html><body><img src="cid:logo@example.com">hi</body></html>
        --r
        Content-Type: image/png
        Content-ID: <logo@example.com>
        Content-Disposition: inline
        Content-Transfer-Encoding: base64

        \(pngBase64)
        --r--
        """.replacingOccurrences(of: "\n", with: "\r\n")
        let message = Data(raw.utf8)

        let parsed = MIMEParser.parse(message: message, decodeAttachmentBytes: true)
        XCTAssertNotNil(parsed.html)
        XCTAssertTrue(parsed.html!.contains("cid:logo@example.com"))
        XCTAssertEqual(parsed.attachments.count, 1)
        let att = parsed.attachments[0]
        XCTAssertEqual(att.mimeType, "image/png")
        XCTAssertEqual(att.disposition, .inline)
        XCTAssertEqual(att.contentId, "logo@example.com")
        XCTAssertEqual(att.data, pngBytes)
    }

    /// An image with no explicit disposition still lands as inline so HTML
    /// `cid:` references can find it. The MIME spec is fuzzy here; the safe
    /// default for `image/*` is inline.
    func test_parse_imageWithoutDisposition_defaultsToInline() {
        let raw = """
        Content-Type: multipart/mixed; boundary="b"

        --b
        Content-Type: text/plain

        body
        --b
        Content-Type: image/png

        00
        --b--
        """.replacingOccurrences(of: "\n", with: "\r\n")
        let parsed = MIMEParser.parse(message: Data(raw.utf8))
        XCTAssertEqual(parsed.attachments.count, 1)
        XCTAssertEqual(parsed.attachments[0].disposition, .inline)
    }

    /// `Content-Disposition: attachment` wins over an `image/*` mime type —
    /// the explicit disposition always takes precedence.
    func test_parse_attachmentDisposition_evenWithImageMimeType_landsInAttachments() {
        let raw = """
        Content-Type: multipart/mixed; boundary="b"

        --b
        Content-Type: text/plain

        see attached
        --b
        Content-Type: image/png
        Content-Disposition: attachment; filename="screenshot.png"

        00
        --b--
        """.replacingOccurrences(of: "\n", with: "\r\n")
        let parsed = MIMEParser.parse(message: Data(raw.utf8))
        XCTAssertEqual(parsed.attachments.count, 1)
        XCTAssertEqual(parsed.attachments[0].disposition, .attachment)
        XCTAssertEqual(parsed.attachments[0].filename, "screenshot.png")
    }

    /// Truncation: a body that exceeds `MIMEParser.textCap` is cut and the
    /// `hasMore` flag is set so the client can warn the user.
    func test_parse_textTruncatesAtCap_andFlagsHasMore() {
        let big = String(repeating: "a", count: MIMEParser.textCap + 100)
        let raw = "Content-Type: text/plain; charset=UTF-8\r\n\r\n\(big)"
        let parsed = MIMEParser.parse(message: Data(raw.utf8))
        XCTAssertTrue(parsed.hasMore)
        XCTAssertLessThanOrEqual(parsed.text.count, MIMEParser.textCap + 64) // +truncation marker
    }

    // MARK: - RFC 5322 address list (reply-all)

    /// The plain case: `Name <addr>` and bare addresses mixed.
    func test_addressList_mixedBareAndBracketed() {
        let parsed = MIMEParser.parseAddressList(
            "Alice <alice@example.com>, bob@example.com, \"Carol\" <carol@x.org>"
        )
        XCTAssertEqual(parsed, ["alice@example.com", "bob@example.com", "carol@x.org"])
    }

    /// A comma inside a quoted display name must not split the list.
    /// This is the case that breaks a naive `split(",")`.
    func test_addressList_quotedCommaStaysOneRecipient() {
        let parsed = MIMEParser.parseAddressList(
            "\"Smith, John\" <john@example.com>, other@example.com"
        )
        XCTAssertEqual(parsed, ["john@example.com", "other@example.com"])
    }

    /// A comma inside angle brackets must not split either.
    func test_addressList_commaInsideAngleBrackets() {
        let parsed = MIMEParser.parseAddressList("\"weird, name\" <a@b.com>")
        XCTAssertEqual(parsed, ["a@b.com"])
    }

    /// A display name with no address is junk and gets dropped rather
    /// than becoming a recipient.
    func test_addressList_displayNameWithoutAddress_isSkipped() {
        let parsed = MIMEParser.parseAddressList("Just A Name, real@example.com")
        XCTAssertEqual(parsed, ["real@example.com"])
    }

    func test_addressList_emptyInputYieldsEmpty() {
        XCTAssertEqual(MIMEParser.parseAddressList(""), [])
        XCTAssertEqual(MIMEParser.parseAddressList("   "), [])
    }

    /// `To:` / `Cc:` come off the top-level headers, addresses only.
    func test_parse_extractsToAndCc() {
        let raw = """
        From: sender@example.com
        To: Alice <alice@example.com>, bob@example.com
        Cc: "Smith, Carol" <carol@example.com>
        Subject: hi

        body
        """.replacingOccurrences(of: "\n", with: "\r\n")
        let parsed = MIMEParser.parse(message: Data(raw.utf8))
        XCTAssertEqual(parsed.to, ["alice@example.com", "bob@example.com"])
        XCTAssertEqual(parsed.cc, ["carol@example.com"])
    }

    /// Both `text/plain` and `text/html` are returned when present, so the
    /// client can pick the rendered variant. The plain-text body is also
    /// populated for search / accessibility.
    func test_parse_multipartAlternative_returnsBothPlainAndHtml() {
        let raw = """
        Content-Type: multipart/alternative; boundary="a"

        --a
        Content-Type: text/plain; charset=UTF-8

        hello world
        --a
        Content-Type: text/html; charset=UTF-8

        <p>hello <b>world</b></p>
        --a--
        """.replacingOccurrences(of: "\n", with: "\r\n")
        let parsed = MIMEParser.parse(message: Data(raw.utf8))
        XCTAssertEqual(parsed.text, "hello world")
        XCTAssertEqual(parsed.html, "<p>hello <b>world</b></p>")
        XCTAssertTrue(parsed.attachments.isEmpty)
    }

    // MARK: - message/rfc822

    /// A forwarded `.eml` that comes before the real body. Recursing into it
    /// without registering it as an attachment loses the forward entirely
    /// (nothing in `attachments`, so nothing in the UI to download) and lets
    /// the forwarded text stand in for the sender's actual message.
    func test_parse_forwardedMessageFirst_keepsRealBodyAndListsTheForward() throws {
        let raw = """
        Content-Type: multipart/mixed; boundary="m"

        --m
        Content-Type: message/rfc822
        Content-Disposition: attachment; filename="forwarded.eml"

        From: someone@else.example
        Subject: forwarded
        Content-Type: text/plain

        FORWARDED BODY
        --m
        Content-Type: text/plain; charset=UTF-8

        THE REAL BODY
        --m--
        """.replacingOccurrences(of: "\n", with: "\r\n")
        let parsed = MIMEParser.parse(message: Data(raw.utf8), decodeAttachmentBytes: true)

        XCTAssertEqual(parsed.text, "THE REAL BODY")
        XCTAssertEqual(parsed.attachments.count, 1)
        let forward = try XCTUnwrap(parsed.attachments.first)
        XCTAssertEqual(forward.id, "1.1", "the id must address the .eml part itself")
        XCTAssertEqual(forward.filename, "forwarded.eml")
        XCTAssertEqual(forward.mimeType, "message/rfc822")
        XCTAssertEqual(forward.disposition, .attachment)
        XCTAssertTrue(String(decoding: forward.data, as: UTF8.self).contains("FORWARDED BODY"))
    }

    /// Same message, forward *after* the body: the forward must still be
    /// downloadable, and must not displace the body that was seen first.
    func test_parse_forwardedMessageLast_listsTheForwardWithoutStealingTheBody() {
        let raw = """
        Content-Type: multipart/mixed; boundary="m"

        --m
        Content-Type: text/plain; charset=UTF-8

        THE REAL BODY
        --m
        Content-Type: message/rfc822
        Content-Disposition: attachment; filename="forwarded.eml"

        Subject: forwarded
        Content-Type: text/plain

        FORWARDED BODY
        --m--
        """.replacingOccurrences(of: "\n", with: "\r\n")
        let parsed = MIMEParser.parse(message: Data(raw.utf8))

        XCTAssertEqual(parsed.text, "THE REAL BODY")
        XCTAssertEqual(parsed.attachments.map(\.id), ["1.2"])
        XCTAssertEqual(parsed.attachments.first?.filename, "forwarded.eml")
    }

    /// An inline forward is meant to be read, so its text joins the body — but
    /// it still has to be a downloadable attachment, and its HTML must not
    /// become the message's HTML: the detail view renders `html` in preference
    /// to `text`, which would hide the sender's real message.
    func test_parse_inlineForwardedMessage_contributesTextButNotHtml() throws {
        let raw = """
        Content-Type: multipart/mixed; boundary="m"

        --m
        Content-Type: text/plain; charset=UTF-8

        THE REAL BODY
        --m
        Content-Type: message/rfc822

        Subject: forwarded
        Content-Type: text/html

        <p>FORWARDED HTML</p>
        --m--
        """.replacingOccurrences(of: "\n", with: "\r\n")
        let parsed = MIMEParser.parse(message: Data(raw.utf8), decodeAttachmentBytes: true)

        XCTAssertEqual(parsed.text, "THE REAL BODY", "the real body was seen first and must win")
        XCTAssertNil(parsed.html, "a forwarded message must not become the message's html")
        XCTAssertEqual(parsed.attachments.map(\.id), ["1.2"])
        XCTAssertEqual(parsed.attachments.first?.disposition, .inline)
        let forward = try XCTUnwrap(parsed.attachments.first)
        XCTAssertTrue(String(decoding: forward.data, as: UTF8.self).contains("FORWARDED HTML"))
    }

    /// The recursion numbers its child under the forwarding part, so an
    /// attachment *inside* the forward cannot claim the forward's own id.
    func test_parse_inlineForward_itsOwnAttachmentGetsADistinctId() {
        let raw = """
        Content-Type: multipart/mixed; boundary="m"

        --m
        Content-Type: message/rfc822

        Content-Type: multipart/mixed; boundary="i"

        --i
        Content-Type: text/plain

        forwarded text
        --i
        Content-Type: application/pdf
        Content-Disposition: attachment; filename="inner.pdf"

        inner
        --i--
        --m--
        """.replacingOccurrences(of: "\n", with: "\r\n")
        let parsed = MIMEParser.parse(message: Data(raw.utf8))

        let ids = parsed.attachments.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "ids must be unique: \(ids)")
        XCTAssertTrue(ids.contains("1.1"), "the forwarded .eml itself: \(ids)")
        XCTAssertTrue(ids.contains("1.1.2"), "the attachment inside it: \(ids)")
    }

    // MARK: - LF-only line endings

    /// LF-only line endings are accepted by the header split, so they must be
    /// accepted by the boundary search too. A `--boundary` is only recognized
    /// after CRLF, which used to collapse the whole message into one part: the
    /// base64 of the PDF landed in the body text and the attachment list came
    /// back empty.
    func test_parse_lfOnlyMultipartMixed_keepsAttachmentsOutOfTheBody() throws {
        let pdfBytes = Data("%PDF-1.4 test".utf8)
        let raw = """
        Content-Type: multipart/mixed; boundary="b"

        --b
        Content-Type: text/plain; charset=UTF-8

        Hello
        --b
        Content-Type: application/pdf
        Content-Transfer-Encoding: base64
        Content-Disposition: attachment; filename="report.pdf"

        \(pdfBytes.base64EncodedString())
        --b--
        """
        let parsed = MIMEParser.parse(message: Data(raw.utf8), decodeAttachmentBytes: true)

        XCTAssertEqual(parsed.text, "Hello")
        XCTAssertEqual(parsed.attachments.count, 1)
        let attachment = try XCTUnwrap(parsed.attachments.first)
        XCTAssertEqual(attachment.filename, "report.pdf")
        XCTAssertEqual(attachment.data, pdfBytes)
        XCTAssertFalse(parsed.hasMore)
    }

    /// The same message with CRLF must parse identically — the fix reframes
    /// LF-only bodies, and a CRLF body must not gain a second CR anywhere.
    func test_parse_crlfMultipartMixed_isUnaffectedByTheReframing() {
        let pdfBytes = Data("%PDF-1.4 test".utf8)
        let raw = """
        Content-Type: multipart/mixed; boundary="b"

        --b
        Content-Type: text/plain; charset=UTF-8

        Hello
        --b
        Content-Type: application/pdf
        Content-Transfer-Encoding: base64
        Content-Disposition: attachment; filename="report.pdf"

        \(pdfBytes.base64EncodedString())
        --b--
        """.replacingOccurrences(of: "\n", with: "\r\n")
        let parsed = MIMEParser.parse(message: Data(raw.utf8), decodeAttachmentBytes: true)

        XCTAssertEqual(parsed.text, "Hello")
        XCTAssertEqual(parsed.attachments.count, 1)
        XCTAssertEqual(parsed.attachments[0].data, pdfBytes)
    }

    /// `multipart/alternative` with LF endings used to keep one part, so the
    /// HTML variant vanished into the text and the detail view fell back to
    /// plain text.
    func test_parse_lfOnlyMultipartAlternative_keepsTheHTMLVariant() {
        let raw = """
        Content-Type: multipart/alternative; boundary="a"

        --a
        Content-Type: text/plain; charset=UTF-8

        plain version
        --a
        Content-Type: text/html; charset=UTF-8

        <p>HTML version</p>
        --a--
        """
        let parsed = MIMEParser.parse(message: Data(raw.utf8))

        XCTAssertEqual(parsed.text, "plain version")
        XCTAssertEqual(parsed.html, "<p>HTML version</p>")
    }

    // MARK: - RFC 5987 filenames

    /// `filename*=UTF-8''…` is percent-encoded and names its own charset.
    /// Neither the escapes nor the `UTF-8''` prefix may reach the UI — the
    /// attachment row shows `filename` verbatim.
    func test_parse_filenameStarExtendedParameter_decodesToTheRealName() {
        let raw = """
        Content-Type: multipart/mixed; boundary="b"

        --b
        Content-Type: text/plain

        body
        --b
        Content-Type: application/pdf
        Content-Disposition: attachment; filename*=UTF-8''%E6%8A%A5%E5%91%8A%20Q3.pdf

        %PDF
        --b--
        """.replacingOccurrences(of: "\n", with: "\r\n")
        let parsed = MIMEParser.parse(message: Data(raw.utf8))

        XCTAssertEqual(parsed.attachments.count, 1)
        XCTAssertEqual(parsed.attachments[0].filename, "报告 Q3.pdf")
    }

    /// The same extended form on `Content-Type; name*` — the parameter the
    /// parser never even looked at, so the filename was simply missing and the
    /// row fell back to showing the mime type.
    func test_parse_contentTypeNameStarExtendedParameter_decodesToTheRealName() {
        let raw = """
        Content-Type: multipart/mixed; boundary="b"

        --b
        Content-Type: text/plain

        body
        --b
        Content-Type: application/pdf; name*=UTF-8''%E6%8A%A5%E5%91%8A.pdf
        Content-Disposition: attachment

        %PDF
        --b--
        """.replacingOccurrences(of: "\n", with: "\r\n")
        let parsed = MIMEParser.parse(message: Data(raw.utf8))

        XCTAssertEqual(parsed.attachments.count, 1)
        XCTAssertEqual(parsed.attachments[0].filename, "报告.pdf")
    }

    /// RFC 6266 §4.3: a sender that sends both forms keeps the plain one.
    func test_parse_filename_prefersPlainFormOverExtendedForm() {
        let raw = """
        Content-Type: multipart/mixed; boundary="b"

        --b
        Content-Type: text/plain

        body
        --b
        Content-Type: application/pdf
        Content-Disposition: attachment; filename="report.pdf"; filename*=UTF-8''%E6%8A%A5.pdf

        %PDF
        --b--
        """.replacingOccurrences(of: "\n", with: "\r\n")
        let parsed = MIMEParser.parse(message: Data(raw.utf8))

        XCTAssertEqual(parsed.attachments.first?.filename, "report.pdf")
    }
}
