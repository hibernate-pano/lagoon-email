import XCTest
import Foundation
import Logging
@testable import LagoonServer

/// The delivery verdict, not the goodbye.
///
/// The bug these tests pin: the SMTP session used to treat a failed `QUIT`
/// as a failed send. But the server's 250 to the DATA terminator is the
/// point of no return (RFC 5321 §4.1.1.3) — the message is queued and
/// the client owes the server nothing but a goodbye. Reporting the goodbye
/// as a failure told the user "not sent" for a mail that was already on its
/// way, and the user's second tap delivered it twice.
final class SMTPDeliveryTests: XCTestCase {
    private let outbound = OutboundMessage(
        fromEmail: "me@qq.com",
        fromName: "Me",
        to: "alice@example.com",
        subject: "Lunch?",
        body: "See you at noon.",
        inReplyTo: nil,
        references: nil
    )

    private func makeClient(
        _ transport: any StreamTransport,
        readTimeout: Duration = .seconds(5)
    ) -> SMTPClient {
        SMTPClient(
            transport: transport,
            logger: Logger(label: "smtp-delivery-tests"),
            readTimeout: readTimeout
        )
    }

    /// Everything the client has put on the wire, as one CRLF string.
    private func wire(_ transport: ScriptedTransport) async -> String {
        await transport.writes
            .map { String(decoding: $0, as: UTF8.self) }
            .joined()
    }

    /// The conversation up to and including the 250 that accepts the
    /// payload. What happens *after* it is the part under test.
    private func scriptUpToDelivery(_ transport: ScriptedTransport) async {
        await transport.enqueue("220 smtp.qq.com ESMTP ready")
        await transport.enqueue("250 smtp.qq.com")
        await transport.enqueue("235 Authentication successful")
        await transport.enqueue("250 OK")            // MAIL FROM
        await transport.enqueue("250 OK")            // RCPT TO
        await transport.enqueue("354 End data with <CR><LF>.<CR><LF>")
        await transport.enqueue("250 OK: queued")    // the delivery verdict
    }

    /// The server hangs up instead of answering 221.
    ///
    /// The scripted transport closes once its script runs out, which is
    /// exactly what a server that drops the connection after accepting the
    /// message looks like. The mail is queued; the conversation ended
    /// abruptly. That is not a delivery failure.
    func test_send_serverHangsUpAfterDelivery_stillReportsSuccess() async throws {
        let transport = ScriptedTransport()
        await scriptUpToDelivery(transport)
        // No "221 Bye": the server is gone.

        let messageId = try await makeClient(transport).send(
            outbound, host: "smtp.qq.com", port: 465,
            username: "me@qq.com", authCode: "abcd1234abcd1234"
        )

        XCTAssertNotNil(messageId, "the mail was queued; the send must not be reported as failed")

        let transcript = await wire(transport)
        XCTAssertTrue(transcript.contains("\r\n.\r\n"), "the payload was terminated")
        XCTAssertTrue(transcript.contains("QUIT\r\n"), "the client still says goodbye")
        // A retry would need a second 220; its absence proves no retry.
        XCTAssertEqual(transcript.components(separatedBy: "EHLO").count - 1, 1, transcript)
    }

    /// The server answers QUIT with something that is not 221.
    ///
    /// Same verdict as above: the message is already queued. A 5xx here is
    /// the server closing the conversation, not a verdict on the mail.
    func test_send_quitRefusedAfterDelivery_stillReportsSuccess() async throws {
        let transport = ScriptedTransport()
        await scriptUpToDelivery(transport)
        await transport.enqueue("500 Service shutting down")

        let messageId = try await makeClient(transport).send(
            outbound, host: "smtp.qq.com", port: 465,
            username: "me@qq.com", authCode: "abcd1234abcd1234"
        )

        XCTAssertNotNil(messageId, "the mail was queued; the send must not be reported as failed")
        let transcript = await wire(transport)
        XCTAssertTrue(transcript.contains("QUIT\r\n"), transcript)
        XCTAssertEqual(transcript.components(separatedBy: "EHLO").count - 1, 1, transcript)
    }

