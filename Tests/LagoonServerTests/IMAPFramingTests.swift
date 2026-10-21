import Foundation
import XCTest
import Logging
@testable import LagoonServer

/// The framing ceiling has to fit what the product promised to accept.
///
/// The bug: the ceiling was 32 MB, but a body part travels base64 encoded —
/// 4 bytes of wire for every 3 bytes of attachment — so the 25 MB the
/// attachment cap allows arrives as ~33.3 MB of literal. The ceiling was
/// below that, the overflow was raised as a protocol error, and the route
/// answered 502 "server error" for a mail that was merely too big.
final class IMAPFramingTests: XCTestCase {
    private let logger = Logger(label: "imap-framing-tests")

    /// The ceiling must be above the inflated size of a legal attachment.
    ///
    /// 25 MB of attachment is 25 × 4/3 ≈ 33.3 MB on the wire, plus the
    /// headers and the text around it. A 32 MB ceiling refused exactly that,
    /// which is a size the product had already promised to accept.
    func test_theCeilingFitsTheLargestLegalAttachment() {
        let inflated = AttachmentLimit.maxBytes * 4 / 3
        XCTAssertGreaterThanOrEqual(
            IMAPConnection.maxLiteralBytes,
            inflated,
            "the framing ceiling must fit a 25 MB attachment once base64 has inflated it"
        )
        XCTAssertGreaterThan(
            IMAPConnection.maxLiteralBytes,
            32 * 1024 * 1024,
            "the old 32 MB ceiling rejected legitimate mail"
        )
    }

    /// A response that declares more than the ceiling is refused *before* a
    /// single byte of it is read, and it is refused as a size verdict, not as
    /// a broken server.
    func test_anOversizeLiteralIsRefusedBeforeAnyByteIsRead() async throws {
        let transport = ScriptedTransport()
        await transport.enqueue("* OK IMAP4rev1 ready")
        // A body part of 40 MB + 1: one byte over the ceiling.
        await transport.enqueue("* 1 FETCH (BODY[TEXT] {41943041}")

        let connection = IMAPConnection(transport: transport, logger: self.logger)
        try await connection.connect(host: "imap.qq.com", port: 993)

        do {
            _ = try await connection.execute("FETCH 1 BODY.PEEK[]")
            XCTFail("expected the oversize literal to be refused")
        } catch let error as MailError {
            XCTAssertEqual(error, .protocolError(IMAPConnection.oversizeLiteralLabel))
        }
    }

    /// The framing itself is untouched: an ordinary literal still comes
    /// through whole.
    func test_anOrdinaryLiteralStillFrames() async throws {
        let transport = ScriptedTransport()
        await transport.enqueue("* OK IMAP4rev1 ready")
        await transport.enqueue("* 1 FETCH (BODY[TEXT] {5}")
        await transport.enqueueLiteral(Data("hello".utf8))
        await transport.enqueue(")")
        await transport.enqueue("A0001 OK FETCH completed")

        let connection = IMAPConnection(transport: transport, logger: self.logger)
        try await connection.connect(host: "imap.qq.com", port: 993)
        let responses = try await connection.execute("FETCH 1 BODY.PEEK[]")

        XCTAssertEqual(responses.count, 2, "the untagged response and the tagged completion")
        XCTAssertEqual(responses.first?.literal, Data("hello".utf8))
    }
}
