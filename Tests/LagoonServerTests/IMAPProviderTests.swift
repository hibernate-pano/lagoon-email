import XCTest
import Foundation
import Logging
import LagoonKit
@testable import LagoonServer

/// Drives `IMAPProvider` over a scripted transport: each test queues a
/// QQ-shaped transcript and asserts both the commands that leave the machine
/// and the provider-neutral structures that come back.
///
/// The account carries its sealed credentials in memory (the shape the connect
/// flow hands to `probe()`), so no database is involved.
final class IMAPProviderTests: XCTestCase {
    private static let key = TokenKeyFixture.freshKey()

    private let headerFields =
        "FROM SUBJECT DATE MESSAGE-ID IN-REPLY-TO REFERENCES LIST-UNSUBSCRIBE"

    // MARK: - Scaffolding

    private func makeProvider(
        transport: ScriptedTransport,
        reconcilesInbox: Bool = false
    ) throws -> (provider: IMAPProvider, account: Account) {
        let account = Account(
            id: UUID(),
            provider: .qq,
            oauthUser: "user@qq.com",
            email: "user@qq.com",
            credentials: try CredentialVault.seal(
                .imap(username: "user@qq.com", authCode: "authcode0123456789")
            )
        )
        let provider = IMAPProvider(
            account: account,
            db: nil,
            logger: Logger(label: "imap-provider-tests"),
            reconcilesInbox: reconcilesInbox,
            transportFactory: { transport }
        )
        return (provider, account)
    }

