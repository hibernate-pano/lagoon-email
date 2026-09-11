import XCTest
import Foundation
import Logging
@testable import LagoonServer

/// Drives `IMAPConnection` over a scripted transport: exact command bytes,
/// literal framing, tagged error mapping and read timeouts — all offline.
final class IMAPConnectionTests: XCTestCase {
    private func makeConnection(
        transport: ScriptedTransport,
        readTimeout: Duration = .seconds(5)
    ) async throws -> IMAPConnection {
        let connection = IMAPConnection(
            transport: transport,
            logger: Logger(label: "imap-connection-tests"),
            readTimeout: readTimeout
        )
        await transport.enqueue("* OK [CAPABILITY IMAP4rev1] Lagoon ready")
        try await connection.connect(host: "imap.qq.com", port: 993)
        return connection
    }

    /// (a) the tag is generated locally and the command goes out verbatim.
    func test_execute_writesTaggedCommand_andParsesTaggedOK() async throws {
        let transport = ScriptedTransport()
        let connection = try await makeConnection(transport: transport)

        await transport.enqueue("A0001 OK CAPABILITY completed")
        let responses = try await connection.execute("CAPABILITY")

        XCTAssertEqual(responses.count, 1)
        XCTAssertEqual(responses.first?.kind, .tagged("A0001", .ok))
        let writes = await transport.writes
        XCTAssertEqual(writes, [Data("A0001 CAPABILITY\r\n".utf8)])
    }

    /// Untagged lines before the tagged one are collected, not dropped.
    func test_execute_collectsUntaggedLinesBeforeTagged() async throws {
        let transport = ScriptedTransport()
        let connection = try await makeConnection(transport: transport)

        await transport.enqueue("* 12 EXISTS")
        await transport.enqueue("* OK still here")
        await transport.enqueue("A0001 OK NOOP completed")
        let responses = try await connection.execute("NOOP")

        XCTAssertEqual(responses.count, 3)
        XCTAssertEqual(responses.map(\.kind), [.untagged, .untagged, .tagged("A0001", .ok)])
    }

    /// (b) `{N}` framing: the declared bytes are read exactly and attached.
    func test_execute_readsLiteralVerbatim() async throws {
        let transport = ScriptedTransport()
        let connection = try await makeConnection(transport: transport)

        await transport.enqueue("* 1 FETCH (BODY[TEXT] {5}")
        await transport.enqueueLiteral(Data("hello".utf8))
        await transport.enqueue(")")
        await transport.enqueue("A0001 OK FETCH completed")
        let responses = try await connection.execute("UID FETCH 1 (BODY.PEEK[TEXT])")

        XCTAssertEqual(responses.count, 2, "literal tail must merge into its own line")
        XCTAssertEqual(responses.first?.kind, .untagged)
        XCTAssertEqual(responses.first?.literal, Data("hello".utf8))
        XCTAssertEqual(
            responses.first?.raw,
            "* 1 FETCH (BODY[TEXT] {5})",
            "the tail after the literal belongs to the same logical line"
        )
    }

    /// (c) a rejected login must be typed so `SyncEngine` can stop retrying.
    func test_taggedNo_authenticationFailed_mapsToAuthFailed() async throws {
        let transport = ScriptedTransport()
        let connection = try await makeConnection(transport: transport)

        await transport.enqueue("A0001 NO [AUTHENTICATIONFAILED] Authentication failed")
        let thrown = await XCTAssertThrowsErrorAsync {
            try await connection.execute("LOGIN test-user test-auth-code")
        }
        XCTAssertEqual(thrown as? MailError, .authFailed)
    }

