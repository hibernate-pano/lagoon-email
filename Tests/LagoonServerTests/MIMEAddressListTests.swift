import XCTest
import Foundation
@testable import LagoonServer

/// The `To:` / `Cc:` header of an outgoing message.
///
/// RFC 5322 address lists are comma-separated, but a comma can legally appear
/// inside a quoted display name. Splitting on every comma turned one
/// recipient into two — the second half a bare address that could bounce, and
/// that a forward-path builder would read as somebody else entirely.
final class MIMEAddressListTests: XCTestCase {
    private func outbound(
        to: String,
        cc: [String] = []
    ) -> OutboundMessage {
        OutboundMessage(
            fromEmail: "me@example.com",
            fromName: "Me",
            to: to,
            cc: cc,
            subject: "Hello",
            body: "Body",
            inReplyTo: nil,
            references: nil,
            isReply: true
        )
    }

    private func header(_ data: Data, _ name: String) throws -> String? {
        let text = String(decoding: data, as: UTF8.self)
        for line in text.components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            if line[..<colon].lowercased() == name.lowercased() {
                return String(line[line.index(after: colon)...])
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// The regression: a display name with a comma in it is one recipient.
    ///
    /// Before the fix the header read `<"Zhang>, Wei" <wei@example.com>` — a
    /// nonsense address, plus a second recipient nobody asked for.
    func test_quotedDisplayNameWithAComma_staysOneRecipient() throws {
        let data = MIMEBuilder.reply(
            outbound(to: "\"Zhang, Wei\" <wei@example.com>"),
            messageId: "<m1@lagoon>"
        )
        XCTAssertEqual(
            try header(data, "to"), "\"Zhang, Wei\" <wei@example.com>",
            "a comma inside a quoted display name is not a separator"
        )
    }

    /// The same, in a list: the quoted name survives and the other
    /// recipients are still separated.
    func test_quotedDisplayNameInAList_keepsItsNeighbours() throws {
        let data = MIMEBuilder.reply(
            outbound(to: "\"Zhang, Wei\" <wei@example.com>, bob@example.com"),
            messageId: "<m1@lagoon>"
        )
        XCTAssertEqual(
            try header(data, "to"),
            "\"Zhang, Wei\" <wei@example.com>, <bob@example.com>"
        )
    }

    /// `Cc:` goes through the same helper, so it gets the same treatment.
    func test_ccList_splitsOnTopLevelCommasOnly() throws {
        let data = MIMEBuilder.reply(
            outbound(to: "alice@example.com", cc: ["\"Li, Ming\" <li@example.com>", "carol@example.com"]),
            messageId: "<m1@lagoon>"
        )
        XCTAssertEqual(
            try header(data, "cc"),
            "\"Li, Ming\" <li@example.com>, <carol@example.com>"
        )
    }

    /// An ordinary list is untouched — the fix must not change the common
    /// case.
    func test_ordinaryList_isUnchanged() throws {
        let data = MIMEBuilder.reply(
            outbound(to: "alice@example.com, Bob <bob@example.com>"),
            messageId: "<m1@lagoon>"
        )
        XCTAssertEqual(try header(data, "to"), "<alice@example.com>, Bob <bob@example.com>")
    }

    /// The splitter itself, so the rule is pinned where it lives.
    func test_splitAddressList_keepsQuotedAndBracketedPiecesIntact() {
        let pieces = MIMEParser.splitAddressList(
            "\"Zhang, Wei\" <wei@example.com>, bob@example.com, \"Doe, Jane\" <jane@example.com>"
        )
        XCTAssertEqual(
            pieces,
            [
                "\"Zhang, Wei\" <wei@example.com>",
                "bob@example.com",
                "\"Doe, Jane\" <jane@example.com>",
            ]
        )
    }

    /// The address parser still returns routable addresses — the display name
    /// is dropped there, because a forward-path may not carry one.
    func test_parseAddressList_stillReturnsBareAddresses() {
        XCTAssertEqual(
            MIMEParser.parseAddressList(
                "\"Zhang, Wei\" <wei@example.com>, bob@example.com"
            ),
            ["wei@example.com", "bob@example.com"]
        )
    }
}