    /// Everything the provider has put on the wire, CRLF stripped.
    private func wire(_ transport: ScriptedTransport) async -> [String] {
        await transport.writes.map {
            String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .newlines)
        }
    }

    private func tag(_ number: Int) -> String {
        String(format: "A%04d", number)
    }

    /// connect → AUTHENTICATE → CAPABILITY → ID: the prologue every fresh
    /// connection runs (spec §3.1 steps 1–5).
    private func scriptHandshake(
        _ transport: ScriptedTransport,
        capabilities: String = "IMAP4rev1 ID IDLE MOVE AUTH=PLAIN"
    ) async {
        await transport.enqueue("* OK Lagoon ready")
        await transport.enqueue("\(tag(1)) OK AUTHENTICATE completed")
        await transport.enqueue("* CAPABILITY \(capabilities)")
        await transport.enqueue("\(tag(2)) OK CAPABILITY completed")
        await transport.enqueue("\(tag(3)) OK ID completed")
    }

    private func scriptList(
        _ transport: ScriptedTransport,
        number: Int,
        mailboxes: [(name: String, attribute: String?)]
    ) async {
        for mailbox in mailboxes {
            let attributes = mailbox.attribute.map { "\\HasNoChildren \($0)" } ?? "\\HasNoChildren"
            await transport.enqueue(#"* LIST (\#(attributes)) "/" "\#(mailbox.name)""#)
        }
        await transport.enqueue("\(tag(number)) OK LIST completed")
    }

    private func scriptSelect(
        _ transport: ScriptedTransport,
        number: Int,
        exists: Int = 3,
        uidValidity: Int64 = 42,
        uidNext: Int64
    ) async {
        await transport.enqueue("* \(exists) EXISTS")
        await transport.enqueue("* OK [UIDVALIDITY \(uidValidity)] UIDs valid")
        await transport.enqueue("* OK [UIDNEXT \(uidNext)] Predicted next UID")
        await transport.enqueue("\(tag(number)) OK [READ-WRITE] \(IMAPClient.selectVerb) completed")
    }

    /// One header FETCH response, split across the literal framing the server
    /// actually uses.
    private func scriptHeaderFetch(
        _ transport: ScriptedTransport,
        sequence: Int,
        uid: Int64,
        flags: String,
        internalDate: String = "11-Sep-2026 10:00:00 +0800",
        headers: [(String, String)]
    ) async {
        let block = headers.map { "\($0.0): \($0.1)" }.joined(separator: "\r\n") + "\r\n\r\n"
        let data = Data(block.utf8)
        await transport.enqueue(
            #"* \#(sequence) FETCH (UID \#(uid) FLAGS (\#(flags)) INTERNALDATE "\#(internalDate)" BODY[HEADER.FIELDS (\#(headerFields))] {\#(data.count)}"#
        )
        await transport.enqueueLiteral(data)
        await transport.enqueue(")")
    }

    /// `BODY[]<0.N>` answer for one UID: the message prefix (headers + body)
    /// that `BODY.PEEK[]<0.32768>` returns, so the decoder can see the MIME
    /// content type and transfer encoding.
    private func scriptSnippet(
        _ transport: ScriptedTransport,
        sequence: Int,
        uid: Int64,
        message: String
    ) async {
        let data = Data(message.utf8)
        await transport.enqueue(#"* \#(sequence) FETCH (UID \#(uid) BODY[]<0> {\#(data.count)}"#)
        await transport.enqueueLiteral(data)
        await transport.enqueue(")")
    }

    /// Runs one pull round whose single message is `message` and returns the
    /// snippet the provider derived from it. The message is delivered exactly
    /// as authored, so a caller can hand over a truncated window on purpose.
    private func pulledSnippet(_ message: String) async throws -> String? {
        let transport = ScriptedTransport()
        let (provider, _) = try makeProvider(transport: transport)
        await scriptHandshake(transport)
        await scriptList(transport, number: 4, mailboxes: [
            (name: "INBOX", attribute: nil),
            (name: "Archive", attribute: "\\Archive"),
        ])
        await scriptSelect(transport, number: 5, uidValidity: 42, uidNext: 1)
        await scriptHeaderFetch(transport, sequence: 1, uid: 1, flags: "", headers: [
            ("From", "zhangsan@qq.com"),
            ("Subject", "snippet"),
        ])
        await transport.enqueue("A0006 OK FETCH completed")
        await scriptSnippet(transport, sequence: 1, uid: 1, message: message)
        await transport.enqueue("A0007 OK FETCH completed")
        let change = try await provider.pullChanges(after: MailSyncState(), waitUpTo: .zero)
        return try XCTUnwrap(change.upserts.first).snippet
    }

    // MARK: - probe

    func test_probe_connectsAuthenticatesListsAndSelectsInbox() async throws {
        try await TokenKeyFixture.withKeyAsync(Self.key) {
            let transport = ScriptedTransport()
            let (provider, _) = try makeProvider(transport: transport)
            await scriptHandshake(transport)
            await scriptList(transport, number: 4, mailboxes: [
                (name: "INBOX", attribute: nil),
                (name: "Archive", attribute: "\\Archive"),
            ])
            await scriptSelect(transport, number: 5, uidNext: 100)

            try await provider.probe()

            let lines = await wire(transport)
            XCTAssertEqual(lines[0], "A0001 AUTHENTICATE PLAIN AHVzZXJAcXEuY29tAGF1dGhjb2RlMDEyMzQ1Njc4OQ==")
            XCTAssertTrue(lines.contains(#"A0004 LIST "" "*""#), "folders are listed to find the archive role")
            XCTAssertTrue(lines.contains(#"A0005 SELECT "INBOX""#), "probe must prove INBOX selects")
            XCTAssertFalse(
                lines.contains { $0.contains("CREATE") },
                "an \\Archive folder exists; nothing needs creating"
            )
        }
    }

    /// A rejected auth code must surface as `.authFailed` — the sync loop uses
    /// that to stop retrying (QQ rate-limits repeated failed logins).
    func test_probe_authRejected_isAuthFailed() async throws {
        try await TokenKeyFixture.withKeyAsync(Self.key) {
            let transport = ScriptedTransport()
            let (provider, _) = try makeProvider(transport: transport)
            await transport.enqueue("* OK Lagoon ready")
            await transport.enqueue("A0001 NO unsupported authentication mechanism")
            await transport.enqueue("A0002 NO [AUTHENTICATIONFAILED] Authentication failed")

            let thrown = await XCTAssertThrowsErrorAsync { try await provider.probe() }

            XCTAssertEqual(thrown as? MailError, .authFailed)
        }
    }

    // MARK: - capabilities

    /// No `\Archive` folder: a one-time CREATE makes archiving possible and the
    /// created name becomes the cursor's archive target (spec §4.3).
    func test_capabilities_createsArchiveFolderWhenServerHasNone() async throws {
        try await TokenKeyFixture.withKeyAsync(Self.key) {
            let transport = ScriptedTransport()
            let (provider, _) = try makeProvider(transport: transport)
            await scriptHandshake(transport)
            await scriptList(transport, number: 4, mailboxes: [
                (name: "INBOX", attribute: nil),
                (name: "Sent Messages", attribute: nil),
            ])
            await transport.enqueue(#"A0005 OK CREATE completed"#)
            await scriptSelect(transport, number: 6, uidValidity: 42, uidNext: 1)
            await transport.enqueue("A0007 OK FETCH completed")

            let capabilities = await provider.capabilities()

            XCTAssertTrue(capabilities.archiveFolder)
            XCTAssertTrue(capabilities.idle)
            XCTAssertTrue(capabilities.move)
            XCTAssertTrue(capabilities.serverSnippet)
            let lines = await wire(transport)
            XCTAssertTrue(lines.contains(#"A0005 CREATE "Archive""#))

            let change = try await provider.pullChanges(after: MailSyncState(), waitUpTo: .zero)
            XCTAssertEqual(change.cursor.archiveFolder, "Archive")
            XCTAssertTrue(change.upserts.isEmpty)
            XCTAssertEqual(change.cursor.lastUid, nil, "an empty mailbox advances nothing")
        }
    }

    func test_capabilities_createRefused_archiveFolderUnavailable() async throws {
        try await TokenKeyFixture.withKeyAsync(Self.key) {
            let transport = ScriptedTransport()
            let (provider, _) = try makeProvider(transport: transport)
            await scriptHandshake(transport)
            await scriptList(transport, number: 4, mailboxes: [(name: "INBOX", attribute: nil)])
            await transport.enqueue(#"A0005 NO CREATE failed"#)

            let capabilities = await provider.capabilities()

            XCTAssertFalse(capabilities.archiveFolder)
            XCTAssertTrue(capabilities.move, "the rest of the negotiation still stands")
        }
    }

    // MARK: - pull

    /// First pull: no cursor, so the window is `max(1, UIDNEXT - 500)`; headers
    /// arrive RFC 2047-encoded and the read state comes from `\Seen`.
    func test_pullChanges_firstRound_readsWindowAndDecodesHeaders() async throws {
        try await TokenKeyFixture.withKeyAsync(Self.key) {
            let transport = ScriptedTransport()
            let (provider, _) = try makeProvider(transport: transport)
            await scriptHandshake(transport)
            await scriptList(transport, number: 4, mailboxes: [
                (name: "INBOX", attribute: nil),
                (name: "Archive", attribute: "\\Archive"),
            ])
            await scriptSelect(transport, number: 5, uidValidity: 42, uidNext: 1000)
            await scriptHeaderFetch(transport, sequence: 1, uid: 900, flags: "\\Seen", headers: [
                ("From", "\"Zhang San\" <zhangsan@qq.com>"),
                ("Subject", "=?UTF-8?B?5rWL6K+V?="),
                ("Message-ID", "<m900@qq.com>"),
                ("References", "<root@qq.com> <parent@qq.com>"),
            ])
            await scriptHeaderFetch(transport, sequence: 2, uid: 901, flags: "", headers: [
                ("From", "lisi@qq.com"),
                ("Subject", "第二封"),
            ])
            await transport.enqueue("A0006 OK FETCH completed")
            await scriptSnippet(
                transport, sequence: 1, uid: 900,
                message: "Content-Type: text/plain; charset=UTF-8\r\n\r\nHello from QQ"
            )
            await transport.enqueue("A0007 OK FETCH completed")
            await scriptSnippet(
                transport, sequence: 2, uid: 901,
                message: "Content-Type: text/plain; charset=UTF-8\r\n"
                    + "Content-Transfer-Encoding: base64\r\n\r\nSGVsbG8gd29ybGQhIHN0dWZm"
            )
            await transport.enqueue("A0008 OK FETCH completed")

            let change = try await provider.pullChanges(after: MailSyncState(), waitUpTo: .zero)

            let lines = await wire(transport)
            XCTAssertTrue(
                lines.contains(
                    "A0006 UID FETCH 500:* (UID FLAGS INTERNALDATE BODY.PEEK[HEADER.FIELDS (\(headerFields))])"
                ),
                "the first pull backfills a bounded window instead of the whole mailbox"
            )
            XCTAssertEqual(change.upserts.count, 2)
            XCTAssertEqual(change.cursor.lastUid, 901)
            XCTAssertEqual(change.cursor.uidValidity, 42)
            XCTAssertFalse(change.resetRequired)

            let first = try XCTUnwrap(change.upserts.first)
            XCTAssertEqual(first.remoteId, "<m900@qq.com>")
            XCTAssertEqual(first.subject, "测试", "RFC 2047 encoded words are decoded")
            XCTAssertEqual(first.fromAddress, "zhangsan@qq.com")
            XCTAssertEqual(first.fromName, "Zhang San")
            XCTAssertTrue(first.isRead, "\\Seen on the wire means read")
            XCTAssertEqual(first.threadId, "<root@qq.com>", "References wins as the thread key")
            XCTAssertEqual(first.snippet, "Hello from QQ")

            let second = try XCTUnwrap(change.upserts.last)
            XCTAssertEqual(second.remoteId, "uid:901")
            XCTAssertFalse(second.isRead)
            XCTAssertEqual(second.fromAddress, "lisi@qq.com")
            XCTAssertEqual(second.threadId, "uid:901", "no References and no Message-ID falls back to the UID")
            XCTAssertEqual(
                second.snippet,
                "Hello world! stuff",
                "the prefix now carries headers, so a base64 text part decodes to readable text"
            )
        }
    }

    /// The production reconciliation pass builds the complete INBOX identity
    /// map once, then `UID SEARCH ALL` removes a UID another client moved out
    /// of INBOX from the authoritative set returned to the store.
    func test_pullChanges_reconcilesMessagesMovedOutOfInbox() async throws {
        try await TokenKeyFixture.withKeyAsync(Self.key) {
            let transport = ScriptedTransport()
            let (provider, _) = try makeProvider(transport: transport, reconcilesInbox: true)
            await scriptHandshake(transport)
            await scriptList(transport, number: 4, mailboxes: [
                (name: "INBOX", attribute: nil),
                (name: "Archive", attribute: "\\Archive"),
            ])
            await scriptSelect(transport, number: 5, uidValidity: 42, uidNext: 3)

            await scriptHeaderFetch(transport, sequence: 1, uid: 1, flags: "", headers: [
                ("Message-ID", "<m1@qq.com>"),
            ])
            await scriptHeaderFetch(transport, sequence: 2, uid: 2, flags: "", headers: [
                ("Message-ID", "<m2@qq.com>"),
            ])
            await transport.enqueue("A0006 OK FETCH completed")

            await transport.enqueue("* SEARCH 1")
            await transport.enqueue("A0007 OK SEARCH completed")

            await transport.enqueue("A0008 OK FETCH completed")

            let change = try await provider.pullChanges(
                after: MailSyncState(uidValidity: 42, lastUid: nil),
                waitUpTo: .zero
            )

            XCTAssertEqual(change.inboxRemoteIds, Set(["<m1@qq.com>"]))
            let lines = await wire(transport)
            XCTAssertTrue(lines.contains("A0006 UID FETCH 1:* (UID FLAGS INTERNALDATE BODY.PEEK[HEADER.FIELDS (\(headerFields))])"))
            XCTAssertTrue(lines.contains("A0007 UID SEARCH ALL"))
            XCTAssertTrue(lines.contains("A0008 UID FETCH 1:* (UID FLAGS INTERNALDATE BODY.PEEK[HEADER.FIELDS (\(headerFields))])"))
        }
    }

    /// Second pull: the cursor's `lastUid` makes it `UID FETCH <lastUid + 1>:*`
    /// and no new mail leaves the cursor untouched.
    /// Sent-folder reply detection (V2 A2): In-Reply-To/References harvested
    /// as reply signals, Sent mail never stored as rows, and a steady-state
    /// round with no new Sent mail skips the FETCH.
    func test_pullChanges_harvestsSentRepliesWithoutStoringSentMail() async throws {
        try await TokenKeyFixture.withKeyAsync(Self.key) {
            let transport = ScriptedTransport()
            let (provider, _) = try makeProvider(transport: transport)
            await scriptHandshake(transport)
            await scriptList(transport, number: 4, mailboxes: [
                (name: "INBOX", attribute: nil),
                (name: "Archive", attribute: "\\Archive"),
                (name: "Sent", attribute: "\\Sent"),
            ])
            await scriptSelect(transport, number: 5, uidValidity: 42, uidNext: 1000)
            await scriptHeaderFetch(transport, sequence: 1, uid: 900, flags: "\\Seen", headers: [
                ("From", "boss@qq.com"),
                ("Subject", "Q3 plan"),
                ("Message-ID", "<m900@qq.com>"),
            ])
            await transport.enqueue("A0006 OK FETCH completed")
            await scriptSnippet(
                transport, sequence: 1, uid: 900,
                message: "Content-Type: text/plain; charset=UTF-8\r\n\r\nHi"
            )
            await transport.enqueue("A0007 OK FETCH completed")
            // Sent folder scan: one reply answering <m900@qq.com>.
            await scriptSelect(transport, number: 8, exists: 1, uidValidity: 7, uidNext: 52)
            await scriptHeaderFetch(transport, sequence: 1, uid: 50, flags: "\\Seen", headers: [
                ("From", "user@qq.com"),
                ("Subject", "Re: Q3 plan"),
                ("Message-ID", "<reply50@qq.com>"),
                ("In-Reply-To", "<m900@qq.com>"),
            ])
            await transport.enqueue("A0009 OK FETCH completed")

            let change = try await provider.pullChanges(after: MailSyncState(), waitUpTo: .zero)

            XCTAssertEqual(change.upserts.count, 1, "Sent mail is never stored as rows")
            XCTAssertEqual(change.repliedMessageIds, ["<m900@qq.com>"])
            XCTAssertEqual(change.cursor.sentLastUid, 50)
            XCTAssertEqual(change.cursor.sentUidValidity, 7)
            XCTAssertEqual(change.cursor.sentFolder, "Sent")
            var lines = await wire(transport)
            XCTAssertTrue(lines.contains("A0008 SELECT \"Sent\""))

            // Second round: nothing new anywhere. Inbox FETCH is empty, the
            // Seen rescan finds no flip, and the Sent scan skips its FETCH.
            await scriptSelect(transport, number: 10, uidValidity: 42, uidNext: 901)
            await transport.enqueue("A0011 OK FETCH completed")
            await transport.enqueue(#"* 1 FETCH (UID 900 FLAGS (\Seen))"#)
            await transport.enqueue("A0012 OK FETCH completed")
            await scriptSelect(transport, number: 13, exists: 1, uidValidity: 7, uidNext: 51)

            let second = try await provider.pullChanges(after: change.cursor, waitUpTo: .zero)

            XCTAssertTrue(second.repliedMessageIds.isEmpty)
            XCTAssertEqual(second.cursor.sentLastUid, 50)
            lines = await wire(transport)
            XCTAssertEqual(
                lines.filter { $0.contains("UID FETCH 1:*") }.count, 1,
                "steady-state Sent scan must not FETCH again"
            )
        }
    }

    /// Finding 4: a round that harvested new sent Message-IDs but saw no new
    /// inbox mail must still be returned, so the engine records the reply
    /// signal and persists the sent cursor. Otherwise the pull keeps looping
    /// on the same (unchanged) `cursor`, re-scanning the same 200-message Sent
    /// backfill every time and never advancing.
    func test_pullChanges_returnsSentOnlyRoundInsteadOfRescanningSent() async throws {
        try await TokenKeyFixture.withKeyAsync(Self.key) {
            let transport = ScriptedTransport()
            let (provider, _) = try makeProvider(transport: transport)
            await scriptHandshake(transport)
            await scriptList(transport, number: 4, mailboxes: [
                (name: "INBOX", attribute: nil),
                (name: "Archive", attribute: "\\Archive"),
                (name: "Sent", attribute: "\\Sent"),
            ])
            // Inbox round: no new mail at all (cursor already past everything).
            await scriptSelect(transport, number: 5, uidValidity: 42, uidNext: 901)
            await transport.enqueue("A0006 OK FETCH completed")
            await transport.enqueue(#"* 1 FETCH (UID 900 FLAGS (\Seen))"#)
            await transport.enqueue("A0007 OK FETCH completed")
            // Sent scan: one brand-new reply. Nothing else is scripted — a
            // second round would hit `closed` and fail the test.
            await scriptSelect(transport, number: 8, exists: 1, uidValidity: 7, uidNext: 52)
            await scriptHeaderFetch(transport, sequence: 1, uid: 50, flags: "\\Seen", headers: [
                ("From", "user@qq.com"),
                ("Subject", "Re: Q3 plan"),
                ("Message-ID", "<reply50@qq.com>"),
                ("In-Reply-To", "<m900@qq.com>"),
            ])
            await transport.enqueue("A0009 OK FETCH completed")

            // A budget below the poll interval would make the old code sleep
            // and re-round; the sent harvest must end the pull on its own.
            let change = try await provider.pullChanges(
                after: MailSyncState(uidValidity: 42, lastUid: 900),
                waitUpTo: .milliseconds(1)
            )

            XCTAssertTrue(change.upserts.isEmpty, "no new inbox mail in this round")
            XCTAssertEqual(
                change.repliedMessageIds, ["<m900@qq.com>"],
                "a sent-only round must not discard the reply signal"
            )
            XCTAssertEqual(change.cursor.sentLastUid, 50)
            let lines = await wire(transport)
            XCTAssertEqual(
                lines.filter { $0.contains("SELECT \"Sent\"") }.count, 1,
                "the Sent window must be scanned once, not re-harvested every round"
            )
        }
    }

    func test_pullChanges_secondRound_fetchesAfterLastUid() async throws {
        try await TokenKeyFixture.withKeyAsync(Self.key) {
            let transport = ScriptedTransport()
            let (provider, _) = try makeProvider(transport: transport)
            await scriptHandshake(transport)
            await scriptList(transport, number: 4, mailboxes: [
                (name: "INBOX", attribute: nil),
                (name: "Archive", attribute: "\\Archive"),
            ])
            await scriptSelect(transport, number: 5, uidValidity: 7, uidNext: 20)
            await transport.enqueue("A0006 OK FETCH completed")
            await transport.enqueue(#"* 1 FETCH (UID 5 FLAGS (\Seen))"#)
            await transport.enqueue("A0007 OK FETCH completed")

            let change = try await provider.pullChanges(
                after: MailSyncState(uidValidity: 7, lastUid: 5),
                waitUpTo: .zero
            )

            XCTAssertTrue(change.upserts.isEmpty)
            XCTAssertEqual(change.cursor.lastUid, 5)
            XCTAssertEqual(change.cursor.uidValidity, 7)
            let lines = await wire(transport)
            XCTAssertTrue(
                lines.contains(
                    "A0006 UID FETCH 6:* (UID FLAGS INTERNALDATE BODY.PEEK[HEADER.FIELDS (\(headerFields))])"
                )
            )
            XCTAssertTrue(lines.contains("A0007 UID FETCH 1:5 (UID FLAGS)"))
        }
    }

    /// A read-state flip made on another client is reported as an upsert that
    /// carries the real headers (the store overwrites `subject` on conflict).
    func test_pullChanges_readStateFlip_reportsFullHeader() async throws {
        try await TokenKeyFixture.withKeyAsync(Self.key) {
            let transport = ScriptedTransport()
            let (provider, _) = try makeProvider(transport: transport)
            await scriptHandshake(transport)
            await scriptList(transport, number: 4, mailboxes: [
                (name: "INBOX", attribute: nil),
                (name: "Archive", attribute: "\\Archive"),
            ])
            await scriptSelect(transport, number: 5, uidValidity: 42, uidNext: 10)
            await scriptHeaderFetch(transport, sequence: 1, uid: 5, flags: "", headers: [
                ("From", "zhangsan@qq.com"),
                ("Subject", "未读"),
                ("Message-ID", "<m5@qq.com>"),
            ])
            await transport.enqueue("A0006 OK FETCH completed")
            await scriptSnippet(
                transport, sequence: 1, uid: 5,
                message: "Content-Type: text/plain; charset=UTF-8\r\n\r\nhello"
            )
            await transport.enqueue("A0007 OK FETCH completed")

            let first = try await provider.pullChanges(
                after: MailSyncState(uidValidity: 42),
                waitUpTo: .zero
            )
            XCTAssertEqual(first.upserts.count, 1)
            XCTAssertFalse(try XCTUnwrap(first.upserts.first).isRead)

            await scriptSelect(transport, number: 8, uidValidity: 42, uidNext: 10)
            await transport.enqueue("A0009 OK FETCH completed")
            await transport.enqueue(#"* 1 FETCH (UID 5 FLAGS (\Seen))"#)
            await transport.enqueue("A0010 OK FETCH completed")
            await scriptHeaderFetch(transport, sequence: 1, uid: 5, flags: "\\Seen", headers: [
                ("From", "zhangsan@qq.com"),
                ("Subject", "未读"),
                ("Message-ID", "<m5@qq.com>"),
            ])
            await transport.enqueue("A0011 OK FETCH completed")

            let second = try await provider.pullChanges(
                after: first.cursor,
                waitUpTo: .zero
            )

            let lines = await wire(transport)
            XCTAssertTrue(
                lines.contains(
                    "A0011 UID FETCH 5 (UID FLAGS INTERNALDATE BODY.PEEK[HEADER.FIELDS (\(headerFields))])"
                ),
                "a flip re-reads that one message's headers"
            )
            XCTAssertEqual(second.upserts.count, 1)
            let flipped = try XCTUnwrap(second.upserts.first)
            XCTAssertEqual(flipped.remoteId, "<m5@qq.com>")
            XCTAssertTrue(flipped.isRead)
            XCTAssertEqual(flipped.subject, "未读", "the upsert must not blank the subject")
        }
    }

    /// UIDVALIDITY moved: every stored UID is meaningless, so the store is told
    /// to wipe before the next round backfills.
    func test_pullChanges_uidValidityChange_requiresReset() async throws {
        try await TokenKeyFixture.withKeyAsync(Self.key) {
            let transport = ScriptedTransport()
            let (provider, _) = try makeProvider(transport: transport)
            await scriptHandshake(transport)
            await scriptList(transport, number: 4, mailboxes: [
                (name: "INBOX", attribute: nil),
                (name: "Archive", attribute: "\\Archive"),
            ])
            await scriptSelect(transport, number: 5, uidValidity: 99, uidNext: 3)

            let change = try await provider.pullChanges(
                after: MailSyncState(uidValidity: 7, lastUid: 5),
                waitUpTo: .zero
            )

            XCTAssertTrue(change.resetRequired)
            XCTAssertTrue(change.upserts.isEmpty)
            XCTAssertEqual(change.cursor.uidValidity, 99)
            XCTAssertNil(change.cursor.lastUid)
            XCTAssertEqual(change.cursor.archiveFolder, "Archive")
        }
    }

    // MARK: - mutations

    func test_archive_movesToResolvedFolder() async throws {
        try await TokenKeyFixture.withKeyAsync(Self.key) {
            let transport = ScriptedTransport()
            let (provider, _) = try makeProvider(transport: transport)
            await scriptHandshake(transport)
            await scriptList(transport, number: 4, mailboxes: [
                (name: "INBOX", attribute: nil),
                (name: "归档", attribute: "\\Archive"),
            ])
            await scriptSelect(transport, number: 5, uidValidity: 42, uidNext: 9)
            await transport.enqueue("A0006 OK MOVE completed")

            try await provider.archive(remoteId: "7")

            let lines = await wire(transport)
            XCTAssertEqual(lines.last, #"A0006 UID MOVE 7 "归档""#)
        }
    }

    func test_unarchive_movesBackToInbox() async throws {
        try await TokenKeyFixture.withKeyAsync(Self.key) {
            let transport = ScriptedTransport()
            let (provider, _) = try makeProvider(transport: transport)
            await scriptHandshake(transport)
            await scriptList(transport, number: 4, mailboxes: [
                (name: "INBOX", attribute: nil),
                (name: "归档", attribute: "\\Archive"),
            ])
            await scriptSelect(transport, number: 5, uidValidity: 42, uidNext: 9)
            await transport.enqueue("A0006 OK MOVE completed")

            try await provider.unarchive(remoteId: "7")

            let lines = await wire(transport)
            XCTAssertTrue(lines.contains(#"A0005 SELECT "归档""#))
            XCTAssertEqual(lines.last, #"A0006 UID MOVE 7 "INBOX""#)
        }
    }

    func test_unarchive_stableMessageID_resolvesTheArchiveUID() async throws {
        try await TokenKeyFixture.withKeyAsync(Self.key) {
            let transport = ScriptedTransport()
            let (provider, _) = try makeProvider(transport: transport)
            await scriptHandshake(transport)
            await scriptList(transport, number: 4, mailboxes: [
                (name: "INBOX", attribute: nil),
                (name: "归档", attribute: "\\Archive"),
            ])
            await scriptSelect(transport, number: 5, uidValidity: 42, uidNext: 9)
            await transport.enqueue("* SEARCH 77")
            await transport.enqueue("A0006 OK SEARCH completed")
            await transport.enqueue("A0007 OK MOVE completed")

            try await provider.unarchive(remoteId: "<m7@qq.com>")

            let lines = await wire(transport)
            XCTAssertTrue(
                lines.contains(#"A0006 UID SEARCH HEADER Message-ID "<m7@qq.com>""#)
            )
            XCTAssertEqual(lines.last, #"A0007 UID MOVE 77 "INBOX""#)
        }
    }

    /// A server without MOVE (163 class) still archives: COPY, flag, EXPUNGE
    /// — the spec §4.3 fallback.
    func test_archive_withoutMoveCapability_copiesAndExpunges() async throws {
        try await TokenKeyFixture.withKeyAsync(Self.key) {
            let transport = ScriptedTransport()
            let (provider, _) = try makeProvider(transport: transport)
            await scriptHandshake(transport, capabilities: "IMAP4rev1 ID IDLE AUTH=PLAIN")
            await scriptList(transport, number: 4, mailboxes: [
                (name: "INBOX", attribute: nil),
                (name: "Archive", attribute: "\\Archive"),
            ])
            await scriptSelect(transport, number: 5, uidValidity: 42, uidNext: 9)
            await transport.enqueue("A0006 OK COPY completed")
            await transport.enqueue("A0007 OK STORE completed")
            await transport.enqueue("A0008 OK EXPUNGE completed")

            try await provider.archive(remoteId: "7")

            let lines = await wire(transport)
            XCTAssertEqual(Array(lines.suffix(3)), [
                #"A0006 UID COPY 7 "Archive""#,
                #"A0007 UID STORE 7 +FLAGS (\Deleted)"#,
                "A0008 EXPUNGE",
            ])
        }
    }

    func test_setRead_storesSeenFlag() async throws {
        try await TokenKeyFixture.withKeyAsync(Self.key) {
            let transport = ScriptedTransport()
            let (provider, _) = try makeProvider(transport: transport)
            await scriptHandshake(transport)
            await scriptSelect(transport, number: 4, uidValidity: 42, uidNext: 9)
            await transport.enqueue("A0005 OK STORE completed")

            try await provider.setRead(remoteId: "7", isRead: true)

            let lines = await wire(transport)
            XCTAssertEqual(lines.last, #"A0005 UID STORE 7 +FLAGS (\Seen)"#)
        }
    }

    // MARK: - body

    func test_fetchBody_parsesMimeToPlainText() async throws {
        try await TokenKeyFixture.withKeyAsync(Self.key) {
            let transport = ScriptedTransport()
            let (provider, _) = try makeProvider(transport: transport)
            await scriptHandshake(transport)
            await scriptSelect(transport, number: 4, uidValidity: 42, uidNext: 9)
            let raw = Data(
                "Subject: hi\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n纯文本版本\r\n".utf8
            )
            await transport.enqueue(#"* 1 FETCH (UID 7 BODY[] {\#(raw.count)}"#)
            await transport.enqueueLiteral(raw)
            await transport.enqueue(")")
            await transport.enqueue("A0005 OK FETCH completed")

            let text = try await provider.fetchBody(remoteId: "7").text

            XCTAssertEqual(text, "纯文本版本")
        }
    }

    /// An empty `BODY[]` means the UID was expunged: 410 territory (spec §3.7).
    func test_fetchBody_expungedMessage_isMessageGone() async throws {
        try await TokenKeyFixture.withKeyAsync(Self.key) {
            let transport = ScriptedTransport()
            let (provider, _) = try makeProvider(transport: transport)
            await scriptHandshake(transport)
            await scriptSelect(transport, number: 4, uidValidity: 42, uidNext: 9)
            await transport.enqueue("A0005 OK FETCH completed")

            let thrown = await XCTAssertThrowsErrorAsync {
                _ = try await provider.fetchBody(remoteId: "7")
            }

            XCTAssertEqual(thrown as? MailError, .messageGone)
        }
    }

    /// List-Unsubscribe at click time comes from the wire, not the store.
    func test_fetchRawHeaderValues_readsTheHeaderBlock() async throws {
        try await TokenKeyFixture.withKeyAsync(Self.key) {
            let transport = ScriptedTransport()
            let (provider, _) = try makeProvider(transport: transport)
            await scriptHandshake(transport)
            await scriptSelect(transport, number: 4, uidValidity: 42, uidNext: 9)
            await scriptHeaderFetch(transport, sequence: 1, uid: 7, flags: "", headers: [
                ("From", "news@qq.com"),
                ("List-Unsubscribe", "<mailto:u@qq.com>"),
            ])
            await transport.enqueue("A0005 OK FETCH completed")

            let values = try await provider.fetchRawHeaderValues(remoteId: "7")

            XCTAssertEqual(values["list-unsubscribe"], "<mailto:u@qq.com>")
        }
    }

    // MARK: - snippets

    /// A multipart/alternative message whose base64 text part is cut in the
    /// middle: the window ends inside the base64 payload, and the bytes that
    /// did arrive must still decode to readable prose. This is the shape that
    /// produced empty previews on the real mailbox.
    func test_snippet_multipartBase64TruncatedMidStream_returnsReadablePrefix() async throws {
        try await TokenKeyFixture.withKeyAsync(Self.key) {
            let plain = String(
                repeating: "这是一封测试邮件的正文内容，用于验证列表预览解码。",
                count: 10
            )
            let base64 = Data(plain.utf8).base64EncodedString()
            let full = "Content-Type: multipart/alternative; boundary=\"b\"\r\n"
                + "\r\n"
                + "--b\r\n"
                + "Content-Type: text/plain; charset=UTF-8\r\n"
                + "Content-Transfer-Encoding: base64\r\n"
                + "\r\n"
                + base64
                + "\r\n--b--\r\n"
            // The header block ends around byte 137, so byte 300 lands well
            // inside the base64 and never reaches the closing delimiter.
            let cut = Data(full.utf8).prefix(300)
            let window = String(decoding: cut, as: UTF8.self)

            let snippet = try await pulledSnippet(window)

            let unwrapped = try XCTUnwrap(snippet)
            XCTAssertTrue(
                unwrapped.hasPrefix("这是一封测试邮件的正文内容"),
                "the decoded head of the base64 part is readable, got: \(unwrapped)"
            )
            XCTAssertFalse(unwrapped.contains("6L+Z"), "raw base64 must not survive as the snippet")
        }
    }

    /// HTML-only mail: the snippet is the tag-stripped prose, not markup.
    func test_snippet_htmlOnly_returnsStrippedText() async throws {
        try await TokenKeyFixture.withKeyAsync(Self.key) {
            let snippet = try await pulledSnippet(
                "Content-Type: text/html; charset=UTF-8\r\n\r\n"
                    + "<html><body><p>只有 HTML 的正文</p><p>第二段</p></body></html>"
            )

            XCTAssertEqual(snippet, "只有 HTML 的正文 第二段")
            XCTAssertFalse(snippet?.contains("<p>") ?? false, "markup is stripped")
        }
    }

    /// An attachment-only message has no preview text: the fallback still
    /// returns nil rather than dumping PDF bytes into the list.
    func test_snippet_attachmentOnly_returnsNil() async throws {
        try await TokenKeyFixture.withKeyAsync(Self.key) {
            let snippet = try await pulledSnippet(
                "Content-Type: application/pdf\r\n"
                    + "Content-Disposition: attachment; filename=\"a.pdf\"\r\n"
                    + "\r\nJVBERi0xLjQK"
            )

            XCTAssertNil(snippet, "an attachment carries no preview text")
        }
    }

    /// The ordinary case: a plain text body is the snippet.
    func test_snippet_plainText_returnsBody() async throws {
        try await TokenKeyFixture.withKeyAsync(Self.key) {
            let snippet = try await pulledSnippet(
                "Content-Type: text/plain; charset=UTF-8\r\n\r\n普通纯文本正文"
            )

            XCTAssertEqual(snippet, "普通纯文本正文")
        }
    }

    /// The list renders one line: the body's newlines and runs of whitespace
    /// collapse to single spaces before the 200-character cut.
    func test_snippet_collapsesWhitespaceToASingleLine() async throws {
        try await TokenKeyFixture.withKeyAsync(Self.key) {
            let snippet = try await pulledSnippet(
                "Content-Type: text/plain; charset=UTF-8\r\n\r\n"
                    + "第一行\r\n\r\n第二行\t\t多个   空格"
            )

            XCTAssertEqual(snippet, "第一行 第二行 多个 空格")
            XCTAssertFalse(snippet?.contains("\n") ?? true, "the list preview is one line")
        }
    }

    /// A folded (multi-line) base64 body the parser could not route — its
    /// `content-transfer-encoding` fell outside the window — must not leak
    /// into the list as prose. The guard has to run after whitespace folding
    /// and against the payload without the fold separators: the CRLF between
    /// base64 lines otherwise breaks the %4/alphabet test and the base64
    /// survives as a preview.
    func test_snippet_foldedBase64_doesNotLeakAsSnippet() async throws {
        try await TokenKeyFixture.withKeyAsync(Self.key) {
            // 120 bytes → base64 length 160 with no padding, so only the
            // payload shape can identify it.
            let raw = Data((0..<120).map { UInt8($0 % 251 + 1) })
            let base64 = raw.base64EncodedString()
            XCTAssertFalse(base64.hasSuffix("="), "the fixture must be caught by shape, not padding")
            var folded = ""
            var index = base64.startIndex
            while index < base64.endIndex {
                let end = base64.index(index, offsetBy: 76, limitedBy: base64.endIndex) ?? base64.endIndex
                folded += base64[index..<end]
                if end < base64.endIndex { folded += "\r\n" }
                index = end
            }
            XCTAssertTrue(folded.contains("\r\n"), "the fixture must actually be folded")

            let snippet = try await pulledSnippet(
                "Content-Type: text/plain; charset=UTF-8\r\n\r\n" + folded
            )

            XCTAssertNil(snippet, "folded base64 must not be shown as a preview")
        }
    }

    /// A body the parser could not route as multipart still starts with its
    /// `--boundary`; that structural text must never be shown.
    func test_snippet_unroutedBoundary_returnsNil() async throws {
        try await TokenKeyFixture.withKeyAsync(Self.key) {
            let snippet = try await pulledSnippet(
                "Content-Type: text/plain; charset=UTF-8\r\n\r\n"
                    + "--boundary\r\nContent-Type: text/plain\r\n\r\n部分正文"
            )

            XCTAssertNil(snippet, "an unrouted boundary is structure, not prose")
        }
    }

    // MARK: - connection lifecycle

    /// A dropped connection is rebuilt on the next call, and the fresh session
    /// runs the full handshake again.
    func test_pullChanges_afterDroppedConnection_reconnects() async throws {
        try await TokenKeyFixture.withKeyAsync(Self.key) {
            let transport = ScriptedTransport()
            let (provider, _) = try makeProvider(transport: transport)
            await scriptHandshake(transport)
            await scriptList(transport, number: 4, mailboxes: [
                (name: "INBOX", attribute: nil),
                (name: "Archive", attribute: "\\Archive"),
            ])
            await scriptSelect(transport, number: 5, uidValidity: 42, uidNext: 1)
            await transport.enqueue("A0006 OK FETCH completed")
            _ = try await provider.pullChanges(after: MailSyncState(), waitUpTo: .zero)

            // The socket dies mid-command: reads past the script throw `.closed`.
            let thrown = await XCTAssertThrowsErrorAsync {
                _ = try await provider.pullChanges(
                    after: MailSyncState(uidValidity: 42, lastUid: 0),
                    waitUpTo: .zero
                )
            }
            XCTAssertNotNil(thrown, "a dead socket must surface, not be swallowed")

            // A new session starts over: A0001 is issued a second time.
            // Capabilities are per-account, so they stay cached — no second LIST.
            await scriptHandshake(transport)
            await scriptSelect(transport, number: 4, uidValidity: 42, uidNext: 1)
            await scriptHeaderFetch(transport, sequence: 1, uid: 1, flags: "", headers: [
                ("From", "zhangsan@qq.com"),
                ("Subject", "reconnected"),
            ])
            await transport.enqueue("A0005 OK FETCH completed")
            await scriptSnippet(
                transport, sequence: 1, uid: 1,
                message: "Content-Type: text/plain; charset=UTF-8\r\n\r\nhello"
            )
            await transport.enqueue("A0006 OK FETCH completed")

            let change = try await provider.pullChanges(
                after: MailSyncState(uidValidity: 42),
                waitUpTo: .zero
            )
            XCTAssertEqual(change.cursor.lastUid, 1)
            let lines = await wire(transport)
            XCTAssertEqual(
                lines.filter { $0.hasPrefix("A0001 ") }.count, 2,
                "the second session re-authenticates from scratch"
            )
        }
    }

    /// With IDLE the wait is a push: the round after the event reports the new
    /// mail, and no polling happens in between (spec §3.3).
    func test_pullChanges_withIdle_waitsForPushThenReports() async throws {
        try await TokenKeyFixture.withKeyAsync(Self.key) {
            let transport = ScriptedTransport()
            let (provider, _) = try makeProvider(transport: transport)
            await scriptHandshake(transport)
            await scriptList(transport, number: 4, mailboxes: [
                (name: "INBOX", attribute: nil),
                (name: "Archive", attribute: "\\Archive"),
            ])
            await scriptSelect(transport, number: 5, uidValidity: 42, uidNext: 1)
            await transport.enqueue("A0006 OK FETCH completed")
            await transport.enqueue("+ idling")
            await transport.enqueue("* 1 EXISTS")
            await transport.enqueue("A0007 OK IDLE completed")
            await scriptSelect(transport, number: 8, uidValidity: 42, uidNext: 2)
            await scriptHeaderFetch(transport, sequence: 1, uid: 1, flags: "", headers: [
                ("From", "zhangsan@qq.com"),
                ("Subject", "pushed"),
            ])
            await transport.enqueue("A0009 OK FETCH completed")
            await scriptSnippet(
                transport, sequence: 1, uid: 1,
                message: "Content-Type: text/plain; charset=UTF-8\r\n\r\nhi"
            )
            await transport.enqueue("A0010 OK FETCH completed")

            let change = try await provider.pullChanges(
                after: MailSyncState(uidValidity: 42),
                waitUpTo: .milliseconds(200)
            )

            XCTAssertEqual(change.upserts.count, 1)
            XCTAssertEqual(change.cursor.lastUid, 1)
            let lines = await wire(transport)
            XCTAssertTrue(
                lines.contains { $0.hasSuffix(" IDLE") },
                "the wait is a push, not a poll"
            )
            XCTAssertEqual(
                lines.filter { $0.contains("SELECT") }.count, 2,
                "one SELECT per round, not per poll interval"
            )
        }
    }

    /// Without IDLE the provider polls on an interval instead of issuing IDLE.
    func test_pullChanges_withoutIdle_polls() async throws {
        try await TokenKeyFixture.withKeyAsync(Self.key) {
            let transport = ScriptedTransport()
            let (provider, _) = try makeProvider(transport: transport)
            await scriptHandshake(transport, capabilities: "IMAP4rev1 MOVE AUTH=PLAIN")
            await scriptList(transport, number: 4, mailboxes: [
                (name: "INBOX", attribute: nil),
                (name: "Archive", attribute: "\\Archive"),
            ])
            for number in [5, 7, 9] {
                await scriptSelect(transport, number: number, uidValidity: 42, uidNext: 1)
                await transport.enqueue("\(tag(number + 1)) OK FETCH completed")
            }

            let change = try await provider.pullChanges(
                after: MailSyncState(uidValidity: 42, lastUid: 0),
                waitUpTo: .milliseconds(60)
            )

            XCTAssertTrue(change.upserts.isEmpty)
            let lines = await wire(transport)
            XCTAssertFalse(lines.contains { $0.hasSuffix(" IDLE") }, "no IDLE on a server without it")
            XCTAssertGreaterThanOrEqual(
                lines.filter { $0.contains("SELECT") }.count, 2,
                "the wait is spent polling, not returning early"
            )
        }
    }
}