    func test_taggedNo_otherReason_mapsToProtocolError() async throws {
        let transport = ScriptedTransport()
        let connection = try await makeConnection(transport: transport)

        await transport.enqueue("A0001 NO [TRYCREATE] mailbox does not exist")
        let thrown = await XCTAssertThrowsErrorAsync {
            try await connection.execute(#"SELECT "Nope""#)
        }
        XCTAssertEqual(thrown as? MailError, .protocolError("tagged NO"))
    }

    /// (d) BAD is structural, never credential-related.
    func test_taggedBad_mapsToProtocolError() async throws {
        let transport = ScriptedTransport()
        let connection = try await makeConnection(transport: transport)

        await transport.enqueue("A0001 BAD Command syntax error")
        let thrown = await XCTAssertThrowsErrorAsync {
            try await connection.execute("BOGUS")
        }
        XCTAssertEqual(thrown as? MailError, .protocolError("tagged BAD"))
    }

    /// (e) a literal the server never delivers must not hang the sync loop.
    func test_literalReadTimeout_throwsTimedOut() async throws {
        let transport = ScriptedTransport(closeAfterScript: false)
        let connection = try await makeConnection(transport: transport, readTimeout: .milliseconds(100))

        await transport.enqueue("* 1 FETCH (BODY[TEXT] {5}")
        let thrown = await XCTAssertThrowsErrorAsync {
            try await connection.execute("UID FETCH 1 (BODY.PEEK[TEXT])")
        }
        XCTAssertEqual(thrown as? StreamTransportError, .timedOut)
    }

    /// A hung line read is also bounded by the timeout.
    func test_lineReadTimeout_throwsTimedOut() async throws {
        let transport = ScriptedTransport(closeAfterScript: false)
        let connection = try await makeConnection(transport: transport, readTimeout: .milliseconds(100))

        let thrown = await XCTAssertThrowsErrorAsync {
            try await connection.execute("NOOP")
        }
        XCTAssertEqual(thrown as? StreamTransportError, .timedOut)
    }

    func test_connect_sendsNothing_andRecordsHostAndPort() async throws {
        let transport = ScriptedTransport()
        let connection = IMAPConnection(
            transport: transport,
            logger: Logger(label: "imap-connection-tests")
        )
        await transport.enqueue("* OK Lagoon ready")
        try await connection.connect(host: "imap.qq.com", port: 993)

        let writes = await transport.writes
        XCTAssertEqual(writes, [], "the greeting is read-only")
        let host = await transport.connectedHost
        let port = await transport.connectedPort
        XCTAssertEqual(host, "imap.qq.com")
        XCTAssertEqual(port, 993)
    }

    func test_connect_rejectsNonGreeting() async throws {
        let transport = ScriptedTransport()
        let connection = IMAPConnection(
            transport: transport,
            logger: Logger(label: "imap-connection-tests")
        )
        await transport.enqueue("A1 NO go away")

        let thrown = await XCTAssertThrowsErrorAsync {
            try await connection.connect(host: "imap.qq.com", port: 993)
        }
        XCTAssertEqual(thrown as? MailError, .protocolError("unexpected greeting"))
    }

    /// IDLE: one sync event is enough to trigger a pull, then DONE re-enters.
    func test_idle_returnsFirstEvent_andSendsDone() async throws {
        let transport = ScriptedTransport()
        let connection = try await makeConnection(transport: transport)

        await transport.enqueue("+ idling")
        await transport.enqueue("* 3 EXISTS")
        await transport.enqueue("A0001 OK IDLE terminated")

        let events = try await connection.idle(waitUpTo: .seconds(5))

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.atoms, ["*", "3", "EXISTS"])
        let writes = await transport.writes
        XCTAssertEqual(
            writes,
            [Data("A0001 IDLE\r\n".utf8), Data("DONE\r\n".utf8)]
        )
    }

    /// Non-sync untagged noise (greeting-style `* OK`) must not end the wait.
    func test_idle_ignoresNonEventLines_untilTimeout() async throws {
        let transport = ScriptedTransport(closeAfterScript: false)
        let connection = try await makeConnection(transport: transport)

        await transport.enqueue("+ idling")
        await transport.enqueue("* OK still here")
        // The completion only arrives once DONE is on the wire, so the wait
        // itself must end on the deadline, not on a server reply.
        await transport.enqueue("A0001 OK IDLE terminated", onlyAfterWrites: 2)

        let events = try await connection.idle(waitUpTo: .milliseconds(150))

        XCTAssertEqual(events, [], "a keep-alive note is not a change")
        let writes = await transport.writes
        XCTAssertEqual(
            writes,
            [Data("A0001 IDLE\r\n".utf8), Data("DONE\r\n".utf8)],
            "the timeout path still terminates IDLE cleanly"
        )
    }

    func test_idle_canBeEnteredTwice_afterDone() async throws {
        let transport = ScriptedTransport()
        let connection = try await makeConnection(transport: transport)

        await transport.enqueue("+ idling")
        await transport.enqueue("* 1 EXISTS")
        await transport.enqueue("A0001 OK IDLE terminated")
        _ = try await connection.idle(waitUpTo: .seconds(1))

        await transport.enqueue("+ idling")
        await transport.enqueue("* 2 EXISTS")
        await transport.enqueue("A0002 OK IDLE terminated")
        let second = try await connection.idle(waitUpTo: .seconds(1))

        XCTAssertEqual(second.first?.atoms, ["*", "2", "EXISTS"])
        let writes = await transport.writes
        XCTAssertEqual(writes.count, 4)
        XCTAssertEqual(writes[2], Data("A0002 IDLE\r\n".utf8))
    }

    func test_execute_withoutConnect_throwsNotConnected() async throws {
        let transport = ScriptedTransport()
        let connection = IMAPConnection(
            transport: transport,
            logger: Logger(label: "imap-connection-tests")
        )
        let thrown = await XCTAssertThrowsErrorAsync {
            try await connection.execute("CAPABILITY")
        }
        XCTAssertEqual(thrown as? StreamTransportError, .notConnected)
    }

    func test_close_closesTransport_andFurtherExecutesFail() async throws {
        let transport = ScriptedTransport()
        let connection = try await makeConnection(transport: transport)

        await connection.close()

        let thrown = await XCTAssertThrowsErrorAsync {
            try await connection.execute("NOOP")
        }
        XCTAssertEqual(thrown as? StreamTransportError, .notConnected)
        let writes = await transport.writes
        XCTAssertEqual(writes, [], "no LOGOUT is sent by close(): that is the client's call")
    }
}