    /// A QUIT that never gets an answer must not hang the send either.
    ///
    /// The read timeout bounds the goodbye, not the delivery: the mail is
    /// already queued, so the client gives up on the 221 and reports
    /// success.
    func test_send_quitTimesOutAfterDelivery_stillReportsSuccess() async throws {
        let transport = ScriptedTransport(closeAfterScript: false)
        await scriptUpToDelivery(transport)
        // No answer to QUIT, ever.

        let messageId = try await makeClient(transport, readTimeout: .milliseconds(200)).send(
            outbound, host: "smtp.qq.com", port: 465,
            username: "me@qq.com", authCode: "abcd1234abcd1234"
        )

        XCTAssertNotNil(messageId, "the mail was queued; the send must not be reported as failed")
        let transcript = await wire(transport)
        XCTAssertTrue(transcript.contains("QUIT\r\n"), transcript)
    }

    /// A failure *before* the payload still fails the send.
    ///
    /// The delivery verdict is what makes the QUIT irrelevant — not a
    /// general "ignore SMTP errors" rule. A refused DATA command means the
    /// mail never left, and the user must be told so.
    func test_send_dataRejectedBeforeDelivery_stillFails() async throws {
        let transport = ScriptedTransport()
        await transport.enqueue("220 smtp.qq.com ESMTP ready")
        await transport.enqueue("250 smtp.qq.com")
        await transport.enqueue("235 Authentication successful")
        await transport.enqueue("250 OK")
        await transport.enqueue("250 OK")
        await transport.enqueue("554 cannot accept data")

        do {
            _ = try await makeClient(transport).send(
                outbound, host: "smtp.qq.com", port: 465,
                username: "me@qq.com", authCode: "abcd1234abcd1234"
            )
            XCTFail("expected the send to fail")
        } catch {
            // The typed error is asserted elsewhere; the point here is that
            // the failure still propagates.
        }

        let transcript = await wire(transport)
        XCTAssertFalse(transcript.contains("\r\n.\r\n"), transcript)
    }

    // MARK: - The read timeout leaves nothing running

    /// When the client gives up on a read, the read must be over.
    ///
    /// The timeout is raced against the transport read in a task group. The
    /// loser is the transport read, and it is the loser that holds the
    /// socket: if it were still running when the client tore the transport
    /// down, the two would touch the same connection at once — the crash and
    /// the leaked connection the audit describes.
    ///
    /// The invariant is what the test pins: by the time the client reports
    /// the timeout, no read is still in flight and the read has seen the
    /// cancellation.
    func test_readTimeout_leavesNoReadRunningWhenTheClientGivesUp() async throws {
        let transport = BlockingReadTransport()
        let client = makeClient(transport, readTimeout: .milliseconds(100))

        do {
            _ = try await client.send(
                outbound, host: "smtp.qq.com", port: 465,
                username: "me@qq.com", authCode: "abcd1234abcd1234"
            )
            XCTFail("expected the read to time out")
        } catch {
            // The timeout is the point; the typed error is covered elsewhere.
        }

        let readsInFlight = await transport.readsInFlight
        XCTAssertEqual(
            readsInFlight, 0,
            "the timed-out read must not still be running when the client gives up"
        )
        let sawCancellation = await transport.readSawCancellation
        XCTAssertTrue(
            sawCancellation,
            "the timed-out read must be cancelled, not abandoned"
        )
    }
}

/// A transport whose reads never answer.
///
/// The only way to reach the read-timeout path deterministically: the
/// server accepts the connection and then says nothing. The transport
/// records whether a read was still running when the client gave up, which
/// is the thing the timeout must guarantee.
actor BlockingReadTransport: StreamTransport {
    private(set) var readsInFlight = 0
    private(set) var readSawCancellation = false
    private(set) var isClosed = false

    func connect(host: String, port: Int) async throws {
        isClosed = false
    }

    func write(_ bytes: Data) async throws {
        guard !isClosed else { throw StreamTransportError.closed }
    }

    func readLine() async throws -> String {
        readsInFlight += 1
        defer { readsInFlight -= 1 }
        do {
            // The server never answers. Only cancellation ends this.
            try await Task.sleep(for: .seconds(30))
            return "220 never"
        } catch {
            readSawCancellation = true
            throw StreamTransportError.closed
        }
    }

    func readExactly(_ count: Int) async throws -> Data {
        Data(try await readLine().utf8)
    }

    func close() async {
        isClosed = true
    }
}
