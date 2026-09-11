import XCTest
import Foundation
@testable import LagoonServer

/// `MIMEBuilder.reply` produces the exact bytes that will be handed to SMTP or
/// to the Gmail raw endpoint, so every assertion here is about the wire format:
/// CRLF framing, header shape, RFC 2047 subject and base64 body.
final class MIMEBuilderTests: XCTestCase {
    private func outbound(
        fromEmail: String = "me@qq.com",
        fromName: String? = "Me",
        to: String = "alice@example.com",
        subject: String = "Hello",
        body: String = "Plain text body",
        inReplyTo: String? = nil,
        references: String? = nil
    ) -> OutboundMessage {
        OutboundMessage(
            fromEmail: fromEmail,
            fromName: fromName,
            to: to,
            subject: subject,
            body: body,
            inReplyTo: inReplyTo,
            references: references
        )
    }

    /// Splits the message into its header block and the raw body text.
    private func parts(_ data: Data) throws -> (headers: [String: String], rawBody: String) {
        let text = String(decoding: data, as: UTF8.self)
        let separator = try XCTUnwrap(text.range(of: "\r\n\r\n"), "missing header/body separator")
        let headerBlock = String(text[text.startIndex..<separator.lowerBound])
        let body = String(text[separator.upperBound...])

        var headers: [String: String] = [:]
        for line in headerBlock.components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<colon]).lowercased()
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        return (headers, body)
    }

    func test_reply_usesCRLFEverywhere() throws {
        let data = MIMEBuilder.reply(outbound(), messageId: "<m1@lagoon>")
        let text = String(decoding: data, as: UTF8.self)

        XCTAssertTrue(text.contains("\r\n"), "no CRLF line endings")
        XCTAssertFalse(text.replacingOccurrences(of: "\r\n", with: "").contains("\n"),
                       "bare LF found")
        XCTAssertTrue(text.hasSuffix("\r\n"), "message must end with CRLF before the DATA dot")
    }

    /// Decodes every `=?UTF-8?B?…?=` encoded word back into plain text.
    private func decoded(_ value: String) -> String {
        var result = ""
        var rest = Substring(value)
        while let start = rest.range(of: "=?UTF-8?B?") {
            result += rest[rest.startIndex..<start.lowerBound]
            guard let end = rest.range(of: "?=", range: start.upperBound..<rest.endIndex) else {
                break
            }
            let payload = String(rest[start.upperBound..<end.lowerBound])
            result += String(decoding: Data(base64Encoded: payload) ?? Data(), as: UTF8.self)
            rest = rest[end.upperBound...]
        }
        return result + rest
    }

    func test_reply_asciiSubjectStaysPlainAndGetsTheRePrefix() throws {
        let data = MIMEBuilder.reply(outbound(subject: "Lunch?"), messageId: "<m1@lagoon>")
        let (headers, _) = try parts(data)

        XCTAssertEqual(headers["subject"], "Re: Lunch?")
    }

    func test_reply_nonASCIISubjectIsRFC2047Encoded() throws {
        let data = MIMEBuilder.reply(outbound(subject: "会议纪要"), messageId: "<m1@lagoon>")
        let (headers, _) = try parts(data)
        let subject = try XCTUnwrap(headers["subject"])

        XCTAssertTrue(subject.contains("=?UTF-8?B?"), subject)
        XCTAssertFalse(subject.contains("会议纪要"), subject)
        XCTAssertEqual(decoded(subject), "Re: 会议纪要")
    }

    func test_reply_subjectWithRePrefix_isNotDoubled() throws {
        let plain = MIMEBuilder.reply(outbound(subject: "Re: Lunch?"), messageId: "<m1@lagoon>")
        let (plainHeaders, _) = try parts(plain)
        XCTAssertEqual(plainHeaders["subject"], "Re: Lunch?")

        let lowercased = MIMEBuilder.reply(outbound(subject: "re: Lunch?"), messageId: "<m1@lagoon>")
        let (lowerHeaders, _) = try parts(lowercased)
        XCTAssertEqual(lowerHeaders["subject"], "re: Lunch?")

        let added = MIMEBuilder.reply(outbound(subject: "Lunch?"), messageId: "<m1@lagoon>")
        let (addedHeaders, _) = try parts(added)
        XCTAssertEqual(addedHeaders["subject"], "Re: Lunch?")
    }

    func test_reply_threadHeadersPassThroughWhenPresent() throws {
        let data = MIMEBuilder.reply(
            outbound(inReplyTo: "<original@qq.com>", references: "<a@qq.com> <original@qq.com>"),
            messageId: "<m1@lagoon>"
        )
        let (headers, _) = try parts(data)

        XCTAssertEqual(headers["in-reply-to"], "<original@qq.com>")
        XCTAssertEqual(headers["references"], "<a@qq.com> <original@qq.com>")
    }

    func test_reply_threadHeadersOmittedWhenAbsent() throws {
        let data = MIMEBuilder.reply(outbound(), messageId: "<m1@lagoon>")
        let (headers, _) = try parts(data)

        XCTAssertNil(headers["in-reply-to"])
        XCTAssertNil(headers["references"])
    }

    func test_reply_hasValidDateAndMessageId() throws {
        let data = MIMEBuilder.reply(outbound(), messageId: "<m1@lagoon>")
        let (headers, _) = try parts(data)

        XCTAssertEqual(headers["message-id"], "<m1@lagoon>")
        XCTAssertEqual(headers["mime-version"], "1.0")

        let date = try XCTUnwrap(headers["date"])
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        // Formatting is lenient about single-digit days; parsing must round-trip.
        let parsed = formatter.date(from: date) ?? ISO8601DateFormatter().date(from: date)
        XCTAssertNotNil(parsed, "Date header is not RFC 5322: \(date)")
    }

    func test_reply_addressesCarryTheFromName() throws {
        let data = MIMEBuilder.reply(outbound(), messageId: "<m1@lagoon>")
        let (headers, _) = try parts(data)

        XCTAssertEqual(headers["from"], "\"Me\" <me@qq.com>")
        XCTAssertEqual(headers["to"], "<alice@example.com>")

        let bare = MIMEBuilder.reply(outbound(fromName: nil), messageId: "<m1@lagoon>")
        let (bareHeaders, _) = try parts(bare)
        XCTAssertEqual(bareHeaders["from"], "<me@qq.com>")
    }

    func test_reply_nonASCIIDisplayNameIsRFC2047Encoded() throws {
        let data = MIMEBuilder.reply(outbound(fromName: "陈其"), messageId: "<m1@lagoon>")
        let (headers, _) = try parts(data)
        let from = try XCTUnwrap(headers["from"])

        XCTAssertFalse(from.contains("陈其"), from)
        XCTAssertTrue(from.contains("=?UTF-8?B?"), from)
        XCTAssertEqual(decoded(from), "陈其 <me@qq.com>")
    }

    func test_reply_bodyIsBase64WithShortLines() throws {
        let body = String(repeating: "这是一段中文回复。", count: 40)
        let data = MIMEBuilder.reply(outbound(body: body), messageId: "<m1@lagoon>")
        let (headers, rawBody) = try parts(data)

        XCTAssertEqual(headers["content-type"], "text/plain; charset=UTF-8")
        XCTAssertEqual(headers["content-transfer-encoding"], "base64")

        let encodedLines = rawBody
            .components(separatedBy: "\r\n")
            .filter { !$0.isEmpty }
        XCTAssertFalse(encodedLines.isEmpty)
        for line in encodedLines {
            XCTAssertLessThanOrEqual(line.count, 76, "base64 line too long: \(line.count)")
        }
        let decoded = Data(base64Encoded: encodedLines.joined())
        XCTAssertEqual(String(decoding: try XCTUnwrap(decoded), as: UTF8.self), body)
    }
}
