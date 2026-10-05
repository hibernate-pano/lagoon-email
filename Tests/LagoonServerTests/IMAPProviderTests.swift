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
        reconcilesInbox: Bool = false,
        logger: Logger = Logger(label: "imap-provider-tests")
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
            logger: logger,
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
            // 600 messages, UIDNEXT 1000: a sparse UID space on purpose. The
            // window is the newest `backfillWindow` *messages*, so it starts at
            // sequence 101 — not at UID 500, which is what measuring the same
            // window in UID slots produced.
            await scriptSelect(transport, number: 5, exists: 600, uidValidity: 42, uidNext: 1000)
            await scriptHeaderFetch(transport, sequence: 101, uid: 900, flags: "\\Seen", headers: [
                ("From", "\"Zhang San\" <zhangsan@qq.com>"),
                ("Subject", "=?UTF-8?B?5rWL6K+V?="),
                ("Message-ID", "<m900@qq.com>"),
                ("References", "<root@qq.com> <parent@qq.com>"),
            ])
            await scriptHeaderFetch(transport, sequence: 102, uid: 901, flags: "", headers: [
                ("From", "lisi@qq.com"),
                ("Subject", "第二封"),
            ])
            await transport.enqueue("A0006 OK FETCH completed")
            // One range snippet command for the whole window (both untagged
            // FETCH blocks answer A0007): a backfill must not pay one round
            // trip per message.
            await scriptSnippet(
                transport, sequence: 101, uid: 900,
                message: "Content-Type: text/plain; charset=UTF-8\r\n\r\nHello from QQ"
            )
            await scriptSnippet(
                transport, sequence: 102, uid: 901,
                message: "Content-Type: text/plain; charset=UTF-8\r\n"
                    + "Content-Transfer-Encoding: base64\r\n\r\nSGVsbG8gd29ybGQhIHN0dWZm"
            )
            await transport.enqueue("A0007 OK FETCH completed")

            let change = try await provider.pullChanges(after: MailSyncState(), waitUpTo: .zero)

            let lines = await wire(transport)
            XCTAssertTrue(
                lines.contains(
                    "A0006 FETCH 101:* (UID FLAGS INTERNALDATE BODY.PEEK[HEADER.FIELDS (\(headerFields))])"
                ),
                "the first pull asks for the newest N messages by sequence, never a UID range"
            )
            XCTAssertEqual(change.upserts.count, 2)
            XCTAssertEqual(change.cursor.lastUid, 901)
            XCTAssertEqual(change.cursor.uidValidity, 42)
            XCTAssertEqual(
                change.cursor.historyFloorUid, 900,
                "the round records how far back it reached, or the gap is never revisited"
            )
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
    /// of INBOX from the authoritative set returned to the store. It runs once
    /// the cursor carries a UID — the first-ever sync skips it, because an
    /// empty store has nothing to reconcile.
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

            // A floor in the cursor means the history window already ran, so
            // this round takes the forward path — which is what reconciliation
            // is written against.
            let change = try await provider.pullChanges(
                after: MailSyncState(uidValidity: 42, lastUid: 0, historyFloorUid: 1),
                waitUpTo: .zero
            )

            XCTAssertEqual(change.inboxRemoteIds, Set(["<m1@qq.com>"]))
            let lines = await wire(transport)
            XCTAssertTrue(lines.contains("A0006 UID FETCH 1:* (UID FLAGS INTERNALDATE BODY.PEEK[HEADER.FIELDS (\(headerFields))])"))
            XCTAssertTrue(lines.contains("A0007 UID SEARCH ALL"))
            XCTAssertTrue(lines.contains("A0008 UID FETCH 1:* (UID FLAGS INTERNALDATE BODY.PEEK[HEADER.FIELDS (\(headerFields))])"))
        }
    }

    /// The very first sync (no cursor UID yet — nothing in the store to
    /// reconcile against) must not pay for the membership reconcile: no
    /// identity fetch, no `UID SEARCH ALL`, and no reconciliation set.
    func test_pullChanges_firstSync_skipsMembershipReconcile() async throws {
        try await TokenKeyFixture.withKeyAsync(Self.key) {
            let transport = ScriptedTransport()
            let (provider, _) = try makeProvider(transport: transport, reconcilesInbox: true)
            await scriptHandshake(transport)
            await scriptList(transport, number: 4, mailboxes: [
                (name: "INBOX", attribute: nil),
                (name: "Archive", attribute: "\\Archive"),
            ])
            await scriptSelect(transport, number: 5, uidValidity: 42, uidNext: 1)
            await transport.enqueue("A0006 OK FETCH completed")

            let change = try await provider.pullChanges(
                after: MailSyncState(),
                waitUpTo: .zero
            )

            XCTAssertNil(change.inboxRemoteIds)
            XCTAssertFalse(change.resetRequired)
            let lines = await wire(transport)
            XCTAssertFalse(
                lines.contains("UID SEARCH ALL"),
                "an empty store has nothing to reconcile, so the SEARCH is pure latency"
            )
            XCTAssertEqual(lines.filter { $0.contains("BODY.PEEK[HEADER.FIELDS") }.count, 1,
                           "only the window fetch, no full-identity fetch")
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

    /// The Sent folder was rebuilt: its UIDVALIDITY moved (7 → 9) and every
    /// UID in the old space is dead. The stored sent cursor belongs to the dead
    /// space, so the round must NOT keep it as the high-water mark — a stale
    /// `sentLastUid` (5000) is larger than the new folder's whole range, so
    /// every later round would short-circuit on `baseUid >= uidNext` and
    /// cross-client reply detection would stop silently, forever.
    func test_pullChanges_sentUidValidityChange_resetsTheSentCursor() async throws {
        try await TokenKeyFixture.withKeyAsync(Self.key) {
            let transport = ScriptedTransport()
            let (provider, _) = try makeProvider(transport: transport)
            await scriptHandshake(transport)
            await scriptList(transport, number: 4, mailboxes: [
                (name: "INBOX", attribute: nil),
                (name: "Archive", attribute: "\\Archive"),
                (name: "Sent", attribute: "\\Sent"),
            ])
            // No new inbox mail; the \Seen rescan reports nothing new.
            await scriptSelect(transport, number: 5, uidValidity: 42, uidNext: 901)
            await transport.enqueue("A0006 OK FETCH completed")
            await transport.enqueue(#"* 1 FETCH (UID 900 FLAGS (\Seen))"#)
            await transport.enqueue("A0007 OK FETCH completed")
            // Rebuilt Sent folder: brand-new UIDVALIDITY, a small range.
            await scriptSelect(transport, number: 8, exists: 2, uidValidity: 9, uidNext: 11)
            await scriptHeaderFetch(transport, sequence: 1, uid: 1, flags: "\\Seen", headers: [
                ("From", "user@qq.com"),
                ("Message-ID", "<sent1@qq.com>"),
            ])
            await scriptHeaderFetch(transport, sequence: 2, uid: 10, flags: "\\Seen", headers: [
                ("From", "user@qq.com"),
                ("Message-ID", "<sent10@qq.com>"),
            ])
            await transport.enqueue("A0009 OK FETCH completed")

            let cursor = MailSyncState(
                uidValidity: 42,
                lastUid: 900,
                archiveFolder: "Archive",
                sentUidValidity: 7,
                sentLastUid: 5000,
                sentFolder: "Sent"
            )
            let change = try await provider.pullChanges(after: cursor, waitUpTo: .zero)

            XCTAssertEqual(change.cursor.sentUidValidity, 9)
            XCTAssertEqual(
                change.cursor.sentLastUid, 10,
                "a UIDVALIDITY change must rebase the sent cursor, not carry the dead one forward"
            )

            // The round after that must still scan Sent: the cursor now resumes
            // from 10, so a reply arriving in the new folder is harvested.
            await scriptSelect(transport, number: 10, uidValidity: 42, uidNext: 901)
            await transport.enqueue("A0011 OK FETCH completed")
            await transport.enqueue(#"* 1 FETCH (UID 900 FLAGS (\Seen))"#)
            await transport.enqueue("A0012 OK FETCH completed")
            await scriptSelect(transport, number: 13, exists: 3, uidValidity: 9, uidNext: 12)
            await scriptHeaderFetch(transport, sequence: 3, uid: 11, flags: "\\Seen", headers: [
                ("From", "user@qq.com"),
                ("Message-ID", "<reply11@qq.com>"),
                ("In-Reply-To", "<m900@qq.com>"),
            ])
            await transport.enqueue("A0014 OK FETCH completed")

            let second = try await provider.pullChanges(after: change.cursor, waitUpTo: .zero)

            XCTAssertEqual(
                second.repliedMessageIds, ["<m900@qq.com>"],
                "reply detection must survive a Sent-folder rebuild"
            )
            XCTAssertEqual(second.cursor.sentLastUid, 11)
            let lines = await wire(transport)
            XCTAssertTrue(
                lines.contains(
                    "A0014 UID FETCH 11:* (UID FLAGS INTERNALDATE BODY.PEEK[HEADER.FIELDS (\(headerFields))])"
                ),
                "the next round resumes from the new cursor instead of short-circuiting"
            )
        }
    }

    /// Same rebuild, but the new Sent folder is empty. The harvest returns
    /// before it FETCHes anything, so this early return must drop the dead
    /// cursor too — otherwise it is persisted verbatim and the next round
    /// short-circuits on a UID that the empty folder will never have.
    func test_pullChanges_sentUidValidityChange_onEmptySent_dropsTheDeadCursor() async throws {
        try await TokenKeyFixture.withKeyAsync(Self.key) {
            let transport = ScriptedTransport()
            let (provider, _) = try makeProvider(transport: transport)
            await scriptHandshake(transport)
            await scriptList(transport, number: 4, mailboxes: [
                (name: "INBOX", attribute: nil),
                (name: "Archive", attribute: "\\Archive"),
                (name: "Sent", attribute: "\\Sent"),
            ])
            await scriptSelect(transport, number: 5, uidValidity: 42, uidNext: 901)
            await transport.enqueue("A0006 OK FETCH completed")
            await transport.enqueue(#"* 1 FETCH (UID 900 FLAGS (\Seen))"#)
            await transport.enqueue("A0007 OK FETCH completed")
            await scriptSelect(transport, number: 8, exists: 0, uidValidity: 9, uidNext: 1)

            let change = try await provider.pullChanges(
                after: MailSyncState(
                    uidValidity: 42,
                    lastUid: 900,
                    archiveFolder: "Archive",
                    sentUidValidity: 7,
                    sentLastUid: 5000,
                    sentFolder: "Sent"
                ),
                waitUpTo: .zero
            )

            XCTAssertEqual(change.cursor.sentUidValidity, 9)
            XCTAssertNil(
                change.cursor.sentLastUid,
                "an empty rebuilt Sent folder must not carry the dead cursor forward"
            )
        }
    }

    /// A snippet batch that the server refuses must cost only its own chunk:
    /// the previews already fetched for the earlier chunks still reach the
    /// store, and the refusal is recorded. Losing the whole window silently is
    /// unrecoverable — the cursor advances past those messages, so they are
    /// never re-fetched.
    func test_pullChanges_refusedSnippetChunk_keepsThePreviewsOfEarlierChunks() async throws {
        try await TokenKeyFixture.withKeyAsync(Self.key) {
            let transport = ScriptedTransport()
            let (logger, log) = Logger.recording(label: "imap-provider-tests")
            let (provider, _) = try makeProvider(transport: transport, logger: logger)
            await scriptHandshake(transport)
            await scriptList(transport, number: 4, mailboxes: [
                (name: "INBOX", attribute: nil),
                (name: "Archive", attribute: "\\Archive"),
            ])
            await scriptSelect(transport, number: 5, uidValidity: 42, uidNext: 200)
            // 101 messages: the preview FETCH chunks at 100 UIDs per command.
            for uid in 1...101 {
                await scriptHeaderFetch(transport, sequence: uid, uid: Int64(uid), flags: "", headers: [
                    ("From", "zhangsan@qq.com"),
                    ("Message-ID", "<m\(uid)@qq.com>"),
                ])
            }
            await transport.enqueue("A0006 OK FETCH completed")
            // Chunk one answers with previews…
            await scriptSnippet(
                transport, sequence: 1, uid: 1,
                message: "Content-Type: text/plain; charset=UTF-8\r\n\r\npreview one"
            )
            await scriptSnippet(
                transport, sequence: 2, uid: 2,
                message: "Content-Type: text/plain; charset=UTF-8\r\n\r\npreview two"
            )
            await transport.enqueue("A0007 OK FETCH completed")
            // …chunk two is refused.
            await transport.enqueue("A0008 NO FETCH failed")

            let change = try await provider.pullChanges(after: MailSyncState(), waitUpTo: .zero)

            XCTAssertEqual(change.upserts.count, 101, "no message may be lost with the refused chunk")
            XCTAssertEqual(change.upserts.first?.snippet, "preview one")
            XCTAssertEqual(change.upserts[1].snippet, "preview two")
            XCTAssertNil(
                change.upserts.last?.snippet,
                "the refused chunk yields no preview, but the round completes"
            )
            let lines = await wire(transport)
            XCTAssertEqual(
                lines.filter { $0.contains("UID FETCH") && $0.contains("BODY.PEEK[]") }.count, 2,
                "the window is fetched in chunks of at most 100 UIDs"
            )
            XCTAssertTrue(
                log.messages.contains("imap.snippetChunkSkipped"),
                "a refused chunk must be recorded, not swallowed: \(log.messages)"
            )
        }
    }

    /// The preview fetch is batched, and the batching is the whole reason the
    /// strictly serial session can backfill at all: a full window
    /// (`IMAPProvider.backfillWindow` = 500) costs 5 commands of 100 UIDs, not
    /// 500 round trips. `IMAPClient.snippetOctets` is documented against this
    /// number, so it is pinned here rather than left to a comment.
    func test_pullChanges_backfillWindow_previewsCostFiveBatchedCommands() async throws {
        try await TokenKeyFixture.withKeyAsync(Self.key) {
            let transport = ScriptedTransport()
            let (provider, _) = try makeProvider(transport: transport)
            await scriptHandshake(transport)
            await scriptList(transport, number: 4, mailboxes: [
                (name: "INBOX", attribute: nil),
                (name: "Archive", attribute: "\\Archive"),
            ])
            // UIDNEXT 1000 → the first pull's window is UID 500..999.
            await scriptSelect(transport, number: 5, uidValidity: 42, uidNext: 1000)
            for uid in 500...999 {
                await scriptHeaderFetch(transport, sequence: uid - 499, uid: Int64(uid), flags: "", headers: [
                    ("From", "zhangsan@qq.com"),
                    ("Message-ID", "<m\(uid)@qq.com>"),
                ])
            }
            await transport.enqueue("A0006 OK FETCH completed")
            for chunk in 0..<5 {
                for index in 0..<100 {
                    await scriptSnippet(
                        transport, sequence: index + 1, uid: Int64(500 + chunk * 100 + index),
                        message: "Content-Type: text/plain; charset=UTF-8\r\n\r\nbody"
                    )
                }
                await transport.enqueue("\(tag(7 + chunk)) OK FETCH completed")
            }

            let change = try await provider.pullChanges(after: MailSyncState(), waitUpTo: .zero)

            XCTAssertEqual(change.upserts.count, 500)
            XCTAssertTrue(change.upserts.allSatisfy { $0.snippet == "body" })
            let lines = await wire(transport)
            let previewCommands = lines.filter {
                $0.contains("UID FETCH") && $0.contains("BODY.PEEK[]<0.32768>")
            }
            XCTAssertEqual(previewCommands.count, 5, "500 UIDs at 100 per command")
            for command in previewCommands {
                let set = command
                    .replacingOccurrences(of: " (UID BODY.PEEK[]<0.32768>)", with: "")
                    .split(separator: " ").last ?? ""
                XCTAssertEqual(set.split(separator: ",").count, 100, "no command may exceed the batch")
            }
        }
    }

    /// Best-effort means "the session survives", not "the failure is invisible".
    /// When the Sent scan loses the socket, the round must tear the session
    /// down instead of handing the next command a connection whose read
    /// stream is no longer trustworthy.
    func test_pullChanges_sentScanTransportFailure_dropsTheSession() async throws {
        try await TokenKeyFixture.withKeyAsync(Self.key) {
            let transport = ScriptedTransport()
            let (provider, _) = try makeProvider(transport: transport)
            await scriptHandshake(transport)
            await scriptList(transport, number: 4, mailboxes: [
                (name: "INBOX", attribute: nil),
                (name: "Archive", attribute: "\\Archive"),
                (name: "Sent", attribute: "\\Sent"),
            ])
            await scriptSelect(transport, number: 5, uidValidity: 42, uidNext: 1)
            await transport.enqueue("A0006 OK FETCH completed")
            // The Sent SELECT answers; the FETCH behind it hits a dead socket.
            await scriptSelect(transport, number: 7, exists: 1, uidValidity: 7, uidNext: 52)
            await transport.failNextRead(with: StreamTransportError.timedOut)

            let change = try await provider.pullChanges(
                after: MailSyncState(uidValidity: 42),
                waitUpTo: .zero
            )

            XCTAssertTrue(change.repliedMessageIds.isEmpty, "no reply signal without the scan")
            let closes = await transport.closeCount
            XCTAssertGreaterThan(
                closes, 0,
                "a Sent scan that failed on the socket must not leave the session in place"
            )
        }
    }

    /// A transport failure while CREATE-ing the archive folder is not the
    /// server refusing. Latching "this server has no archive folder" from a
    /// socket blip permanently disables remote archiving for this provider
    /// instance — the folder may well have been created moments later.
    func test_pullChanges_archiveCreateTransportFailure_isNotLatched() async throws {
        try await TokenKeyFixture.withKeyAsync(Self.key) {
            let transport = ScriptedTransport()
            let (provider, _) = try makeProvider(transport: transport)
            // Round one: no \Archive and no name match → CREATE, which dies on
            // the socket exactly the way the real transport reports a read
            // failure (a MailError, not a tagged NO).
            await scriptHandshake(transport)
            await scriptList(transport, number: 4, mailboxes: [(name: "INBOX", attribute: nil)])
            await transport.failNextRead(with: MailError.unreachable("read"))
            let thrown = await XCTAssertThrowsErrorAsync {
                try await provider.pullChanges(after: MailSyncState(), waitUpTo: .zero)
            }
            XCTAssertEqual(
                thrown as? MailError, .unreachable("read"),
                "a dead socket surfaces as unreachable, not as a successful round"
            )

            // Round two reconnects and must try the CREATE again.
            await scriptHandshake(transport)
            await scriptList(transport, number: 4, mailboxes: [(name: "INBOX", attribute: nil)])
            await transport.enqueue(#"A0005 OK CREATE completed"#)
            await scriptSelect(transport, number: 6, uidValidity: 42, uidNext: 1)
            await transport.enqueue("A0007 OK FETCH completed")

            let change = try await provider.pullChanges(after: MailSyncState(), waitUpTo: .zero)

            XCTAssertEqual(change.cursor.archiveFolder, "Archive")
            let lines = await wire(transport)
            XCTAssertEqual(
                lines.filter { $0.contains("CREATE") }.count, 2,
                "a blip must not latch the folder as unavailable: \(lines)"
            )
        }
    }

    /// The server greets and then goes silent: the socket is already the
    /// reason this connect failed, so writing a LOGOUT into it would spend the
    /// whole read timeout (30 s, under `commandLock`) waiting for a reply that
    /// cannot come.
    func test_probe_silentServer_closesWithoutWaitingForLogout() async throws {
        try await TokenKeyFixture.withKeyAsync(Self.key) {
            let transport = ScriptedTransport()
            let (provider, _) = try makeProvider(transport: transport)
            await transport.enqueue("* OK Lagoon ready")
            await transport.enqueue("\(tag(1)) OK AUTHENTICATE completed")
            await transport.failNextRead(with: StreamTransportError.timedOut)

            let thrown = await XCTAssertThrowsErrorAsync { try await provider.probe() }

            XCTAssertEqual(thrown as? MailError, .unreachable("imap transport"))
            let lines = await wire(transport)
            XCTAssertFalse(
                lines.contains { $0.contains("LOGOUT") },
                "a session that failed on the socket is closed, not politely logged out: \(lines)"
            )
            let closes = await transport.closeCount
            XCTAssertGreaterThan(closes, 0, "the socket must be handed back either way")
        }
    }

    /// The session belongs to the provider, so the provider has to be able to
    /// hand it back. A dropped `IMAPProvider` cannot: the read pump under the
    /// TLS transport keeps the socket authenticated on QQ's side, and QQ caps
    /// concurrent IMAP sessions per account.
    func test_shutdown_closesTheSession() async throws {
        try await TokenKeyFixture.withKeyAsync(Self.key) {
            let transport = ScriptedTransport()
            let (provider, _) = try makeProvider(transport: transport)
            await scriptHandshake(transport)
            await scriptList(transport, number: 4, mailboxes: [
                (name: "INBOX", attribute: nil),
                (name: "Archive", attribute: "\\Archive"),
            ])
            await scriptSelect(transport, number: 5, uidValidity: 42, uidNext: 1)

            try await provider.probe()
            let before = await transport.closeCount
            XCTAssertEqual(before, 0, "a live provider holds its session")

            await provider.shutdown()

            let after = await transport.closeCount
            XCTAssertGreaterThan(after, before, "shutdown() must close the session")
        }
    }

    /// The mirror image: the server is still talking and refused a command, so
    /// the session ends the way RFC 3501 intends — with a LOGOUT.
    func test_probe_refusedCommand_stillLogsOut() async throws {
        try await TokenKeyFixture.withKeyAsync(Self.key) {
            let transport = ScriptedTransport()
            let (provider, _) = try makeProvider(transport: transport)
            await transport.enqueue("* OK Lagoon ready")
            await transport.enqueue("\(tag(1)) OK AUTHENTICATE completed")
            await transport.enqueue("\(tag(2)) NO CAPABILITY failed")

            let thrown = await XCTAssertThrowsErrorAsync { try await provider.probe() }

            XCTAssertEqual(thrown as? MailError, .protocolError("tagged NO"))
            let lines = await wire(transport)
            XCTAssertTrue(
                lines.contains("\(tag(3)) LOGOUT"),
                "a live session that refused a command is still logged out: \(lines)"
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
                after: MailSyncState(uidValidity: 7, lastUid: 5, historyFloorUid: 5),
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

    /// The 2026-10-04 incident, pinned as a wire assertion.
    ///
    /// A real QQ mailbox: 265 messages, `UIDNEXT` 13734 — a UID space that is
    /// 98% holes, because IMAP burns a UID forever on every expunge, move and
    /// append. The window used to be `UID FETCH (uidNext - 500):*`, which on
    /// this mailbox reached the newest ~43 messages and left 222 unfetched
    /// forever, while the cursor parked at the top and health read `ok`. The
    /// user-visible symptom was "the client shows fewer messages than I have",
    /// which reads like a pagination bug and is not one: those rows were never
    /// on the machine.
    func test_pullChanges_sparseUidSpace_historyWindowIsAMessageCount() async throws {
        try await TokenKeyFixture.withKeyAsync(Self.key) {
            let transport = ScriptedTransport()
            let (provider, _) = try makeProvider(transport: transport)
            await scriptHandshake(transport)
            await scriptList(transport, number: 4, mailboxes: [
                (name: "INBOX", attribute: nil),
                (name: "Archive", attribute: "\\Archive"),
            ])
            await scriptSelect(transport, number: 5, exists: 265, uidValidity: 1384787035, uidNext: 13734)
            for (sequence, uid) in [(sequence: 1, uid: Int64(13700)), (2, 13720), (3, 13733)] {
                await scriptHeaderFetch(
                    transport, sequence: sequence, uid: uid, flags: "",
                    headers: [("Message-ID", "<m\(uid)@qq.com>")]
                )
            }
            await transport.enqueue("A0006 OK FETCH completed")
            for (sequence, uid) in [(sequence: 1, uid: Int64(13700)), (2, 13720), (3, 13733)] {
                await scriptSnippet(
                    transport, sequence: sequence, uid: uid,
                    message: "Content-Type: text/plain; charset=UTF-8\r\n\r\nbody"
                )
            }
            await transport.enqueue("A0007 OK FETCH completed")

            let change = try await provider.pullChanges(after: MailSyncState(), waitUpTo: .zero)

            XCTAssertEqual(change.upserts.count, 3, "every message in the mailbox, not only the newest UIDs")
            XCTAssertEqual(change.cursor.historyFloorUid, 13700)
            XCTAssertEqual(change.cursor.lastUid, 13733)

            let lines = await wire(transport)
            XCTAssertTrue(
                lines.contains { $0.hasPrefix("A0006 FETCH 1:* ") },
                "265 messages fit inside the window, so the fetch starts at sequence 1"
            )
            XCTAssertFalse(
                lines.contains { $0.contains("UID FETCH 13234:*") },
                "the window must not be expressed as UID slots behind UIDNEXT"
            )
            XCTAssertFalse(
                lines.contains { $0.contains("BODY.PEEK[HEADER.FIELDS") && $0.hasPrefix("A0006 UID") },
                "header fetches in a history round are sequence-addressed"
            )
        }
    }

    /// The upgrade path for an install that already synced under the old window.
    ///
    /// Its stored cursor has `lastUid` at the top of the mailbox and no
    /// `historyFloorUid`, because the field did not exist — that combination is
    /// the signature of a truncated history, and the next round must refill it
    /// without the user reconnecting. The round after that must go back to the
    /// cheap forward path instead of re-reading the whole window forever.
    func test_pullChanges_legacyCursorWithoutFloor_refillsHistoryThenGoesForward() async throws {
        try await TokenKeyFixture.withKeyAsync(Self.key) {
            let transport = ScriptedTransport()
            let (provider, _) = try makeProvider(transport: transport)
            await scriptHandshake(transport)
            await scriptList(transport, number: 4, mailboxes: [
                (name: "INBOX", attribute: nil),
                (name: "Archive", attribute: "\\Archive"),
            ])

            // Round 1: the stored cursor a pre-fix install left behind.
            await scriptSelect(transport, number: 5, exists: 265, uidValidity: 1384787035, uidNext: 13734)
            for (sequence, uid) in [(sequence: 1, uid: Int64(13700)), (2, 13720), (3, 13733)] {
                await scriptHeaderFetch(
                    transport, sequence: sequence, uid: uid, flags: "",
                    headers: [("Message-ID", "<m\(uid)@qq.com>")]
                )
            }
            await transport.enqueue("A0006 OK FETCH completed")
            for (sequence, uid) in [(sequence: 1, uid: Int64(13700)), (2, 13720), (3, 13733)] {
                await scriptSnippet(
                    transport, sequence: sequence, uid: uid,
                    message: "Content-Type: text/plain; charset=UTF-8\r\n\r\nbody"
                )
            }
            await transport.enqueue("A0007 OK FETCH completed")
            // `readStateFlips` runs because the legacy cursor has a `lastUid`.
            await transport.enqueue("A0008 OK FETCH completed")

            let legacy = MailSyncState(
                uidValidity: 1384787035,
                lastUid: 13733,
                archiveFolder: "Archive"
            )
            let refilled = try await provider.pullChanges(after: legacy, waitUpTo: .zero)

            XCTAssertEqual(refilled.upserts.count, 3, "the gap below the old cursor is fetched")
            XCTAssertEqual(refilled.cursor.historyFloorUid, 13700)
            XCTAssertEqual(refilled.cursor.lastUid, 13733, "refilling must not walk the cursor back")

            // Round 2: the same cursor, now carrying a floor. Nothing new.
            // No LIST here — the archive folder resolved in round 1 is cached,
            // so the sequence is SELECT, forward FETCH, flag rescan.
            await scriptSelect(transport, number: 9, exists: 265, uidValidity: 1384787035, uidNext: 13734)
            await transport.enqueue("A0010 OK FETCH completed")
            await transport.enqueue("A0011 OK FETCH completed")

            let forward = try await provider.pullChanges(after: refilled.cursor, waitUpTo: .zero)

            XCTAssertTrue(forward.upserts.isEmpty)
            let lines = await wire(transport)
            XCTAssertTrue(
                lines.contains("A0010 UID FETCH 13734:* (UID FLAGS INTERNALDATE BODY.PEEK[HEADER.FIELDS (\(headerFields))])"),
                "with a floor recorded, a steady round reads only above the high-water mark"
            )
            XCTAssertFalse(
                lines.contains { $0.hasPrefix("A0010 FETCH ") },
                "the history window must not re-run every round"
            )
        }
    }

    /// The empty-mailbox half of the history window. Two separate facts, both
    /// worth pinning because they are easy to conflate:
    ///
    /// * `exists = 0` records floor 0, not `uidNext`. Nothing was skipped, so
    ///   the cursor must not claim a boundary that does not exist — a floor
    ///   invented from `uidNext` would silently assert "we deliberately did not
    ///   fetch below UID 7" about a folder that was simply empty.
    /// * The forward start comes from `lastUid`, which is still nil here, so
    ///   the next round reads from UID 1 and the mailbox's first arrival is
    ///   picked up. This is deliberately *not* caused by the floor being 0 —
    ///   deriving the forward start from the floor instead would make an
    ///   empty new mailbox skip straight to `uidNext` and miss that arrival
    ///   forever, which is the shape of the bug this whole change fixes.
    func test_pullChanges_emptyMailbox_recordsFloorZeroAndSeesTheFirstArrival() async throws {
        try await TokenKeyFixture.withKeyAsync(Self.key) {
            let transport = ScriptedTransport()
            let (provider, _) = try makeProvider(transport: transport)
            await scriptHandshake(transport)
            await scriptList(transport, number: 4, mailboxes: [
                (name: "INBOX", attribute: nil),
                (name: "Archive", attribute: "\\Archive"),
            ])
            // Empty mailbox, but UIDNEXT already above 1 — exactly what a
            // freshly provisioned folder looks like.
            await scriptSelect(transport, number: 5, exists: 0, uidValidity: 42, uidNext: 7)
            // No FETCH completion is scripted here on purpose: an empty mailbox
            // issues no header command at all, and a stale tagged OK left in the
            // queue would be consumed by the *next* round's SELECT, silently
            // shifting every tag after it.

            let empty = try await provider.pullChanges(after: MailSyncState(), waitUpTo: .zero)

            XCTAssertTrue(empty.upserts.isEmpty)
            XCTAssertEqual(empty.cursor.historyFloorUid, 0, "an empty window skipped nothing, so the floor is 0")
            XCTAssertNil(empty.cursor.lastUid, "nothing arrived; the high-water mark stays unset")
            let lines = await wire(transport)
            XCTAssertFalse(
                lines.contains { $0.contains("BODY.PEEK[HEADER.FIELDS") },
                "an empty mailbox must not issue a header FETCH at all"
            )

            // Round 2: one message arrives. The floor says read from UID 1.
            // Tags continue at A0006 — round 1 ended at its SELECT.
            await scriptSelect(transport, number: 6, exists: 1, uidValidity: 42, uidNext: 8)
            await scriptHeaderFetch(
                transport, sequence: 1, uid: 7, flags: "",
                headers: [("Message-ID", "<first@qq.com>")]
            )
            await transport.enqueue("A0007 OK FETCH completed")
            await scriptSnippet(
                transport, sequence: 1, uid: 7,
                message: "Content-Type: text/plain; charset=UTF-8\r\n\r\nhello"
            )
            await transport.enqueue("A0008 OK FETCH completed")

            let arrival = try await provider.pullChanges(after: empty.cursor, waitUpTo: .zero)

            XCTAssertEqual(arrival.upserts.count, 1, "the first arrival of a new mailbox is never skipped")
            XCTAssertEqual(arrival.cursor.lastUid, 7)
            let lines2 = await wire(transport)
            XCTAssertTrue(
                lines2.contains("A0007 UID FETCH 1:* (UID FLAGS INTERNALDATE BODY.PEEK[HEADER.FIELDS (\(headerFields))])"),
                "with lastUid unset and floor 0, the forward round starts at UID 1"
            )
        }
    }

    /// A read-state flip made on another client is reported as an upsert that
    /// carries the real headers — the store is keyed on the Message-ID and the
    /// briefing classifier and the user's stack rules match on the sender, so
    /// neither can be dropped. The fetch is batched with the rest of the flips
    /// rather than issued one message at a time (the session is serial).
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

    /// A phone marking a batch of mail read flips up to `flagRescanWindow`
    /// (200) UIDs in one round. Each flip used to cost its own `UID FETCH` on
    /// the strictly serial session, with the command lock held throughout; the
    /// flips are now asked for in batches of 100.
    func test_pullChanges_manyReadStateFlips_batchTheirHeaderFetch() async throws {
        try await TokenKeyFixture.withKeyAsync(Self.key) {
            let transport = ScriptedTransport()
            let (provider, _) = try makeProvider(transport: transport)
            await scriptHandshake(transport)
            await scriptList(transport, number: 4, mailboxes: [
                (name: "INBOX", attribute: nil),
                (name: "Archive", attribute: "\\Archive"),
            ])
            // Round one: the window 1...200 arrives unread and becomes the
            // read-state baseline.
            await scriptSelect(transport, number: 5, uidValidity: 42, uidNext: 201)
            for uid in 1...200 {
                await scriptHeaderFetch(transport, sequence: uid, uid: Int64(uid), flags: "", headers: [
                    ("From", "zhangsan@qq.com"),
                    ("Subject", "未读"),
                    ("Message-ID", "<m\(uid)@qq.com>"),
                ])
            }
            await transport.enqueue("A0006 OK FETCH completed")
            for chunk in 0..<2 {
                for index in 0..<100 {
                    await scriptSnippet(
                        transport, sequence: index + 1, uid: Int64(chunk * 100 + index + 1),
                        message: "Content-Type: text/plain; charset=UTF-8\r\n\r\nhello"
                    )
                }
                await transport.enqueue("\(tag(7 + chunk)) OK FETCH completed")
            }

            let first = try await provider.pullChanges(
                after: MailSyncState(uidValidity: 42),
                waitUpTo: .zero
            )
            XCTAssertEqual(first.upserts.count, 200)

            // Round two: every message flipped to \Seen on another client.
            await scriptSelect(transport, number: 9, uidValidity: 42, uidNext: 201)
            await transport.enqueue("A0010 OK FETCH completed")
            for uid in 1...200 {
                await transport.enqueue(#"* \#(uid) FETCH (UID \#(uid) FLAGS (\Seen))"#)
            }
            await transport.enqueue("A0011 OK FETCH completed")
            for chunk in 0..<2 {
                for index in 0..<100 {
                    await scriptHeaderFetch(
                        transport, sequence: chunk * 100 + index + 1,
                        uid: Int64(chunk * 100 + index + 1), flags: "\\Seen", headers: [
                            ("From", "zhangsan@qq.com"),
                            ("Subject", "未读"),
                            ("Message-ID", "<m\(chunk * 100 + index + 1)@qq.com>"),
                        ]
                    )
                }
                await transport.enqueue("\(tag(12 + chunk)) OK FETCH completed")
            }

            var second: MailChangeSet?
            var failure: Error?
            do {
                second = try await provider.pullChanges(after: first.cursor, waitUpTo: .zero)
            } catch {
                failure = error
            }

            let lines = await wire(transport)
            let flipCommands = lines.filter {
                $0.contains("BODY.PEEK[HEADER.FIELDS") && $0.contains(",")
            }
            XCTAssertNil(failure, "the round completes: \(String(describing: failure))")
            XCTAssertEqual(
                flipCommands.count, 2,
                "200 flips cost two batched commands, not one per message: \(lines.filter { $0.contains("A001") })"
            )
            let change = try XCTUnwrap(second)
            XCTAssertEqual(change.upserts.count, 200, "every flip is reported")
            XCTAssertTrue(change.upserts.allSatisfy(\.isRead))
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

    /// RFC 3501 §2.3.1.1: a message's identity is (mailbox, UIDVALIDITY, UID).
    /// Two folders may report the same UIDVALIDITY and still number their mail
    /// independently, so a UID resolved in INBOX means nothing in the archive
    /// folder — reusing it would MOVE an unrelated message back to INBOX.
    func test_unarchive_doesNotReuseAnInboxUIDWhenTheFoldersShareAUIDValidity() async throws {
        try await TokenKeyFixture.withKeyAsync(Self.key) {
            let transport = ScriptedTransport()
            let (provider, _) = try makeProvider(transport: transport)
            await scriptHandshake(transport)
            // Open one message in INBOX: the Message-ID → UID cache now holds
            // (INBOX, UIDVALIDITY 42) → 5.
            await scriptSelect(transport, number: 4, uidValidity: 42, uidNext: 10)
            await transport.enqueue("* SEARCH 5")
            await transport.enqueue("A0005 OK SEARCH completed")
            await scriptHeaderFetch(transport, sequence: 1, uid: 5, flags: "\\Seen", headers: [
                ("From", "boss@qq.com"),
                ("Subject", "Q3 plan"),
                ("Message-ID", "<m7@qq.com>"),
            ])
            await transport.enqueue("A0006 OK FETCH completed")
            let headers = try await provider.fetchRawHeaderValues(remoteId: "<m7@qq.com>")
            XCTAssertEqual(headers["subject"], "Q3 plan")

            // The archive folder reports the same UIDVALIDITY but numbers the
            // same message 77. The cache must be dropped on the folder switch.
            await scriptList(transport, number: 7, mailboxes: [
                (name: "INBOX", attribute: nil),
                (name: "归档", attribute: "\\Archive"),
            ])
            await scriptSelect(transport, number: 8, uidValidity: 42, uidNext: 100)
            await transport.enqueue("* SEARCH 77")
            await transport.enqueue("A0009 OK SEARCH completed")
            await transport.enqueue("A0010 OK MOVE completed")

            try await provider.unarchive(remoteId: "<m7@qq.com>")

            let lines = await wire(transport)
            XCTAssertTrue(
                lines.contains(#"A0009 UID SEARCH HEADER Message-ID "<m7@qq.com>""#),
                "the archive folder must resolve the UID itself: \(lines)"
            )
            XCTAssertEqual(lines.last, #"A0010 UID MOVE 77 "INBOX""#)
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

    // MARK: - 彻底删除 / 清空废纸篓（唯一不可逆的操作）

    /// 彻底删除: flag `\Deleted` on that one uid, then `UID EXPUNGE` it.
    ///
    /// ## Why this test exists at all
    ///
    /// This is the only irreversible operation in the product, and until now
    /// **nothing drove it at the IMAP layer** — `PurgeRoutesTests` exercises the
    /// route with a `StubMailProvider` whose `permanentlyDelete` always
    /// succeeds, so the whole `UID EXPUNGE` path was untested. Every assertion
    /// about "permanent delete works" in this project was really an assertion
    /// about a stub.
    ///
    /// `UID EXPUNGE <uid>` rather than plain `EXPUNGE` is the point of the
    /// implementation: plain `EXPUNGE` removes **every** `\Deleted`-flagged
    /// message in the folder, including ones other clients flagged and this
    /// account never touched. For "delete this one message" that is equivalent
    /// to "delete whatever the server thinks is pending deletion".
    func test_permanentlyDelete_flagsThenUidExpungesExactlyOneUID() async throws {
        try await TokenKeyFixture.withKeyAsync(Self.key) {
            let transport = ScriptedTransport()
            let (provider, _) = try makeProvider(transport: transport)
            await scriptHandshake(transport, capabilities: "IMAP4rev1 ID IDLE UIDPLUS AUTH=PLAIN")
            await scriptList(transport, number: 4, mailboxes: [
                (name: "INBOX", attribute: nil),
                (name: "已删除", attribute: "\\Trash"),
            ])
            await scriptSelect(transport, number: 5, uidValidity: 42, uidNext: 9)
            await transport.enqueue("A0006 OK STORE completed")
            await transport.enqueue("A0007 OK EXPUNGE completed")

            try await provider.permanentlyDelete(remoteId: "7")

            let lines = await wire(transport)
            XCTAssertTrue(
                lines.contains(#"A0005 SELECT "已删除""#),
                "it must act inside the Trash, not the inbox: \(lines)"
            )
            XCTAssertEqual(Array(lines.suffix(2)), [
                #"A0006 UID STORE 7 +FLAGS (\Deleted)"#,
                "A0007 UID EXPUNGE 7",
            ])
            XCTAssertFalse(
                lines.contains { $0.hasSuffix("EXPUNGE") && !$0.contains("UID EXPUNGE") },
                "a bare EXPUNGE takes every \\Deleted message in the folder, "
                    + "including other clients' pending deletions: \(lines)"
            )
        }
    }

    /// No UIDPLUS ⇒ refuse, and **emit no deletion command at all**.    ///
    /// The implementation's own comment states the trade: a slightly larger
    /// Trash beats a wrong deletion of someone else's pending deletions. That
    /// trade is only real if the refusal happens *before* any `STORE
    /// \Deleted` — a version that flagged first and checked second would leave
    /// the message flagged (and thus one plain `EXPUNGE` away from vanishing)
    /// while still reporting failure.
    func test_permanentlyDelete_withoutUIDPLUS_refusesAndSendsNoExpunge() async throws {
        try await TokenKeyFixture.withKeyAsync(Self.key) {
            let transport = ScriptedTransport()
            let (provider, _) = try makeProvider(transport: transport)
            await scriptHandshake(transport, capabilities: "IMAP4rev1 ID IDLE AUTH=PLAIN")
            await scriptList(transport, number: 4, mailboxes: [
                (name: "INBOX", attribute: nil),
                (name: "已删除", attribute: "\\Trash"),
            ])
            await scriptSelect(transport, number: 5, uidValidity: 42, uidNext: 9)

            do {
                try await provider.permanentlyDelete(remoteId: "7")
                XCTFail("without UIDPLUS the operation must be refused, not approximated")
            } catch let error as MailError {
                guard case .protocolError(let message) = error else {
                    return XCTFail("expected protocolError, got \(error)")
                }
                XCTAssertTrue(
                    message.contains("UIDPLUS"),
                    "the refusal must name the missing capability: \(message)"
                )
            }

            let lines = await wire(transport)
            XCTAssertFalse(
                lines.contains { $0.contains("EXPUNGE") },
                "nothing may be expunged on a server without UIDPLUS: \(lines)"
            )
            XCTAssertFalse(
                lines.contains { $0.contains("STORE") },
                "and nothing may be flagged \\Deleted either — a flag without an "
                    + "expunge leaves it one plain EXPUNGE from gone: \(lines)"
            )
        }
    }

    /// 清空废纸篓: flag every uid the Trash holds, then one batched
    /// `UID EXPUNGE` over the whole set.
    ///
    /// The uid set comes from *this* folder under *this* session's view, so a
    /// message another client trashed a moment ago is not swept up by
    /// implication. The batched form is also asserted because the per-message
    /// loop that precedes it is the easy shape to regress into.
    func test_emptyTrash_flagsAllThenExpungesTheWholeSetAtOnce() async throws {
        try await TokenKeyFixture.withKeyAsync(Self.key) {
            let transport = ScriptedTransport()
            let (provider, _) = try makeProvider(transport: transport)
            await scriptHandshake(transport, capabilities: "IMAP4rev1 ID IDLE UIDPLUS AUTH=PLAIN")
            await scriptList(transport, number: 4, mailboxes: [
                (name: "INBOX", attribute: nil),
                (name: "已删除", attribute: "\\Trash"),
            ])
            await scriptSelect(transport, number: 5, uidValidity: 42, uidNext: 9)
            await transport.enqueue("* SEARCH 3 5 9")
            await transport.enqueue("A0006 OK SEARCH completed")
            for number in 7...9 {
                await transport.enqueue("A000\(number) OK STORE completed")
            }
            await transport.enqueue("A0010 OK EXPUNGE completed")

            try await provider.emptyTrash()

            let lines = await wire(transport)
            XCTAssertTrue(lines.contains("A0006 UID SEARCH ALL"), "the uid set comes from the folder: \(lines)")

            // Every uid in the folder is flagged, in *some* order: `allUIDs()`
            // returns a `Set<Int64>`, so both the uid sequence and its pairing to
            // response tags are unordered by construction. Asserting `3,5,9` —
            // or which tag answered which uid — would be asserting an
            // implementation detail that a legitimate `Set` change would break
            // for no behavioural reason; the uid order in `UID EXPUNGE` is not
            // semantically meaningful. So: the *set* of flagged uids, and the
            // *set* of expunged uids, which is what the protocol actually means.
            let storedUIDs = Set(lines.compactMap { line -> Int64? in
                let parts = line.split(separator: " ").map(String.init)
                guard line.contains("UID STORE"),
                      let index = parts.firstIndex(of: "STORE"),
                      parts.count > index + 1 else { return nil }
                return Int64(parts[index + 1])
            })
            XCTAssertEqual(
                storedUIDs, [3, 5, 9],
                "every uid in the Trash must be flagged before the expunge: \(lines)"
            )
            XCTAssertEqual(
                lines.filter { $0.contains("UID STORE") }.count, 3,
                "one flag per uid, no duplicates: \(lines)"
            )

            // The expunge itself is one command over the whole set.
            let expunges = lines.filter { $0.contains("EXPUNGE") }
            XCTAssertEqual(
                expunges.count, 1,
                "one batched command, not a loop: \(lines)"
            )
            let expungedUIDs = expunges.first.flatMap { line -> Set<Int64>? in
                let payload = line.split(separator: " ").last.map(String.init) ?? ""
                let parts = payload.split(separator: ",").compactMap { Int64($0) }
                return parts.isEmpty ? nil : Set(parts)
            }
            XCTAssertEqual(
                expungedUIDs, [3, 5, 9],
                "and it must name every flagged uid: \(lines)"
            )
            XCTAssertFalse(
                lines.contains { $0.hasSuffix("EXPUNGE") && !$0.contains("UID EXPUNGE") },
                "a bare EXPUNGE here would take the whole folder with it: \(lines)"
            )
        }
    }

    /// An empty Trash must send **no** expunge at all.
    ///
    /// `UID EXPUNGE` with an empty sequence set is at best a server error and at
    /// worst, on a server that treats it loosely, an unfiltered expunge — which
    /// is the exact catastrophe the UIDPLUS requirement exists to prevent. The
    /// empty case is also the one a user hits on their first "empty trash",
    /// where nothing is actually there.
    func test_emptyTrash_onAnEmptyFolder_sendsNoExpunge() async throws {
        try await TokenKeyFixture.withKeyAsync(Self.key) {
            let transport = ScriptedTransport()
            let (provider, _) = try makeProvider(transport: transport)
            await scriptHandshake(transport, capabilities: "IMAP4rev1 ID IDLE UIDPLUS AUTH=PLAIN")
            await scriptList(transport, number: 4, mailboxes: [
                (name: "INBOX", attribute: nil),
                (name: "已删除", attribute: "\\Trash"),
            ])
            await scriptSelect(transport, number: 5, exists: 0, uidValidity: 42, uidNext: 9)
            await transport.enqueue("* SEARCH")
            await transport.enqueue("A0006 OK SEARCH completed")

            try await provider.emptyTrash()

            let lines = await wire(transport)
            XCTAssertFalse(
                lines.contains { $0.contains("EXPUNGE") },
                "nothing to empty means nothing to expunge: \(lines)"
            )
            XCTAssertFalse(
                lines.contains { $0.contains("STORE") },
                "and nothing to flag: \(lines)"
            )
        }
    }

    /// No Trash folder at all ⇒ refuse, and touch nothing.
    func test_emptyTrash_withoutATrashFolder_refuses() async throws {
        try await TokenKeyFixture.withKeyAsync(Self.key) {
            let transport = ScriptedTransport()
            let (provider, _) = try makeProvider(transport: transport)
            await scriptHandshake(transport, capabilities: "IMAP4rev1 ID IDLE UIDPLUS AUTH=PLAIN")
            await scriptList(transport, number: 4, mailboxes: [
                (name: "INBOX", attribute: nil),
            ])

            do {
                try await provider.emptyTrash()
                XCTFail("an account with no Trash must refuse rather than sweep the inbox")
            } catch let error as MailError {
                XCTAssertTrue(
                  error == .trashUnavailable,
                    "expected trashUnavailable, got \(error)"
                )
            }
            let lines = await wire(transport)
            XCTAssertFalse(lines.contains { $0.contains("EXPUNGE") }, "\(lines)")
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
            // The push wait re-selects INBOX before parking, so the IDLE is
            // issued against the mailbox that can actually report new mail.
            await scriptSelect(transport, number: 7, uidValidity: 42, uidNext: 1)
            await transport.enqueue("+ idling")
            await transport.enqueue("* 1 EXISTS")
            await transport.enqueue("A0008 OK IDLE completed")
            await scriptSelect(transport, number: 9, uidValidity: 42, uidNext: 2)
            await scriptHeaderFetch(transport, sequence: 1, uid: 1, flags: "", headers: [
                ("From", "zhangsan@qq.com"),
                ("Subject", "pushed"),
            ])
            await transport.enqueue("A0010 OK FETCH completed")
            await scriptSnippet(
                transport, sequence: 1, uid: 1,
                message: "Content-Type: text/plain; charset=UTF-8\r\n\r\nhi"
            )
            await transport.enqueue("A0011 OK FETCH completed")

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
                lines.filter { $0.contains("SELECT") }.count, 3,
                "one SELECT per round plus the re-select before IDLE, not one per poll interval"
            )
        }
    }

    /// Regression: a round ends in `collectSentReplies`, which SELECTs the Sent
    /// folder to look for replies. The push wait used to issue IDLE against
    /// whatever mailbox was left selected, so with a Sent folder present the
    /// provider parked on Sent and never learned about an arriving inbox
    /// message until the whole wait budget expired. The only pre-existing IDLE
    /// test scripted a LIST with no Sent folder, so `collectSentReplies`
    /// returned early and the bug was invisible.
    func test_pullChanges_withSentFolder_idlesOnInboxNotSent() async throws {
        try await TokenKeyFixture.withKeyAsync(Self.key) {
            let transport = ScriptedTransport()
            let (provider, _) = try makeProvider(transport: transport)
            await scriptHandshake(transport)
            await scriptList(transport, number: 4, mailboxes: [
                (name: "INBOX", attribute: nil),
                (name: "Archive", attribute: "\\Archive"),
                (name: "Sent Messages", attribute: nil),
            ])
            // Round 1: empty INBOX, empty Sent, so the round reports nothing
            // and the provider falls through to the push wait.
            await scriptSelect(transport, number: 5, uidValidity: 42, uidNext: 1)
            await transport.enqueue("A0006 OK FETCH completed")
            await scriptSelect(transport, number: 7, exists: 0, uidValidity: 7, uidNext: 1)
            // The re-select the fix introduced: back to INBOX, *then* IDLE.
            await scriptSelect(transport, number: 8, uidValidity: 42, uidNext: 1)
            await transport.enqueue("+ idling")
            await transport.enqueue("* 1 EXISTS")
            await transport.enqueue("A0009 OK IDLE completed")
            // Round 2 sees the pushed message.
            await scriptSelect(transport, number: 10, uidValidity: 42, uidNext: 2)
            await scriptHeaderFetch(transport, sequence: 1, uid: 1, flags: "", headers: [
                ("From", "zhangsan@qq.com"),
                ("Subject", "pushed"),
            ])
            await transport.enqueue("A0011 OK FETCH completed")
            await scriptSnippet(
                transport, sequence: 1, uid: 1,
                message: "Content-Type: text/plain; charset=UTF-8\r\n\r\nhi"
            )
            await transport.enqueue("A0012 OK FETCH completed")
            await scriptSelect(transport, number: 13, exists: 0, uidValidity: 7, uidNext: 1)

            let change = try await provider.pullChanges(
                after: MailSyncState(uidValidity: 42),
                waitUpTo: .milliseconds(200)
            )

            XCTAssertEqual(change.upserts.count, 1, "the pushed inbox message must be reported")
            let lines = await wire(transport)
            let idleIndex = try XCTUnwrap(lines.firstIndex { $0.hasSuffix(" IDLE") })
            let lastSelectBeforeIdle = try XCTUnwrap(
                lines[..<idleIndex].lastIndex { $0.contains(IMAPClient.selectVerb) }
            )
            XCTAssertTrue(
                lines[lastSelectBeforeIdle].hasSuffix("\"INBOX\""),
                "IDLE must be parked on INBOX, got: \(lines[lastSelectBeforeIdle])"
            )
            XCTAssertTrue(
                lines.prefix(idleIndex).contains { $0.contains("SELECT \"Sent Messages\"") },
                "the round really did visit Sent, so this test would have caught the bug"
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
