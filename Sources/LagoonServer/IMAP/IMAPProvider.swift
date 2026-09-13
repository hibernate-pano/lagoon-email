import Foundation
import Logging
import LagoonKit
import PostgresNIO

/// IMAP-backed `MailProvider` (QQ first).
///
/// One long-lived connection per provider instance, a UIDNEXT cursor, and IDLE
/// when the server offers it. The provider is the only place that turns IMAP
/// bytes into the provider-neutral structures `SyncEngine` persists (spec
/// §3.2); `SyncEngine` caches instances per account, so the connection, the
/// resolved archive folder and the read-state baseline all survive between
/// ticks.
public actor IMAPProvider: MailProvider, ArchiveFolderResolving {
    /// First pull backfills `UIDNEXT - window` … end, so a freshly connected
    /// mailbox shows recent mail instead of its whole history (spec §3.2).
    static let backfillWindow: Int64 = 500
    /// Read-state rescan window: one round costs at most this many UID flags
    /// (spec §3.2 step 3).
    static let flagRescanWindow: Int64 = 200
    /// Poll cadence when the server has no IDLE — the Gmail poller's rhythm.
    static let pollInterval: Duration = .seconds(30)
    /// One IDLE stretch. The loop leaves IDLE, re-SELECTs and re-enters, so a
    /// long `waitUpTo` never exceeds the protocol's IDLE ceiling.
    static let idleBudget: Duration = .seconds(290)
    static let inboxName = "INBOX"
    static let defaultArchiveFolderName = "Archive"

    public let kind: MailProviderKind

    private let account: Account
    private let db: PostgresConnection?
    private let logger: Logger
    private let transportFactory: @Sendable () -> any StreamTransport
    /// IMAP is single-command by design. Actor reentrancy alone does not keep
    /// two route calls from interleaving tagged commands while one awaits I/O.
    private let commandLock = AsyncMutex()

    private var client: IMAPClient?
    /// Capability names as negotiated by the live session.
    private var negotiated: Set<String> = []
    /// Mailbox state of the last SELECT; nil means "not selected yet".
    private var selected: IMAPSelected?
    /// The archive role is account data, not connection state: it survives a
    /// reconnect (spec §4.3).
    private var archiveResolved = false
    private var archiveName: String?
    private var sentResolved = false
    private var sentName: String?
    private var cachedCapabilities: MailCapabilities?
    /// `\Seen` as last reported to the store. Flips are only reported for UIDs
    /// in here: without a baseline a rescan says nothing about what the user
    /// has already seen.
    private var reportedRead: [Int64: Bool] = [:]
    /// The pull path is otherwise silent, which makes "connected but nothing
    /// arrived" indistinguishable from "empty mailbox" — the log only says
    /// `imap.connected`. One SELECT/backfill summary per process per account.
    private var loggedFirstRound = false

    public init(
        account: Account,
        db: PostgresConnection?,
        logger: Logger,
        transportFactory: @escaping @Sendable () -> any StreamTransport = {
            NIOSSLStreamTransport()
        }
    ) {
        self.kind = account.provider
        self.account = account
        self.db = db
        self.logger = logger
        self.transportFactory = transportFactory
    }

    // MARK: - Capabilities

    public func capabilities() async -> MailCapabilities {
        do {
            let resolved = try await withClient { client -> MailCapabilities in
                let folder = try await resolveArchiveFolder(client: client)
                return MailCapabilities(
                    archiveFolder: folder != nil,
                    idle: negotiated.contains("IDLE"),
                    move: negotiated.contains("MOVE"),
                    // Every IMAP body can be sampled from its message prefix
                    // with BODY.PEEK[] and decoded by MIMEParser.
                    serverSnippet: true
                )
            }
            cachedCapabilities = resolved
            return resolved
        } catch {
            // The protocol signature is non-throwing; the sync round reports
            // the failure. A previous negotiation stays valid on the account.
            logger.warning("imap.capabilitiesFailed", metadata: ["label": .string(Self.label(error))])
            return cachedCapabilities ?? .unknown
        }
    }

    /// The resolved remote archive mailbox, `nil` when this server has none.
    /// The connect flow persists it into the account's sync cursor.
    public func archiveFolder() async -> String? {
        do {
            return try await withClient { client in
                try await resolveArchiveFolder(client: client)
            }
        } catch {
            return nil
        }
    }

    /// Diagnostics only: check whether a recently sent message reached the
    /// server's Sent-role mailbox. This is used by `LagoonServer --self-test`.
    public func diagnosticSentContains(subject: String, limit: Int = 30) async throws -> Bool {
        try await withClient { client in
            let mailboxes = try await client.listMailboxes()
            guard let sent = mailboxes.first(where: { mailbox in
                mailbox.attributes.contains {
                    $0.caseInsensitiveCompare("\\Sent") == .orderedSame
                } || ["sent", "sent messages", "已发送", "已发送邮件"].contains(
                    mailbox.name.lowercased()
                )
            }) else {
                return false
            }
            let state = try await client.select(sent.name)
            let fromUid = max(1, state.uidNext - Int64(max(limit, 1)))
            let headers = try await client.fetchHeaders(fromUid: fromUid)
            let contains = headers.contains { fetched in
                guard let raw = fetched.rawHeaders["subject"] else { return false }
                let decoded = MIMEParser.decodeRFC2047(raw)
                return decoded == subject || decoded == "Re: \(subject)"
            }
            selected = try await client.select(Self.inboxName)
            return contains
        }
    }

    public func diagnosticMailboxes() async throws -> [IMAPMailbox] {
        try await withClient { client in
            try await client.listMailboxes()
        }
    }

    public func diagnosticFind(subject: String, perMailboxLimit: Int = 100) async throws -> [(String, Int64)] {
        try await withClient { client in
            var matches: [(String, Int64)] = []
            let mailboxes = try await client.listMailboxes()
            for mailbox in mailboxes where !mailbox.attributes.contains(where: {
                $0.caseInsensitiveCompare("\\NoSelect") == .orderedSame
            }) {
                let state = try await client.select(mailbox.name)
                let fromUid = max(1, state.uidNext - Int64(max(perMailboxLimit, 1)))
                let headers = try await client.fetchHeaders(fromUid: fromUid)
                for header in headers {
                    guard let raw = header.rawHeaders["subject"],
                          MIMEParser.decodeRFC2047(raw).contains(subject)
                    else { continue }
                    matches.append((mailbox.name, header.uid))
                }
            }
            selected = nil
            return matches
        }
    }

    // MARK: - Pull

    public func pullChanges(
        after cursor: MailSyncState,
        waitUpTo: Duration
    ) async throws -> MailChangeSet {
        let deadline = ContinuousClock.now.advanced(by: waitUpTo)
        // Half the budget caps the poll cadence, so a short `waitUpTo` (the
        // connect flow's immediate sync) still gets more than one look.
        let pollInterval = max(.milliseconds(1), min(Self.pollInterval, waitUpTo / 2))
        while true {
            let change = try await round(after: cursor)
            if !change.upserts.isEmpty || change.resetRequired { return change }
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { return change }
            if negotiated.contains("IDLE") {
                // Push: IDLE returns as soon as the mailbox moves, so new mail
                // is picked up within seconds instead of on the next poll.
                try await withClient { client in
                    try await client.idle(waitUpTo: min(remaining, Self.idleBudget))
                }
            } else {
                guard remaining >= pollInterval else { return change }
                try await Task.sleep(for: pollInterval)
            }
        }
    }

    /// One spec §3.2 round: refresh the selection, diff new mail and read-state
    /// flips, and report what the store must write.
    private func round(after cursor: MailSyncState) async throws -> MailChangeSet {
        try await withClient { client -> MailChangeSet in
            let archiveFolder = try await resolveArchiveFolder(client: client)
            let inbox = try await selectInbox(client: client, force: true)

            // UIDVALIDITY moved: every stored UID belongs to a dead identity
            // space, so the store is wiped before the next round backfills
            // (spec §2.4).
            if let expected = cursor.uidValidity, expected != inbox.uidValidity {
                logger.warning("sync.uidValidityReset", metadata: ["account": .string(account.email)])
                reportedRead.removeAll()
                return MailChangeSet(
                    upserts: [],
                    resetRequired: true,
                    cursor: MailSyncState(
                        historyId: cursor.historyId,
                        uidValidity: inbox.uidValidity,
                        lastUid: nil,
                        archiveFolder: archiveFolder
                    )
                )
            }

            let fromUid = cursor.lastUid.map { $0 + 1 }
                ?? max(1, inbox.uidNext - Self.backfillWindow)
            let fetched = try await client.fetchHeaders(fromUid: fromUid)
            if !loggedFirstRound {
                loggedFirstRound = true
                logger.info("imap.round", metadata: [
                    "account": .string(account.email),
                    "exists": .string("\(inbox.exists)"),
                    "uidValidity": .string("\(inbox.uidValidity)"),
                    "uidNext": .string("\(inbox.uidNext)"),
                    "fromUid": .string("\(fromUid)"),
                    "fetched": .string("\(fetched.count)"),
                ])
            }

            var upserts: [RemoteHeader] = []
            upserts.reserveCapacity(fetched.count)
            for header in fetched {
                let remote = remoteHeader(from: header, snippet: await snippetText(client: client, uid: header.uid))
                upserts.append(remote)
                reportedRead[header.uid] = remote.isRead
            }
            if let lastUid = cursor.lastUid, lastUid > 0 {
                upserts.append(contentsOf: try await readStateFlips(client: client, through: lastUid))
            }

            // Only new mail advances the cursor: an empty window means there is
            // nothing newer to resume from.
            let nextLastUid = fetched.map(\.uid).max().map { max(cursor.lastUid ?? 0, $0) }
                ?? cursor.lastUid
            return MailChangeSet(
                upserts: upserts,
                resetRequired: false,
                cursor: MailSyncState(
                    historyId: cursor.historyId,
                    uidValidity: inbox.uidValidity,
                    lastUid: nextLastUid,
                    archiveFolder: archiveFolder
                )
            )
        }
    }

    /// Bounded `\Seen` rescan over already-known mail (spec §3.2 step 3).
    private func readStateFlips(client: IMAPClient, through lastUid: Int64) async throws -> [RemoteHeader] {
        let fromUid = max(1, lastUid - Self.flagRescanWindow + 1)
        let flags = try await client.fetchFlags(fromUid: fromUid, toUid: lastUid)

        var flips: [RemoteHeader] = []
        for entry in flags {
            let isRead = Self.isRead(flags: entry.flags)
            guard let known = reportedRead[entry.uid], known != isRead else { continue }
            reportedRead[entry.uid] = isRead
            // The store overwrites `subject` on conflict, so a flip must carry
            // the real headers instead of just the flag.
            guard let header = try await client.fetchHeader(uid: entry.uid).first else { continue }
            flips.append(remoteHeader(from: header))
        }
        return flips
    }

    /// Best-effort snippet (spec §3.2 step 4): a preview is never worth
    /// failing a pull over, but a failed command may have desynced the
    /// session, so the connection is dropped and rebuilt next round.
    private func snippetText(client: IMAPClient, uid: Int64) async -> String? {
        do {
            let fetched = try await client.fetchTextSnippet(uid: uid)
            return Self.snippetText(from: fetched.first?.snippet)
        } catch {
            logger.debug("imap.snippetSkipped", metadata: ["label": .string(Self.label(error))])
            dropConnection()
            return nil
        }
    }

    // MARK: - Body & headers

    public func fetchBody(remoteId: String) async throws -> String {
        return try await withClient { client in
            try await selectInbox(client: client, force: false)
            let uid = try await resolveUID(remoteId, client: client)
            let raw = try await client.fetchFullBody(uid: uid)
            return MIMEParser.plainText(from: raw)
        }
    }

    public func fetchRawHeaderValues(remoteId: String) async throws -> [String: String] {
        return try await withClient { client in
            try await selectInbox(client: client, force: false)
            let uid = try await resolveUID(remoteId, client: client)
            guard let header = try await client.fetchHeader(uid: uid).first else {
                throw MailError.messageGone
            }
            return header.rawHeaders
        }
    }

    // MARK: - Mutations

    public func setRead(remoteId: String, isRead: Bool) async throws {
        try await withClient { client in
            try await selectInbox(client: client, force: false)
            let uid = try await resolveUID(remoteId, client: client)
            try await client.store(
                uid: uid,
                add: isRead ? ["\\Seen"] : [],
                remove: isRead ? [] : ["\\Seen"]
            )
            // Keep the baseline honest: our own write must not come back as a
            // "flip" in the next round.
            reportedRead[uid] = isRead
        }
    }

    public func archive(remoteId: String) async throws {
        try await withClient { client in
            guard let folder = try await resolveArchiveFolder(client: client) else {
                throw MailError.archiveUnavailable
            }
            try await selectInbox(client: client, force: false)
            let uid = try await resolveUID(remoteId, client: client)
            try await move(client: client, uid: uid, to: folder)
        }
    }

    public func unarchive(remoteId: String) async throws {
        try await withClient { client in
            guard let folder = try await resolveArchiveFolder(client: client) else {
                throw MailError.archiveUnavailable
            }
            selected = try await client.select(folder)
            let archivedUID = try await resolveUID(remoteId, client: client)
            try await move(client: client, uid: archivedUID, to: Self.inboxName)
            selected = nil
        }
    }

    /// SMTP lives beside IMAP, not inside it: a fresh TLS session per send, to
    /// the preset host only. The auth code is the same one IMAP uses, read
    /// straight from the sealed blob and never held past the session.
    public func send(_ outbound: OutboundMessage) async throws -> String? {
        guard let preset = ProviderPresets.imap(for: account.provider) else {
            throw MailError.notConfigured("no smtp preset")
        }
        let credentials = try await imapCredentials()
        let smtp = SMTPClient(transport: transportFactory(), logger: logger)
        let messageID = "<\(UUID().uuidString.lowercased())@lagoon>"
        let message = outbound.isReply
            ? MIMEBuilder.reply(outbound, messageId: messageID)
            : MIMEBuilder.newMessage(outbound, messageId: messageID)
        try await smtp.sendRaw(
            message,
            outbound: outbound,
            host: preset.smtpHost,
            port: preset.smtpPort,
            username: credentials.username,
            authCode: credentials.authCode
        )
        do {
            if let sent = try await resolveSentFolder() {
                try await withClient { client in
                    try await client.append(mailbox: sent, message: message)
                }
            }
        } catch {
            // Delivery already succeeded. Do not make the client retry a sent
            // message just because the audit copy could not be appended.
            logger.warning("imap.sent.appendFailed", metadata: [
                "label": .string(Self.label(error)),
            ])
        }
        return messageID
    }

    public func probe() async throws {
        try await withClient { client in
            _ = try await resolveArchiveFolder(client: client)
            try await selectInbox(client: client, force: true)
        }
    }

    // MARK: - Connection lifecycle

    /// Run one command sequence on a live session. Failures are mapped to the
    /// provider-neutral surface, and the session is rebuilt on the next call
    /// unless the error is a verdict about the message rather than the socket.
    private func withClient<T>(_ body: (IMAPClient) async throws -> T) async throws -> T {
        await commandLock.lock()
        do {
            try Task.checkCancellation()
            let client = try await connectedClient()
            let result = try await body(client)
            await commandLock.unlock()
            return result
        } catch let error as MailError where error == .messageGone {
            await commandLock.unlock()
            throw error
        } catch {
            dropConnection()
            await commandLock.unlock()
            throw Self.map(error)
        }
    }

    private func connectedClient() async throws -> IMAPClient {
        if let client { return client }
        let credentials = try await imapCredentials()
        guard let preset = ProviderPresets.imap(for: account.provider) else {
            throw MailError.notConfigured("no imap preset")
        }
        let connection = IMAPConnection(transport: transportFactory(), logger: logger)
        let client = IMAPClient(connection: connection, logger: logger)
        do {
            try await client.connect(host: preset.imapHost, port: preset.imapPort)
            try await client.login(username: credentials.username, authCode: credentials.authCode)
            try await client.sendID()
            negotiated = try await client.capability()
        } catch {
            await client.logout()
            throw Self.map(error)
        }
        self.client = client
        selected = nil
        return client
    }

    /// Tearing the session down is deliberately local: the socket is already
    /// presumed dead, and a reconnect builds a fresh transport anyway.
    private func dropConnection() {
        client = nil
        selected = nil
    }

    /// The auth code lives only between the sealed blob and the TLS session.
    private func imapCredentials() async throws -> (username: String, authCode: String) {
        let credentials: AccountCredentials
        if let blob = account.credentials {
            do {
                credentials = try CredentialVault.open(blob)
            } catch {
                throw MailError.notConfigured("credentials unreadable")
            }
        } else if let db {
            credentials = try await CredentialVault.read(accountId: account.id, db: db)
        } else {
            throw MailError.notConfigured("imap credentials missing")
        }
        guard case .imap(let username, let authCode) = credentials else {
            throw MailError.notConfigured("credential kind mismatch")
        }
        return (username, authCode)
    }

    private func selectInbox(client: IMAPClient, force: Bool) async throws -> IMAPSelected {
        if !force, let selected { return selected }
        let state = try await client.select(Self.inboxName)
        selected = state
        return state
    }

    /// Resolve the archive role once per provider: SPECIAL-USE `\Archive`, a
    /// name match, or a one-time CREATE. Nothing available → nil, and the
    /// client disables archiving instead of misfiling mail into Trash
    /// (spec §4.3).
    private func resolveArchiveFolder(client: IMAPClient) async throws -> String? {
        if archiveResolved { return archiveName }
        let mailboxes = try await client.listMailboxes()
        if let special = mailboxes.first(where: { mailbox in
            mailbox.attributes.contains { $0.caseInsensitiveCompare("\\Archive") == .orderedSame }
        }) {
            archiveName = special.name
        } else if let named = mailboxes.first(where: { mailbox in
            ["archive", "归档"].contains(mailbox.name.lowercased())
        }) {
            archiveName = named.name
        } else {
            do {
                try await client.createMailbox(Self.defaultArchiveFolderName)
                archiveName = Self.defaultArchiveFolderName
            } catch let error as MailError where error != .authFailed {
                logger.warning(
                    "imap.archive.createRefused",
                    metadata: ["label": .string(error.logLabel)]
                )
                archiveName = nil
            }
        }
        archiveResolved = true
        return archiveName
    }

    private func resolveSentFolder() async throws -> String? {
        if sentResolved { return sentName }
        return try await withClient { client in
            let mailboxes = try await client.listMailboxes()
            sentName = mailboxes.first(where: { mailbox in
                mailbox.attributes.contains {
                    $0.caseInsensitiveCompare("\\Sent") == .orderedSame
                } || ["sent", "sent messages", "已发送", "已发送邮件"].contains(
                    mailbox.name.lowercased()
                )
            })?.name
            sentResolved = true
            return sentName
        }
    }

    /// `UID MOVE` when the server has it, else the §4.3 fallback.
    private func move(client: IMAPClient, uid: Int64, to mailbox: String) async throws {
        do {
            try await client.move(uid: uid, to: mailbox)
        } catch MailError.protocolError(let reason) where reason == "MOVE not supported" {
            try await client.copy(uid: uid, to: mailbox)
            try await client.store(uid: uid, add: ["\\Deleted"])
            try await client.expunge()
        }
    }

    // MARK: - Mapping

    /// One wire header block → the provider-neutral row. RFC 2047 runs first:
    /// QQ encodes Chinese subjects and display names as encoded-words.
    private func remoteHeader(from fetched: IMAPFetchedHeader, snippet: String? = nil) -> RemoteHeader {
        let headers = fetched.rawHeaders
        func decoded(_ name: String) -> String? {
            guard let value = headers[name], !value.isEmpty else { return nil }
            return MIMEParser.decodeRFC2047(value)
        }
        let (address, name) = FromHeader.parse(decoded("from") ?? "")
        let messageID = decoded("message-id")
        return RemoteHeader(
            remoteId: messageID ?? "uid:\(fetched.uid)",
            threadId: Self.threadId(
                references: decoded("references"),
                messageId: messageID,
                uid: fetched.uid
            ),
            fromAddress: address,
            fromName: name,
            subject: decoded("subject"),
            snippet: snippet,
            receivedAt: fetched.internalDate ?? Date(),
            isRead: Self.isRead(flags: fetched.flags),
            listUnsubscribe: decoded("list-unsubscribe") != nil,
            messageIdHeader: messageID,
            inReplyTo: decoded("in-reply-to"),
            references: decoded("references")
        )
    }

    /// UID is a mailbox-local position and can change after MOVE. New IMAP rows
    /// use Message-ID as the stable identity; numeric values remain supported
    /// for rows created before the migration.
    private func resolveUID(_ remoteId: String, client: IMAPClient) async throws -> Int64 {
        if let uid = Int64(remoteId) {
            return uid
        }
        if remoteId.hasPrefix("uid:"), let uid = Int64(remoteId.dropFirst(4)) {
            return uid
        }
        if let uid = try await client.searchUID(messageID: remoteId) {
            return uid
        }
        // QQ accepts HEADER SEARCH but can return an empty set even when the
        // header is present. Scan the selected mailbox's recent window as a
        // deterministic fallback.
        if let selected {
            let fromUid = max(1, selected.uidNext - 501)
            let headers = try await client.fetchHeaders(fromUid: fromUid)
            if let match = headers.first(where: {
                $0.rawHeaders["message-id"] == remoteId
            }) {
                return match.uid
            }
        }
        throw MailError.messageGone
    }

    static func isRead(flags: [String]) -> Bool {
        flags.contains { $0.caseInsensitiveCompare("\\Seen") == .orderedSame }
    }

    /// Conversation key: the first References entry (the thread root), else the
    /// Message-ID, else the UID for mail that carries neither.
    static func threadId(references: String?, messageId: String?, uid: Int64) -> String {
        if let root = references?.split(whereSeparator: \.isWhitespace).first.map(String.init),
           !root.isEmpty {
            return root
        }
        if let messageId, !messageId.trimmingCharacters(in: .whitespaces).isEmpty {
            return messageId
        }
        return "uid:\(uid)"
    }

    /// `BODY[]<0.N>` message prefix → preview text, or nil when nothing
    /// readable is inside the window.
    ///
    /// The bytes now start at the RFC 2822 header block, so the project's MIME
    /// decoder does the work: `plainText` splits headers from body, reads the
    /// content type and transfer encoding, and returns the preferred part's
    /// text (base64 / quoted-printable / multipart / HTML all handled). The old
    /// guards remain as a fallback for the cases the parser cannot resolve —
    /// a window that stops inside the header block, or a single-part base64
    /// message whose `content-type` fell outside the window, which
    /// `preferredContent` would otherwise hand back as raw base64 under the
    /// `text/plain` default. A mis-snippet is still worse than no snippet.
    static func snippetText(from data: Data?) -> String? {
        guard let data else { return nil }
        let decoded = MIMEParser.plainText(from: data)
        // Header-only window or an attachment-only body: nothing readable.
        guard !decoded.isEmpty else { return nil }
        // The list shows one line, so runs of whitespace (including the raw
        // body's newlines) collapse to single spaces.
        let collapsed = decoded.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        // A single-part base64 message whose content-type header is outside the
        // window comes back as raw base64 (the text/plain default). Guard after
        // folding, and against the whitespace-free payload: line-folded base64
        // carries CRLF (and sometimes spaces) between its lines, which breaks
        // both the %4 length test and the alphabet test, so testing the raw
        // or space-joined text lets a folded payload through as prose.
        guard !looksTransferEncoded(collapsed.filter { !$0.isWhitespace }) else { return nil }
        // A multipart body the parser could not route (missing content-type /
        // boundary) survives as structure starting with `--boundary`.
        guard !collapsed.hasPrefix("--") else { return nil }
        return String(collapsed.prefix(200))
    }

    static func looksTransferEncoded(_ text: String) -> Bool {
        if text.contains("=\r\n") || text.contains("=\n") || text.hasSuffix("=") { return true }
        guard text.count >= 16, text.count % 4 == 0 else { return false }
        let alphabet = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/="
        )
        return text.unicodeScalars.allSatisfy { alphabet.contains($0) }
    }

    private static func uid(from remoteId: String) throws -> Int64 {
        guard let uid = Int64(remoteId), uid > 0 else {
            throw MailError.protocolError("invalid remote id")
        }
        return uid
    }

    /// Wire failures → the provider-neutral surface. Only a stable label is
    /// ever logged: mail content and credentials stay out of logs (spec §5.2).
    static func map(_ error: Error) -> Error {
        if error is CancellationError { return error }
        if let mail = error as? MailError { return mail }
        if error is StreamTransportError { return MailError.unreachable("imap transport") }
        return MailError.unreachable("imap \(type(of: error))")
    }

    static func label(_ error: Error) -> String {
        (error as? MailError)?.logLabel ?? "\(type(of: error))"
    }
}
