import Foundation
import Logging
import LagoonKit
import GRDB

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
    /// First Sent-folder scan is bounded: only threading references are
    /// harvested (no bodies, no snippets), but an unbounded first scan on a
    /// decade-old Sent mailbox is still a pointless FETCH.
    static let sentBackfillWindow: Int64 = 200
    /// Poll cadence when the server has no IDLE.
    static let pollInterval: Duration = .seconds(30)
    /// One IDLE stretch. The loop leaves IDLE, re-SELECTs and re-enters, so a
    /// long `waitUpTo` never exceeds the protocol's IDLE ceiling.
    static let idleBudget: Duration = .seconds(290)
    static let inboxName = "INBOX"
    static let defaultArchiveFolderName = "Archive"

    public let kind: MailProviderKind

    private let account: Account
    private let db: LagoonDB?
    private let logger: Logger
    private let transportFactory: @Sendable () -> any StreamTransport
    /// Full INBOX membership reconciliation. Enabled in production; provider
    /// tests that script one narrow wire round can disable it.
    private let reconcilesInbox: Bool
    /// IMAP is single-command by design. Actor reentrancy alone does not keep
    /// two route calls from interleaving tagged commands while one awaits I/O.
    private let commandLock = AsyncMutex()

    private var client: IMAPClient?
    /// Capability names as negotiated by the live session.
    private var negotiated: Set<String> = []
    /// Mailbox state of the last SELECT; nil means "not selected yet".
    private var selected: IMAPSelected?
    /// Message-ID → UID for the currently-selected mailbox.
    ///
    /// IMAP addresses messages by UID, but the store's stable identity is
    /// the RFC 5322 Message-ID (migration 010 — a UID changes after MOVE).
    /// Resolving one to the other used to cost a `UID SEARCH HEADER` that
    /// QQ routinely answers empty, followed by a 501-message header scan
    /// — ~2 s on every body fetch, attachment download, markRead, archive
    /// and undo.
    ///
    /// A UID is stable for the lifetime of a UIDVALIDITY *within one mailbox*
    /// (RFC 3501 §2.3.1.1), so the mapping is safe to keep.
    /// `uidCacheIdentity` records which (mailbox, UIDVALIDITY) it was built
    /// against; a mismatch — a different folder, or a server-side mailbox
    /// rebuild — drops the whole map. `IMAPSelected` carries the folder name,
    /// so the check cannot be skipped by a code path that only remembers the
    /// number. The one expensive scan populates *every* mapping it sees, so
    /// opening a second message from the same window is free.
    private var uidByMessageID: [String: Int64] = [:]
    private var uidCacheIdentity: (mailbox: String, uidValidity: Int64)?
    /// Current INBOX membership, keyed by UID. The first round builds this map
    /// once; later rounds use `UID SEARCH ALL` to detect messages another
    /// client moved or deleted.
    private var inboxRemoteIdByUID: [Int64: String] = [:]
    private var inboxUIDs: Set<Int64> = []
    private var inboxIndexValid = false
    /// The archive role is account data, not connection state: it survives a
    /// reconnect (spec §4.3).
    private var archiveResolved = false
    private var archiveName: String?
    private var trashResolved = false
    private var trashName: String?
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
        db: LagoonDB?,
        logger: Logger,
        reconcilesInbox: Bool = true,
        transportFactory: @escaping @Sendable () -> any StreamTransport = {
            NIOSSLStreamTransport()
        }
    ) {
        self.kind = account.provider
        self.account = account
        self.db = db
        self.logger = logger
        self.reconcilesInbox = reconcilesInbox
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
            // A round that only harvested new sent Message-IDs still has to be
            // returned: dropping it here loses the reply signal and leaves the
            // persisted sent cursor behind, so the next round re-scans the same
            // 200-message Sent backfill forever.
            if !change.upserts.isEmpty || change.resetRequired
                || !change.repliedMessageIds.isEmpty {
                return change
            }
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { return change }
            if negotiated.contains("IDLE") {
                // Push: IDLE returns as soon as the *selected* mailbox moves,
                // so new mail is picked up within seconds instead of on the
                // next poll. The round above ends in `collectSentReplies`,
                // which SELECTs the Sent folder and clears `selected` — so
                // without this re-select we would sit in IDLE on Sent and
                // never learn about an arriving inbox message.
                try await withClient { client in
                    _ = try await selectInbox(client: client, force: true)
                    _ = try await client.idle(waitUpTo: min(remaining, Self.idleBudget))
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
                inboxRemoteIdByUID.removeAll(keepingCapacity: true)
                inboxUIDs.removeAll(keepingCapacity: true)
                inboxIndexValid = false
                return MailChangeSet(
                    upserts: [],
                    resetRequired: true,
                    cursor: MailSyncState(
                                    uidValidity: inbox.uidValidity,
                        lastUid: nil,
                        archiveFolder: archiveFolder
                    )
                )
            }

            var inboxRemoteIds: Set<String>?
            // First sync and post-reset rounds skip the membership reconcile:
            // the store has no rows yet, so there is nothing to subtract from.
            // The full index builds on the next round instead of delaying the
            // first paint.
            if reconcilesInbox, cursor.lastUid != nil {
                inboxRemoteIds = try await reconcileInboxMembership(
                    client: client,
                    exists: inbox.exists
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

            // One batched command per ≤100 UIDs (an empty round issues none).
            // A per-message snippet fetch here made a first backfill cost one
            // round trip per message on the strictly serial session — minutes
            // on a real mailbox, all before a single row reached the client.
            //
            // Previews are best-effort: the cursor is about to move past these
            // messages, so a failure that silently dropped the window would
            // leave every message in it without a preview, for good.
            let snippets: [Int64: Data]
            if fetched.isEmpty {
                snippets = [:]
            } else {
                do {
                    snippets = try await client.fetchTextSnippets(uids: fetched.map(\.uid))
                } catch {
                    // Refused chunks are already tolerated inside
                    // `fetchTextSnippets`; what arrives here cost us the
                    // socket, and a session that lost its socket must not keep
                    // reading — it is rebuilt on the next round.
                    await dropConnection()
                    logger.debug("imap.snippetsFailed", metadata: [
                        "label": .string(Self.label(error)),
                        "uids": .string("\(fetched.count)"),
                    ])
                    snippets = [:]
                }
            }
            var upserts: [RemoteHeader] = []
            upserts.reserveCapacity(fetched.count)
            for header in fetched {
                rememberInboxHeader(header)
                let remote = remoteHeader(from: header, snippet: Self.snippetText(from: snippets[header.uid]))
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
            if let ids = inboxRemoteIds {
                inboxRemoteIds = ids.union(upserts.map(\.remoteId))
            }
            // Cross-client reply detection (V2 A2): harvest threading
            // references from Sent mail. Best-effort — a Sent failure must
            // never fail the inbox round.
            let sent = await collectSentReplies(client: client, cursor: cursor)
            // A Sent UIDVALIDITY change kills every stored Sent UID, exactly as
            // an INBOX one does. Carrying the old high-water mark into the next
            // round would leave `baseUid` past the new folder's UIDNEXT and end
            // reply detection silently for good — so a rebase keeps only what
            // this round actually saw, and a failed harvest (nil validity)
            // keeps the stored value.
            let sentValidity = sent.validity ?? cursor.sentUidValidity
            let sentLastUid: Int64? = sent.validity == nil
                || sent.validity == cursor.sentUidValidity
                ? (sent.lastUid ?? cursor.sentLastUid)
                : sent.lastUid
            return MailChangeSet(
                upserts: upserts,
                resetRequired: false,
                cursor: MailSyncState(
                            uidValidity: inbox.uidValidity,
                    lastUid: nextLastUid,
                    archiveFolder: archiveFolder,
                    sentUidValidity: sentValidity,
                    sentLastUid: sentLastUid,
                    sentFolder: sent.folder ?? cursor.sentFolder
                ),
                inboxRemoteIds: inboxRemoteIds,
                repliedMessageIds: sent.ids
            )
        }
    }

    /// Harvest In-Reply-To/References Message-IDs from Sent-folder mail newer
    /// than the sent cursor. Sent mail is never stored as rows — only the
    /// threading references are returned, and the engine records them as reply
    /// signals. Runs inside the round's `withClient` session (no nested lock).
    /// The SELECT moves the session away from INBOX, so `selected` is cleared
    /// and the next INBOX access re-selects.
    private func collectSentReplies(
        client: IMAPClient,
        cursor: MailSyncState
    ) async -> (ids: Set<String>, validity: Int64?, lastUid: Int64?, folder: String?) {
        do {
            guard let folder = sentName else { return ([], nil, nil, nil) }
            let state = try await client.select(folder)
            selected = nil
            let validity = state.uidValidity
            // A Sent UIDVALIDITY change means every UID in the stored sent
            // cursor belongs to a dead identity space. Carrying the old
            // high-water mark forward is not merely useless: it is larger
            // than the whole new folder, so every later round would
            // short-circuit on `baseUid >= uidNext` and cross-client reply
            // detection would stop silently, with no way back. The INBOX
            // cursor is reset the same way (`round` above).
            let rebased = cursor.sentUidValidity != validity
            let carried: Int64? = rebased ? nil : cursor.sentLastUid
            if rebased, cursor.sentLastUid != nil {
                logger.warning("imap.sentUidValidityReset", metadata: [
                    "account": .string(account.email),
                    "folder": .string(folder),
                ])
            }
            let baseUid: Int64
            if let last = carried {
                baseUid = last + 1
            } else {
                // First scan or Sent UIDVALIDITY change: bounded window over
                // the new identity space.
                baseUid = max(1, state.uidNext - Self.sentBackfillWindow)
            }
            guard state.uidNext > baseUid || state.exists > 0 else {
                return ([], validity, carried, folder)
            }
            // Steady state with nothing new: skip the FETCH entirely.
            if carried != nil, baseUid >= state.uidNext {
                return ([], validity, carried, folder)
            }
            let headers = try await client.fetchHeaders(fromUid: baseUid)
            var ids = Set<String>()
            var maxUid = carried
            for header in headers {
                maxUid = max(maxUid ?? 0, header.uid)
                ids.formUnion(Self.threadReferenceIDs(rawHeaders: header.rawHeaders))
            }
            return (ids, validity, maxUid, folder)
        } catch {
            // Best-effort by design: Sent sync must never break inbox sync.
            // A refusal of the Sent commands is a verdict and the session
            // survives it, but a socket we cannot read is not something the
            // next command may keep using — drop it and rebuild next round.
            if !IMAPClient.isMessageVerdict(error) { await dropConnection() }
            logger.debug("imap.sentSkipped", metadata: ["label": .string(Self.label(error))])
            selected = nil
            return ([], nil, nil, nil)
        }
    }

    /// Message-IDs a sent message answers: its In-Reply-To plus every token
    /// in References. Pure function so the parsing is unit-testable without
    /// a wire session.
    static func threadReferenceIDs(rawHeaders: [String: String]) -> Set<String> {
        var ids = Set<String>()
        if let reply = rawHeaders["in-reply-to"], !reply.isEmpty {
            ids.formUnion(RemoteHeader.messageIDTokens(reply))
        }
        if let refs = rawHeaders["references"], !refs.isEmpty {
            ids.formUnion(RemoteHeader.messageIDTokens(refs))
        }
        return ids
    }

    /// Bounded `\Seen` rescan over already-known mail (spec §3.2 step 3).
    private func readStateFlips(client: IMAPClient, through lastUid: Int64) async throws -> [RemoteHeader] {
        let fromUid = max(1, lastUid - Self.flagRescanWindow + 1)
        let flags = try await client.fetchFlags(fromUid: fromUid, toUid: lastUid)

        var flipped: [Int64] = []
        for entry in flags {
            let isRead = Self.isRead(flags: entry.flags)
            guard let known = reportedRead[entry.uid], known != isRead else { continue }
            reportedRead[entry.uid] = isRead
            flipped.append(entry.uid)
        }
        guard !flipped.isEmpty else { return [] }
        // One command per ≤100 flipped UIDs, not one per flip: the session is
        // serial and `commandLock` is held for the whole scan, so a phone
        // marking 200 messages read would otherwise stall every other command
        // behind 200 round trips.
        //
        // The headers are needed for the identity the store is keyed on (the
        // Message-ID behind `remoteId`) and for `from_address`, which the
        // briefing classifier and the user's stack rules match on. The other
        // columns come back unchanged and the store protects them on conflict
        // anyway — the flip itself lands through the monotonic `is_read` OR.
        let headers = try await client.fetchHeaders(uids: flipped)
        return headers.map { remoteHeader(from: $0) }
    }

    // MARK: - Body & headers

    public func fetchBody(remoteId: String) async throws -> FetchedBody {
        // No local cache here: the route serves parsed bodies from the
        // durable BodyStore (V2 A3) and only calls this on a miss, so a
        // provider-level memory cache would just be a second copy.
        let raw = try await withClient { client in
            _ = try await selectInbox(client: client, force: false)
            let uid = try await resolveUID(remoteId, client: client)
            return try await client.fetchFullBody(uid: uid)
        }
        let parsed = MIMEParser.parse(message: raw)
        let body = FetchedBody(
            text: parsed.text,
            html: parsed.html,
            attachments: parsed.attachments.map {
                FetchedAttachment(
                    id: $0.id,
                    filename: $0.filename,
                    mimeType: $0.mimeType,
                    size: $0.size,
                    contentId: $0.contentId,
                    disposition: $0.disposition,
                    data: $0.data
                )
            },
            hasMore: parsed.hasMore,
            to: parsed.to,
            cc: parsed.cc
        )
        return body
    }

    public func fetchAttachment(remoteId: String, attachmentId: String) async throws -> FetchedAttachmentBytes {
        let raw = try await withClient { client in
            _ = try await selectInbox(client: client, force: false)
            let uid = try await resolveUID(remoteId, client: client)
            return try await client.fetchFullBody(uid: uid)
        }
        // The download route DOES need the bytes, so decode them here
        // (the body route skips this via the default false).
        let parsed = MIMEParser.parse(message: raw, decodeAttachmentBytes: true)
        guard let att = parsed.attachments.first(where: { $0.id == attachmentId }) else {
            throw AttachmentError.notFound
        }
        guard att.data.count <= AttachmentLimit.maxBytes else {
            throw AttachmentError.tooLarge
        }
        // Attachment bytes always come off the wire; metadata staleness is a
        // non-issue because bodies are immutable and the store row is keyed
        // on the same stable remoteId.
        return FetchedAttachmentBytes(
            mimeType: att.mimeType,
            filename: att.filename,
            data: att.data
        )
    }

    public func fetchRawMessage(remoteId: String) async throws -> Data {
        return try await withClient { client in
            _ = try await selectInbox(client: client, force: false)
            let uid = try await resolveUID(remoteId, client: client)
            return try await client.fetchFullBody(uid: uid)
        }
    }

    public func fetchRawHeaderValues(remoteId: String) async throws -> [String: String] {
        return try await withClient { client in
            _ = try await selectInbox(client: client, force: false)
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
            _ = try await selectInbox(client: client, force: false)
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
            _ = try await selectInbox(client: client, force: false)
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
        let preset = ProviderPresets.imap()
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
            _ = try await selectInbox(client: client, force: true)
        }
    }

    /// Hand the session back before the caller drops its last reference. A
    /// dropped `IMAPProvider` cannot do this itself: the read pump under the
    /// TLS transport keeps the socket authenticated on the server until its own
    /// idle timeout, and QQ caps concurrent sessions per account.
    public func shutdown() async {
        await dropConnection()
    }

    // MARK: - Connection lifecycle

    /// Run one command sequence on a live session. Failures are mapped to the
    /// provider-neutral surface, and the session is rebuilt on the next call
    /// unless the error is a verdict about the message rather than the socket.
    private func withClient<T>(_ body: (IMAPClient) async throws -> T) async throws -> T {
        await commandLock.lock()
        // `AsyncMutex.lock()` has no cancellation check, so a caller that was
        // cancelled while queued still acquires the lock and then trips
        // `checkCancellation` below. Track whether a command was actually
        // started: the wire is provably untouched before that point, and
        // tearing the shared session down for a cancellation that never sent
        // anything would cost every other caller a full reconnect.
        var issuedCommand = false
        do {
            try Task.checkCancellation()
            let client = try await connectedClient()
            issuedCommand = true
            let result = try await body(client)
            await commandLock.unlock()
            return result
        } catch let error as MailError where error == .messageGone {
            // The verdict is about the message, not the socket, so the session
            // survives — but the body may have SELECTed away from INBOX on its
            // way to discovering the message is gone (`unarchive` selects the
            // Archive folder first). Leaving `selected` set would make the
            // next `UID STORE` run against the wrong mailbox.
            selected = nil
            await commandLock.unlock()
            throw error
        } catch is CancellationError {
            // Cancelled mid-command: the server may still owe us a tagged
            // completion, so the session cannot be reused.
            if issuedCommand { await dropConnection() }
            await commandLock.unlock()
            throw CancellationError()
        } catch {
            await dropConnection()
            await commandLock.unlock()
            throw Self.map(error)
        }
    }

    private func connectedClient() async throws -> IMAPClient {
        if let client { return client }
        let credentials = try await imapCredentials()
        let preset = ProviderPresets.imap()
        let connection = IMAPConnection(transport: transportFactory(), logger: logger)
        let client = IMAPClient(connection: connection, logger: logger)
        do {
            try await client.connect(host: preset.imapHost, port: preset.imapPort)
            try await client.login(username: credentials.username, authCode: credentials.authCode)
            try await client.sendID()
            negotiated = try await client.capability()
        } catch {
            // A session that already failed on the socket must not then spend
            // the full read timeout waiting for a LOGOUT reply that is never
            // coming — that is 30 s holding `commandLock` and a socket nobody
            // gets back, on top of the sync loop's backoff. Only a server that
            // is still talking gets the courtesy round trip.
            if IMAPClient.isMessageVerdict(error) {
                await client.logout()
            } else {
                await client.disconnect()
            }
            throw Self.map(error)
        }
        self.client = client
        selected = nil
        return client
    }

    /// Tear the session down. The socket is closed rather than abandoned:
    /// `NIOSSLStreamTransport` keeps its read pump alive in a `Task` that
    /// captures the transport, so simply dropping the `IMAPClient` reference
    /// leaks the TLS connection, the NIO channel and the file descriptor. QQ
    /// caps concurrent IMAP sessions per account, so a few abandoned sockets
    /// are enough to start getting `NO` — which would leak more of them.
    private func dropConnection() async {
        let dead = client
        client = nil
        selected = nil
        await dead?.disconnect()
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
        // The folder name is part of the check: `selected` may name the
        // Archive or Trash folder after a move, and a UID from one of those
        // means nothing in INBOX.
        if !force, let selected, selected.mailbox == Self.inboxName { return selected }
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
            } catch {
                // A refusal is a verdict about the folder and is remembered.
                // A dead socket says nothing about whether this server has an
                // archive folder, and latching "unavailable" from a blip would
                // turn archiving off for the whole life of this provider — so
                // that error travels out and the round retries the CREATE.
                guard IMAPClient.isMessageVerdict(error) else { throw error }
                logger.warning(
                    "imap.archive.createRefused",
                    metadata: ["label": .string(Self.label(error))]
                )
                archiveName = nil
            }
        }
        archiveResolved = true
        // Piggyback the Sent role on the same LIST: the sync round needs the
        // Sent folder every round for reply detection, and a second LIST per
        // round would double the command cost (V2 A2).
        if !sentResolved {
            sentName = mailboxes.first(where: { Self.isSentMailbox($0) })?.name
            sentResolved = true
        }
        return archiveName
    }

    /// Resolve the Trash role once per provider: SPECIAL-USE `\Trash` or a
    /// well-known name. Unlike the archive role there is NO create fallback —
    /// inventing a "Trash" folder on a server that has none would fake the
    /// delete semantics; the route answers 409 delete-unavailable instead.
    private func resolveTrashFolder(client: IMAPClient) async throws -> String? {
        if trashResolved { return trashName }
        let mailboxes = try await client.listMailboxes()
        if let special = mailboxes.first(where: { mailbox in
            mailbox.attributes.contains { $0.caseInsensitiveCompare("\\Trash") == .orderedSame }
        }) {
            trashName = special.name
        } else if let named = mailboxes.first(where: { mailbox in
            ["trash", "deleted", "deleted messages", "deleted items", "已删除", "已删除邮件"]
                .contains(mailbox.name.lowercased())
        }) {
            trashName = named.name
        }
        trashResolved = true
        return trashName
    }

    public func trash(remoteId: String) async throws {
        try await withClient { client in
            guard let folder = try await resolveTrashFolder(client: client) else {
                throw MailError.trashUnavailable
            }
            _ = try await selectInbox(client: client, force: false)
            let uid = try await resolveUID(remoteId, client: client)
            try await move(client: client, uid: uid, to: folder)
        }
    }

    public func restoreFromTrash(remoteId: String) async throws {
        try await withClient { client in
            guard let folder = try await resolveTrashFolder(client: client) else {
                throw MailError.trashUnavailable
            }
            selected = try await client.select(folder)
            let trashedUID = try await resolveUID(remoteId, client: client)
            try await move(client: client, uid: trashedUID, to: Self.inboxName)
            selected = nil
        }
    }

    private static func isSentMailbox(_ mailbox: IMAPMailbox) -> Bool {
        mailbox.attributes.contains {
            $0.caseInsensitiveCompare("\\Sent") == .orderedSame
        } || ["sent", "sent messages", "已发送", "已发送邮件"].contains(
            mailbox.name.lowercased()
        )
    }

    private func resolveSentFolder() async throws -> String? {
        if sentResolved { return sentName }
        return try await withClient { client in
            let mailboxes = try await client.listMailboxes()
            sentName = mailboxes.first(where: { Self.isSentMailbox($0) })?.name
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

    /// Record one INBOX header in both the UID→remote-ID reconciliation index
    /// and the Message-ID→UID lookup cache.
    private func rememberInboxHeader(_ fetched: IMAPFetchedHeader) {
        let messageID = fetched.rawHeaders["message-id"].flatMap {
            $0.isEmpty ? nil : MIMEParser.decodeRFC2047($0)
        }
        let remoteId = messageID ?? "uid:\(fetched.uid)"
        inboxRemoteIdByUID[fetched.uid] = remoteId
        uidByMessageID[remoteId] = fetched.uid
    }

    /// Build the complete INBOX identity view once, then reconcile it on every
    /// round with `UID SEARCH ALL`. Returning nil means the server did not
    /// provide a trustworthy complete view, so the store must not delete rows.
    private func reconcileInboxMembership(
        client: IMAPClient,
        exists: Int
    ) async throws -> Set<String>? {
        if !inboxIndexValid {
            let headers = try await client.fetchHeaders(fromUid: 1)
            inboxRemoteIdByUID.removeAll(keepingCapacity: true)
            uidByMessageID.removeAll(keepingCapacity: true)
            for header in headers {
                rememberInboxHeader(header)
            }
            inboxUIDs = Set(inboxRemoteIdByUID.keys)
            inboxIndexValid = true
        }

        let currentUIDs = try await client.allUIDs()
        // A successful search over a non-empty mailbox cannot legitimately be
        // empty. Treat that as an incomplete server answer and skip deletion.
        guard !currentUIDs.isEmpty || exists == 0 else { return nil }

        let vanished = inboxUIDs.subtracting(currentUIDs)
        for uid in vanished {
            if let remoteId = inboxRemoteIdByUID.removeValue(forKey: uid) {
                uidByMessageID[remoteId] = nil
            }
            reportedRead[uid] = nil
        }
        inboxUIDs = currentUIDs

        let unmapped = currentUIDs.filter { inboxRemoteIdByUID[$0] == nil }
        if let firstUnmapped = unmapped.min() {
            let headers = try await client.fetchHeaders(fromUid: firstUnmapped)
            for header in headers where currentUIDs.contains(header.uid) {
                rememberInboxHeader(header)
            }
        }
        return Set(currentUIDs.compactMap { inboxRemoteIdByUID[$0] })
    }

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
            unsubscribeLinks: UnsubscribeScanner.headerLinks(decoded("list-unsubscribe") ?? ""),
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
        // Cache: the same Message-ID resolves to the same UID for the whole
        // lifetime of the selected mailbox's UIDVALIDITY. Drop the map when
        // the selection moved to another folder or the mailbox was rebuilt.
        if let selected {
            let identity = (mailbox: selected.mailbox, uidValidity: selected.uidValidity)
            if uidCacheIdentity?.mailbox != identity.mailbox
                || uidCacheIdentity?.uidValidity != identity.uidValidity {
                uidByMessageID.removeAll(keepingCapacity: true)
                uidCacheIdentity = identity
            }
            if let cached = uidByMessageID[remoteId] {
                return cached
            }
        }
        if let uid = try await client.searchUID(messageID: remoteId) {
            uidByMessageID[remoteId] = uid
            return uid
        }
        // QQ accepts HEADER SEARCH but can return an empty set even when the
        // header is present (and for older messages it always does). Scan
        // the recent window once and remember *every* mapping it yields —
        // the next open from the same window is then a dictionary hit.
        if let selected {
            let fromUid = max(1, selected.uidNext - 501)
            let headers = try await client.fetchHeaders(fromUid: fromUid)
            for header in headers {
                guard let messageID = header.rawHeaders["message-id"],
                      !messageID.isEmpty
                else { continue }
                uidByMessageID[messageID] = header.uid
            }
            if let match = uidByMessageID[remoteId] {
                return match
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
