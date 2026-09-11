import XCTest
import Foundation
import Logging
@testable import LagoonServer

/// Drives `SMTPClient` over the scripted transport: the whole 220/235/354/221
/// conversation is queued up front, so the tests assert the exact command
/// sequence that leaves the machine and the typed errors that come back.
final class SMTPClientTests: XCTestCase {
    private let outbound = OutboundMessage(
        fromEmail: "me@qq.com",
        fromName: "Me",
        to: "alice@example.com",
        subject: "Re: Lunch?",
        body: "Sounds good.",
        inReplyTo: "<original@qq.com>",
        references: "<original@qq.com>"
    )

    private func makeClient(_ transport: ScriptedTransport) -> SMTPClient {
        SMTPClient(transport: transport, logger: Logger(label: "smtp-client-tests"))
    }

    /// Everything the client has put on the wire, as one CRLF string.
    private func wire(_ transport: ScriptedTransport) async -> String {
        await transport.writes
            .map { String(decoding: $0, as: UTF8.self) }
            .joined()
    }

    /// A complete accepted delivery: greeting, EHLO, auth, envelope, DATA, QUIT.
    private func scriptAcceptedConversation(_ transport: ScriptedTransport) async {
        await transport.enqueue("220 smtp.qq.com ESMTP ready")
        await transport.enqueue("250-smtp.qq.com")
        await transport.enqueue("250-SIZE 33554432")
        await transport.enqueue("250 AUTH PLAIN LOGIN")
        await transport.enqueue("235 Authentication successful")
        await transport.enqueue("250 OK")
        await transport.enqueue("250 OK")
        await transport.enqueue("354 End data with <CR><LF>.<CR><LF>")
        await transport.enqueue("250 OK: queued")
        await transport.enqueue("221 Bye")
    }

    func test_send_happyPath_sendsExpectedCommandSequence() async throws {
        let transport = ScriptedTransport()
        await scriptAcceptedConversation(transport)

        let messageId = try await makeClient(transport).send(
            outbound, host: "smtp.qq.com", port: 465,
            username: "me@qq.com", authCode: "abcd1234abcd1234"
        )

        let messageIdValue = try XCTUnwrap(messageId)
        XCTAssertTrue(messageIdValue.hasPrefix("<"), messageIdValue)
        XCTAssertTrue(messageIdValue.hasSuffix("@lagoon>"), messageIdValue)

        let (host, port) = await (transport.connectedHost, transport.connectedPort)
        XCTAssertEqual(host, "smtp.qq.com")
        XCTAssertEqual(port, 465)

        let transcript = await wire(transport)
        let expectedAuth = Data("\0me@qq.com\0abcd1234abcd1234".utf8).base64EncodedString()
        let markers = [
            "EHLO ",
            "AUTH PLAIN \(expectedAuth)\r\n",
            "MAIL FROM:<me@qq.com>\r\n",
            "RCPT TO:<alice@example.com>\r\n",
            "DATA\r\n",
            "Message-ID: \(messageIdValue)\r\n",
            "\r\n.\r\n",
            "QUIT\r\n",
        ]
        var cursor = transcript.startIndex
        for marker in markers {
            guard let range = transcript.range(of: marker, range: cursor..<transcript.endIndex) else {
                return XCTFail("missing or out of order: \(marker)\n---\n\(transcript)")
            }
            cursor = range.upperBound
        }
        XCTAssertTrue(transcript.hasPrefix("EHLO "), transcript)
    }

