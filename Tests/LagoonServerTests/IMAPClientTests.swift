import XCTest
import Foundation
import Logging
@testable import LagoonServer

/// Drives `IMAPClient` over a scripted transport: a QQ-shaped transcript per
/// test, asserting the exact command bytes that leave the machine and the
/// structures that come back.
final class IMAPClientTests: XCTestCase {
    private func makeClient(
        transport: ScriptedTransport,
        readTimeout: Duration = .seconds(5)
    ) async throws -> IMAPClient {
        let connection = IMAPConnection(
            transport: transport,
            logger: Logger(label: "imap-client-tests"),
            readTimeout: readTimeout
        )
        let client = IMAPClient(
            connection: connection,
            logger: Logger(label: "imap-client-tests")
        )
        await transport.enqueue("* OK Lagoon ready")
        try await client.connect(host: "imap.qq.com", port: 993)
        return client
    }

    /// Everything the client has put on the wire, CRLF stripped.
    private func wire(_ transport: ScriptedTransport) async -> [String] {
        await transport.writes.map {
            String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .newlines)
        }
    }

    // MARK: - CAPABILITY

    func test_capability_parsesAndCachesResult() async throws {
        let transport = ScriptedTransport()
        let client = try await makeClient(transport: transport)

        await transport.enqueue("* CAPABILITY IMAP4rev1 ID IDLE MOVE AUTH=PLAIN")
        await transport.enqueue("A0001 OK CAPABILITY completed")

        let first = try await client.capability()
        let second = try await client.capability()

        XCTAssertEqual(first, ["IMAP4REV1", "ID", "IDLE", "MOVE", "AUTH=PLAIN"])
        XCTAssertEqual(second, first, "the cached set is handed back")
        let lines = await wire(transport)
        XCTAssertEqual(lines, ["A0001 CAPABILITY"], "no second round trip")
    }

    /// Spec §3.1 step 5: the capability set must be re-read after login —
    /// IDLE / MOVE only appear once authenticated on some servers.
    func test_capability_isRereadAfterLogin() async throws {
        let transport = ScriptedTransport()
        let client = try await makeClient(transport: transport)

        await transport.enqueue("* CAPABILITY IMAP4rev1 AUTH=PLAIN")
        await transport.enqueue("A0001 OK CAPABILITY completed")
        _ = try await client.capability()

        await transport.enqueue("A0002 OK AUTHENTICATE completed")
        try await client.login(username: "user@qq.com", authCode: "abcdefghijklmnop")

        await transport.enqueue("* CAPABILITY IMAP4rev1 IDLE MOVE")
        await transport.enqueue("A0003 OK CAPABILITY completed")
        let refreshed = try await client.capability()

        XCTAssertEqual(refreshed, ["IMAP4REV1", "IDLE", "MOVE"])
        let lines = await wire(transport)
        XCTAssertEqual(
            lines,
            ["A0001 CAPABILITY", "A0002 AUTHENTICATE PLAIN AHVzZXJAcXEuY29tAGFiY2RlZmdoaWprbG1ub3A=", "A0003 CAPABILITY"]
        )
    }

    // MARK: - Authentication

    func test_login_authenticatesWithSASLIR() async throws {
        let transport = ScriptedTransport()
        let client = try await makeClient(transport: transport)

        await transport.enqueue("A0001 OK AUTHENTICATE completed")
        try await client.login(username: "user@qq.com", authCode: "abcdefghijklmnop")

        let lines = await wire(transport)
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(
            lines[0].hasPrefix("A0001 AUTHENTICATE PLAIN "),
            "SASL-IR keeps the auth code off the command word list: \(lines[0])"
        )
        let payload = lines[0].split(separator: " ").last.map(String.init) ?? ""
        XCTAssertEqual(
            String(decoding: Data(base64Encoded: payload) ?? Data(), as: UTF8.self),
            "\0user@qq.com\0abcdefghijklmnop"
        )
    }

    func test_login_fallsBackToLoginCommandWhenSaslRejected() async throws {
        let transport = ScriptedTransport()
        let client = try await makeClient(transport: transport)

        await transport.enqueue("A0001 NO unsupported authentication mechanism")
        await transport.enqueue("A0002 OK LOGIN completed")
        try await client.login(username: "user@qq.com", authCode: "abcdefghijklmnop")

        let lines = await wire(transport)
        XCTAssertEqual(
            lines,
            [
                "A0001 AUTHENTICATE PLAIN AHVzZXJAcXEuY29tAGFiY2RlZmdoaWprbG1ub3A=",
                #"A0002 LOGIN "user@qq.com" "abcdefghijklmnop""#,
            ]
        )
    }

    /// When the credentials themselves are wrong the fallback must not mask
    /// the typed failure: `SyncEngine` stops retrying on `.authFailed`.
    func test_login_authFailureSurvivesFallback() async throws {
        let transport = ScriptedTransport()
        let client = try await makeClient(transport: transport)

        await transport.enqueue("A0001 NO [AUTHENTICATIONFAILED] Authentication failed")
        await transport.enqueue("A0002 NO [AUTHENTICATIONFAILED] Authentication failed")

        let thrown = await XCTAssertThrowsErrorAsync {
            try await client.login(username: "user@qq.com", authCode: "wrong")
        }
        XCTAssertEqual(thrown as? MailError, .authFailed)
    }

    func test_login_escapesQuotesAndBackslashes() async throws {
        let transport = ScriptedTransport()
        let client = try await makeClient(transport: transport)

        await transport.enqueue("A0001 NO try LOGIN")
        await transport.enqueue("A0002 OK LOGIN completed")
        try await client.login(username: #"we"ird\user"#, authCode: #"pa"ss\word"#)

        let lines = await wire(transport)
        XCTAssertEqual(
            lines[1],
            #"A0002 LOGIN "we\"ird\\user" "pa\"ss\\word""#
        )
    }

    /// An auth code is user input: control characters must never be able to
    /// terminate the command line and inject another one.
    func test_login_rejectsControlCharacters() async throws {
        let transport = ScriptedTransport()
        let client = try await makeClient(transport: transport)

        let thrown = await XCTAssertThrowsErrorAsync {
            try await client.login(username: "user@qq.com", authCode: "code\r\nA0009 LOGOUT")
        }
        XCTAssertEqual(thrown as? MailError, .protocolError("control character in argument"))
        let lines = await wire(transport)
        XCTAssertEqual(lines, [], "nothing reaches the wire")
    }

    // MARK: - ID

    func test_sendID_sendsClientIdentityWhenSupported() async throws {
        let transport = ScriptedTransport()
        let client = try await makeClient(transport: transport)

        await transport.enqueue("* CAPABILITY IMAP4rev1 ID IDLE")
        await transport.enqueue("A0001 OK CAPABILITY completed")
        await transport.enqueue("A0002 OK ID completed")
        try await client.sendID()

        let lines = await wire(transport)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[1], #"A0002 ID ("name" "Lagoon" "version" "1.0")"#)
    }

    func test_sendID_isSkippedWhenServerHasNoID() async throws {
        let transport = ScriptedTransport()
        let client = try await makeClient(transport: transport)

        await transport.enqueue("* CAPABILITY IMAP4rev1 IDLE")
        await transport.enqueue("A0001 OK CAPABILITY completed")
        try await client.sendID()

        let lines = await wire(transport)
        XCTAssertEqual(lines, ["A0001 CAPABILITY"])
    }

    // MARK: - LIST

    func test_listMailboxes_parsesAttributesAndNames() async throws {
        let transport = ScriptedTransport()
        let client = try await makeClient(transport: transport)

        await transport.enqueue(#"* LIST (\HasNoChildren) "/" "INBOX""#)
        await transport.enqueue(#"* LIST (\HasNoChildren \Archive) "/" "归档""#)
        await transport.enqueue(#"* LIST () "/" "Sent Messages""#)
        await transport.enqueue(#"* LSUB () "/" "Junk""#)
        await transport.enqueue("A0001 OK LIST completed")

        let mailboxes = try await client.listMailboxes()

        XCTAssertEqual(
            mailboxes,
            [
                IMAPMailbox(name: "INBOX", attributes: ["\\HasNoChildren"]),
                IMAPMailbox(name: "归档", attributes: ["\\HasNoChildren", "\\Archive"]),
                IMAPMailbox(name: "Sent Messages", attributes: []),
            ],
            "LSUB lines are not mailboxes"
        )
        let lines = await wire(transport)
        XCTAssertEqual(lines, [#"A0001 LIST "" "*""#])
    }

    // MARK: - SELECT

    func test_select_parsesUidValidityUidNextAndExists() async throws {
        let transport = ScriptedTransport()
        let client = try await makeClient(transport: transport)

        await transport.enqueue("* 12 EXISTS")
        await transport.enqueue("* OK [UIDVALIDITY 42] UIDs valid")
        await transport.enqueue("* OK [UIDNEXT 100] Predicted next UID")
        await transport.enqueue(#"* FLAGS (\Answered \Flagged \Deleted \Seen \Draft)"#)
        await transport.enqueue("* OK [PERMANENTFLAGS (\\Seen \\Deleted)] Limited")
        await transport.enqueue("A0001 OK [READ-WRITE] SELECT completed")

        let selected = try await client.select("INBOX")

        XCTAssertEqual(selected, IMAPSelected(exists: 12, uidValidity: 42, uidNext: 100))
        let lines = await wire(transport)
        XCTAssertEqual(lines, [#"A0001 SELECT "INBOX""#])
    }

    func test_select_quotesNamesWithSpaces() async throws {
        let transport = ScriptedTransport()
        let client = try await makeClient(transport: transport)

        await transport.enqueue("* 0 EXISTS")
        await transport.enqueue("* OK [UIDVALIDITY 7] UIDs valid")
        await transport.enqueue("* OK [UIDNEXT 9] Predicted next UID")
        await transport.enqueue("A0001 OK SELECT completed")

        _ = try await client.select("Sent Messages")
        let lines = await wire(transport)
        XCTAssertEqual(lines, [#"A0001 SELECT "Sent Messages""#])
    }

    func test_select_rejectsControlCharactersInMailboxName() async throws {
        let transport = ScriptedTransport()
        let client = try await makeClient(transport: transport)

        let thrown = await XCTAssertThrowsErrorAsync {
            try await client.select("INBOX\r\nA0009 DELETE \"INBOX\"")
        }
        XCTAssertEqual(thrown as? MailError, .protocolError("control character in argument"))
        let lines = await wire(transport)
        XCTAssertEqual(lines, [])
    }

    // MARK: - FETCH

    func test_fetchHeaders_usesPeekAndParsesFoldedHeaders() async throws {
        let transport = ScriptedTransport()
        let client = try await makeClient(transport: transport)

        let first = Data(
            [
                #"From: "Zhang San" <zhangsan@qq.com>"#,
                "Subject: =?utf-8?B?5rWL6K+V?=",
                "Date: Fri, 11 Sep 2026 10:00:00 +0800",
                "Message-ID: <abc123@qq.com>",
                "In-Reply-To: <parent@qq.com>",
                "List-Unsubscribe: <mailto:unsub@qq.com>",
                "X-Folded: first line",
                " second line",
                "",
                "",
            ].joined(separator: "\r\n").utf8
        )
        let second = Data("Subject: second\r\n\r\n".utf8)
        let fields = "FROM SUBJECT DATE MESSAGE-ID IN-REPLY-TO REFERENCES LIST-UNSUBSCRIBE"
        await transport.enqueue(
            #"* 1 FETCH (UID 13 FLAGS (\Seen) INTERNALDATE "11-Sep-2026 10:00:00 +0800" BODY[HEADER.FIELDS (\#(fields))] {\#(first.count)}"#
        )
        await transport.enqueueLiteral(first)
        await transport.enqueue(")")
        await transport.enqueue(
            #"* 2 FETCH (UID 14 FLAGS () INTERNALDATE "10-Sep-2026 22:00:00 -0500" BODY[HEADER.FIELDS (\#(fields))] {\#(second.count)}"#
        )
        await transport.enqueueLiteral(second)
        await transport.enqueue(")")
        await transport.enqueue("A0001 OK FETCH completed")

        let headers = try await client.fetchHeaders(fromUid: 13, fields: [
            "FROM", "SUBJECT", "DATE", "MESSAGE-ID", "IN-REPLY-TO", "REFERENCES", "LIST-UNSUBSCRIBE",
        ])

        XCTAssertEqual(headers.count, 2)
        XCTAssertEqual(headers[0].uid, 13)
        XCTAssertEqual(headers[0].flags, ["\\Seen"])
        XCTAssertEqual(headers[1].uid, 14)
        XCTAssertEqual(headers[1].flags, [])
        // 2026-09-11T02:00:00Z — the +0800 date must be converted to UTC.
        XCTAssertEqual(
            headers[0].internalDate?.timeIntervalSince1970 ?? 0,
            1_789_092_000,
            accuracy: 0.5
        )
        // 2026-09-10T22:00:00-05:00 → 2026-09-11T03:00:00Z.
        XCTAssertEqual(
            headers[1].internalDate?.timeIntervalSince1970 ?? 0,
            1_789_095_600,
            accuracy: 0.5
        )
        XCTAssertEqual(
            headers[0].rawHeaders,
            [
                "from": #""Zhang San" <zhangsan@qq.com>"#,
                "subject": "=?utf-8?B?5rWL6K+V?=",
                "date": "Fri, 11 Sep 2026 10:00:00 +0800",
                "message-id": "<abc123@qq.com>",
                "in-reply-to": "<parent@qq.com>",
                "list-unsubscribe": "<mailto:unsub@qq.com>",
                "x-folded": "first line second line",
            ],
            "keys lowercase, continuations unfolded"
        )

        let command = (await wire(transport)).first ?? ""
        XCTAssertEqual(
            command,
            "A0001 UID FETCH 13:* (UID FLAGS INTERNALDATE BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE MESSAGE-ID IN-REPLY-TO REFERENCES LIST-UNSUBSCRIBE)])"
        )
        XCTAssertFalse(
            command.contains("BODY["),
            "the sync path must never set \\Seen"
        )
    }

    func test_fetchFlags_rescansRange() async throws {
        let transport = ScriptedTransport()
        let client = try await makeClient(transport: transport)

        await transport.enqueue(#"* 1 FETCH (UID 5 FLAGS (\Seen \Answered))"#)
        await transport.enqueue(#"* 2 FETCH (UID 6 FLAGS ())"#)
        await transport.enqueue(#"* 3 FETCH (UID 12 FLAGS (\Seen))"#)
        await transport.enqueue("A0001 OK FETCH completed")

        let flags = try await client.fetchFlags(fromUid: 5, toUid: 12)

        XCTAssertEqual(flags.count, 3)
        XCTAssertEqual(flags[0].uid, 5)
        XCTAssertEqual(flags[0].flags, ["\\Seen", "\\Answered"])
        XCTAssertEqual(flags[1].uid, 6)
        XCTAssertEqual(flags[1].flags, [])
        XCTAssertEqual(flags[2].uid, 12)
        XCTAssertEqual(flags[2].flags, ["\\Seen"])
        let lines = await wire(transport)
        XCTAssertEqual(lines, ["A0001 UID FETCH 5:12 (UID FLAGS)"])
    }

    func test_searchUID_quotesMessageIDAndReturnsHighestMatch() async throws {
        let transport = ScriptedTransport()
        let client = try await makeClient(transport: transport)

        await transport.enqueue(#"* SEARCH 44 91"#)
        await transport.enqueue("A0001 OK SEARCH completed")

        let uid = try await client.searchUID(messageID: "<abc@example.com>")

        XCTAssertEqual(uid, 91)
        let lines = await wire(transport)
        XCTAssertEqual(
            lines,
            [#"A0001 UID SEARCH HEADER Message-ID "<abc@example.com>""#]
        )
    }

    func test_allUIDs_returnsCompleteSelectedMailboxSet() async throws {
        let transport = ScriptedTransport()
        let client = try await makeClient(transport: transport)

        await transport.enqueue(#"* SEARCH 5 6 12 91"#)
        await transport.enqueue("A0001 OK SEARCH completed")

        let uids = try await client.allUIDs()

        XCTAssertEqual(uids, Set([5, 6, 12, 91]))
        let lines = await wire(transport)
        XCTAssertEqual(lines, ["A0001 UID SEARCH ALL"])
    }

    func test_fetchTextSnippet_readsLiteralBytes() async throws {
        let transport = ScriptedTransport()
        let client = try await makeClient(transport: transport)

        let snippet = Data("Hello Lagoon".utf8)
        await transport.enqueue("* 1 FETCH (UID 5 BODY[]<0> {\(snippet.count)}")
        await transport.enqueueLiteral(snippet)
        await transport.enqueue(")")
        await transport.enqueue("A0001 OK FETCH completed")

        let fetched = try await client.fetchTextSnippet(uid: 5)

        XCTAssertEqual(fetched, [IMAPFetchedText(uid: 5, snippet: snippet)])
        let lines = await wire(transport)
        XCTAssertEqual(lines, ["A0001 UID FETCH 5 (UID BODY.PEEK[]<0.32768>)"])
    }

    func test_fetchFullBody_returnsRawBytes() async throws {
        let transport = ScriptedTransport()
        let client = try await makeClient(transport: transport)

        let raw = Data("Subject: hi\r\n\r\nBody".utf8)
        await transport.enqueue("* 1 FETCH (BODY[] {\(raw.count)}")
        await transport.enqueueLiteral(raw)
        await transport.enqueue(")")
        await transport.enqueue("A0001 OK FETCH completed")

        let body = try await client.fetchFullBody(uid: 5)

        XCTAssertEqual(body, raw)
        let lines = await wire(transport)
        XCTAssertEqual(lines, ["A0001 UID FETCH 5 (BODY.PEEK[])"])
    }

    /// A UID that no longer exists comes back with no FETCH data at all
    /// (spec §3.7 → 410 message-gone).
    func test_fetchFullBody_emptyResult_throwsMessageGone() async throws {
        let transport = ScriptedTransport()
        let client = try await makeClient(transport: transport)

        await transport.enqueue("A0001 OK FETCH completed")

        let thrown = await XCTAssertThrowsErrorAsync {
            try await client.fetchFullBody(uid: 5)
        }
        XCTAssertEqual(thrown as? MailError, .messageGone)
    }

    // MARK: - STORE / MOVE / COPY / CREATE

    func test_store_issuesAddAndRemoveSeparately() async throws {
        let transport = ScriptedTransport()
        let client = try await makeClient(transport: transport)

        await transport.enqueue("A0001 OK STORE completed")
        try await client.store(uid: 7, add: ["\\Seen"], remove: [])
        await transport.enqueue("A0002 OK STORE completed")
        try await client.store(uid: 7, add: [], remove: ["\\Seen"])
        try await client.store(uid: 7, add: [], remove: [])

        let lines = await wire(transport)
        XCTAssertEqual(
            lines,
            ["A0001 UID STORE 7 +FLAGS (\\Seen)", "A0002 UID STORE 7 -FLAGS (\\Seen)"],
            "an empty change sends nothing"
        )
    }

    func test_move_requiresMoveCapability() async throws {
        let transport = ScriptedTransport()
        let client = try await makeClient(transport: transport)

        await transport.enqueue("* CAPABILITY IMAP4rev1 IDLE")
        await transport.enqueue("A0001 OK CAPABILITY completed")
        _ = try await client.capability()

        let thrown = await XCTAssertThrowsErrorAsync {
            try await client.move(uid: 7, to: "Archive")
        }
        XCTAssertEqual(thrown as? MailError, .protocolError("MOVE not supported"))
        let lines = await wire(transport)
        XCTAssertEqual(lines, ["A0001 CAPABILITY"], "no MOVE reaches the wire")
    }

    func test_move_andUnarchive_issueUidMove() async throws {
        let transport = ScriptedTransport()
        let client = try await makeClient(transport: transport)

        await transport.enqueue("* CAPABILITY IMAP4rev1 IDLE MOVE")
        await transport.enqueue("A0001 OK CAPABILITY completed")
        _ = try await client.capability()
        await transport.enqueue("A0002 OK MOVE completed")
        await transport.enqueue("A0003 OK MOVE completed")

        try await client.move(uid: 7, to: "Archive")
        try await client.move(uid: 7, to: "INBOX")

        let lines = await wire(transport)
        XCTAssertEqual(
            lines,
            [
                "A0001 CAPABILITY",
                #"A0002 UID MOVE 7 "Archive""#,
                #"A0003 UID MOVE 7 "INBOX""#,
            ]
        )
    }

    func test_copyAndCreateMailbox_quoteNames() async throws {
        let transport = ScriptedTransport()
        let client = try await makeClient(transport: transport)

        await transport.enqueue("A0001 OK COPY completed")
        await transport.enqueue("A0002 OK CREATE completed")
        try await client.copy(uid: 7, to: "Archive")
        try await client.createMailbox(#"La"goon"#)

        let lines = await wire(transport)
        XCTAssertEqual(
            lines,
            [#"A0001 UID COPY 7 "Archive""#, #"A0002 CREATE "La\"goon""#]
        )
    }

    func test_append_sendsLiteralAfterContinuation() async throws {
        let transport = ScriptedTransport()
        let client = try await makeClient(transport: transport)
        let message = Data("Subject: test\r\n\r\nbody\r\n".utf8)

        await transport.enqueue("+ Ready for literal")
        await transport.enqueue("A0001 OK APPEND completed")

        try await client.append(mailbox: "Sent Messages", message: message)

        let writes = await transport.writes
        XCTAssertEqual(
            String(decoding: writes[0], as: UTF8.self),
            "A0001 APPEND \"Sent Messages\" (\\Seen) {\(message.count)}\r\n"
        )
        XCTAssertEqual(writes[1], message)
        XCTAssertEqual(String(decoding: writes[2], as: UTF8.self), "\r\n")
    }

    // MARK: - IDLE / LOGOUT

    func test_idle_delegatesToConnection() async throws {
        let transport = ScriptedTransport()
        let client = try await makeClient(transport: transport)

        await transport.enqueue("+ idling")
        await transport.enqueue("* 3 EXISTS")
        await transport.enqueue("A0001 OK IDLE terminated")

        let events = try await client.idle(waitUpTo: .seconds(5))

        XCTAssertEqual(events.first?.atoms, ["*", "3", "EXISTS"])
        let lines = await wire(transport)
        XCTAssertEqual(
            lines,
            ["A0001 IDLE", "DONE"]
        )
    }

    func test_logout_sendsLogoutAndClosesConnection() async throws {
        let transport = ScriptedTransport()
        let client = try await makeClient(transport: transport)

        await transport.enqueue("* BYE Lagoon logging out")
        await transport.enqueue("A0001 OK LOGOUT completed")
        await client.logout()

        let lines = await wire(transport)
        XCTAssertEqual(lines, ["A0001 LOGOUT"])
        let thrown = await XCTAssertThrowsErrorAsync {
            try await client.select("INBOX")
        }
        XCTAssertEqual(thrown as? StreamTransportError, .notConnected)
    }

    /// A hung-up socket during LOGOUT is not an error worth surfacing: the
    /// session is over either way.
    func test_logout_swallowsServerErrors() async throws {
        let transport = ScriptedTransport()
        let client = try await makeClient(transport: transport)

        await transport.enqueue("A0001 NO logout failed")
        await client.logout()
    }
}
