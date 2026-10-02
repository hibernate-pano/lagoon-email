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
            // One range snippet command for the whole window (both untagged
            // FETCH blocks answer A0007): a backfill must not pay one round
            // trip per message.
            await scriptSnippet(
                transport, sequence: 1, uid: 900,
                message: "Content-Type: text/plain; charset=UTF-8\r\n\r\nHello from QQ"
            )
            await scriptSnippet(
                transport, sequence: 2, uid: 901,
                message: "Content-Type: text/plain; charset=UTF-8\r\n"
                    + "Content-Transfer-Encoding: base64\r\n\r\nSGVsbG8gd29ybGQhIHN0dWZm"
            )
            await transport.enqueue("A0007 OK FETCH completed")

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

            let change = try await provider.pullChanges(
                after: MailSyncState(uidValidity: 42, lastUid: 0),
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