    func test_send_authRejected535_throwsAuthFailedAndDoesNotRetry() async throws {
        let transport = ScriptedTransport()
        await transport.enqueue("220 smtp.qq.com ESMTP ready")
        await transport.enqueue("250 smtp.qq.com")
        await transport.enqueue("535 Error: authentication failed")

        do {
            _ = try await makeClient(transport).send(
                outbound, host: "smtp.qq.com", port: 465,
                username: "me@qq.com", authCode: "wrong"
            )
            XCTFail("expected MailError.authFailed")
        } catch MailError.authFailed {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let transcript = await wire(transport)
        XCTAssertEqual(transcript.components(separatedBy: "AUTH PLAIN").count - 1, 1, transcript)
    }

    func test_send_rejectedAfterPayload_throwsProtocolErrorAndDoesNotRetry() async throws {
        let transport = ScriptedTransport()
        await transport.enqueue("220 smtp.qq.com ESMTP ready")
        await transport.enqueue("250 smtp.qq.com")
        await transport.enqueue("235 Authentication successful")
        await transport.enqueue("250 OK")
        await transport.enqueue("250 OK")
        await transport.enqueue("354 End data with <CR><LF>.<CR><LF>")
        // Rejection arrives only once the payload is already on the wire.
        await transport.enqueue("554 Message rejected: content")
        // The retry would need a second 220; its absence also proves no retry.

        do {
            _ = try await makeClient(transport).send(
                outbound, host: "smtp.qq.com", port: 465,
                username: "me@qq.com", authCode: "abcd1234abcd1234"
            )
            XCTFail("expected MailError.protocolError")
        } catch MailError.protocolError(let label) {
            XCTAssertTrue(label.contains("554"), label)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let transcript = await wire(transport)
        XCTAssertTrue(transcript.contains("\r\n.\r\n"), "payload was never terminated")
        XCTAssertEqual(transcript.components(separatedBy: "DATA").count - 1, 1, transcript)
        XCTAssertEqual(transcript.components(separatedBy: "EHLO").count - 1, 1, transcript)
    }

    func test_send_dataCommandRejected_doesNotSendPayload() async throws {
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
            XCTFail("expected a failure")
        } catch {
            // The typed error is asserted by the two tests above; here the
            // point is that nothing was written after DATA.
        }

        let transcript = await wire(transport)
        XCTAssertFalse(transcript.contains("\r\n.\r\n"), transcript)
    }

    func test_send_transient421BeforeData_retriesOnceThenUnreachable() async throws {
        let transport = ScriptedTransport()
        // First attempt: the server refuses right after the greeting.
        await transport.enqueue("220 smtp.qq.com ESMTP ready")
        await transport.enqueue("421 Service not available, closing channel")
        // Second attempt: same verdict.
        await transport.enqueue("220 smtp.qq.com ESMTP ready")
        await transport.enqueue("421 Service not available, closing channel")

        do {
            _ = try await makeClient(transport).send(
                outbound, host: "smtp.qq.com", port: 465,
                username: "me@qq.com", authCode: "abcd1234abcd1234"
            )
            XCTFail("expected MailError.unreachable")
        } catch MailError.unreachable(let label) {
            XCTAssertTrue(label.contains("421"), label)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let transcript = await wire(transport)
        XCTAssertEqual(transcript.components(separatedBy: "EHLO").count - 1, 2, transcript)
    }

    func test_send_secondSendOnSameClientOpensAFreshSession() async throws {
        let transport = ScriptedTransport()
        await scriptAcceptedConversation(transport)
        await scriptAcceptedConversation(transport)

        let client = makeClient(transport)
        let first = try await client.send(
            outbound, host: "smtp.qq.com", port: 465,
            username: "me@qq.com", authCode: "abcd1234abcd1234"
        )
        let second = try await client.send(
            outbound, host: "smtp.qq.com", port: 465,
            username: "me@qq.com", authCode: "abcd1234abcd1234"
        )

        XCTAssertNotEqual(first, second, "Message-ID must be unique per send")
        let transcript = await wire(transport)
        XCTAssertEqual(transcript.components(separatedBy: "EHLO").count - 1, 2, transcript)
        XCTAssertEqual(transcript.components(separatedBy: "QUIT").count - 1, 2, transcript)
    }

    func test_dotStuffed_escapesLeadingDotsAndTerminatesPayload() throws {
        let payload = Data("Subject: x\r\n\r\nline1\r\n.\r\n..already\r\n".utf8)
        let stuffed = SMTPClient.dotStuffedForData(payload)
        XCTAssertEqual(
            String(decoding: stuffed, as: UTF8.self),
            "Subject: x\r\n\r\nline1\r\n..\r\n...already\r\n.\r\n"
        )

        // A payload without a trailing CRLF still gets the dot on its own line.
        let unterminated = SMTPClient.dotStuffedForData(Data("last line".utf8))
        XCTAssertEqual(String(decoding: unterminated, as: UTF8.self), "last line\r\n.\r\n")
    }
}
