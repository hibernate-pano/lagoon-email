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
        let unterminated = Data(
            ("Content-Type: multipart/mixed; boundary=\"b\"\r\n"
                + "\r\n"
                + "--b\r\n"
                + "Content-Type: text/plain; charset=UTF-8\r\n"
                + "\r\n"
                + "部分正文").utf8
        )
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

    func test_decodeQuotedPrintable_softBreakAndInvalidEscape() {
        let encoded = Data("line one=\r\nline two=0A=3Dend=ZZ".utf8)
        XCTAssertEqual(
            String(decoding: MIMEParser.decodeQuotedPrintable(encoded), as: UTF8.self),
            "line oneline two\n=end=ZZ"
        )
    }
}
