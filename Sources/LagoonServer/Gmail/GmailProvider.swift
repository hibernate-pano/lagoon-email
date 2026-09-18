import Foundation
import Logging
import LagoonKit

/// Gmail REST-backed `MailProvider` — the M0 `GmailPoller` turned into a
/// per-account provider.
///
/// The wire behaviour is deliberately unchanged: `messages.list` (last 50) →
/// bounded-concurrent `messages.get?format=metadata` → header mapping, with the
/// same refresh-once/retry-once credential handling. What changed is who owns
/// the state: this type no longer writes to Postgres, it reports what changed
/// and `SyncEngine` persists it (spec §2.4 — the cursor is only persisted after
/// a successful write).
public actor GmailProvider: MailProvider {
    /// `messages.get` calls in flight at once. A metadata get costs 5 quota
    /// units against Gmail's ~250 units/s/user budget, so 8 concurrent calls
    /// stay inside quota while cutting a 50-message poll from ~50 serial
    /// round-trips to ~7 batches.
    static let fetchConcurrency = 8

    /// M0 poll cadence: a pull blocks in `waitUpTo` and re-polls every 30s.
    static let pollInterval: Duration = .seconds(30)

    public let kind: MailProviderKind = .gmail

    private let account: Account
    private let client: GmailClient
    private let tokens: GmailTokenService
    private let logger: Logger

    /// Fingerprints (`"<id>:<u|r>"`) of the previous poll. Without it every
    /// pull would re-report the same last-50 messages, the change set would
    /// never be empty, and `SyncEngine` would spin instead of blocking. The
    /// provider must therefore outlive one tick — `SyncEngine` caches instances
    /// per account.
    private var lastSeen: Set<String> = []

    public init(
        account: Account,
        client: GmailClient,
        tokens: GmailTokenService,
        logger: Logger
    ) {
        self.account = account
        self.client = client
        self.tokens = tokens
        self.logger = logger
    }

    public func capabilities() async -> MailCapabilities {
        // Gmail is REST: no IDLE (webhook fanout replaces it later), archiving
        // is just dropping the INBOX label, and snippets come from the server.
        MailCapabilities(archiveFolder: true, idle: false, move: true, serverSnippet: true)
    }

    // MARK: - Pull

    public func pullChanges(
        after cursor: MailSyncState,
        waitUpTo: Duration
    ) async throws -> MailChangeSet {
        let deadline = ContinuousClock.now.advanced(by: waitUpTo)
        // Gmail's incremental cursor is not used yet (same as M0): the sync is
        // a re-read of the last 50 messages, so the cursor round-trips.
        let next = MailSyncState(
            historyId: cursor.historyId,
            uidValidity: cursor.uidValidity,
            lastUid: cursor.lastUid,
            archiveFolder: cursor.archiveFolder
        )
        while true {
            let raw = try await fetchLatest()
            let changed = changes(from: raw)
            if !changed.isEmpty {
                return MailChangeSet(upserts: changed, resetRequired: false, cursor: next)
            }
            // Only block when a full interval is left; a shorter `waitUpTo`
            // means "one non-blocking poll". Nothing is lost by returning
            // early: SyncEngine pulls again immediately.
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining >= Self.pollInterval else {
                return MailChangeSet(upserts: [], resetRequired: false, cursor: next)
            }
            try await Task.sleep(for: Self.pollInterval)
        }
    }

    /// One `messages.list` + metadata fetch round, capped at the same 50-message
    /// window M0 polled.
    private func fetchLatest() async throws -> [RawGmailMessage] {
        try await perform { token in
            let list = try await self.client.listMessageRefs(
                accessToken: token,
                maxResults: 50
            )
            let ids = Array((list.messages ?? []).prefix(50).map(\.id))
            guard !ids.isEmpty else { return [] }
            return try await Self.fetchAll(ids: ids, client: self.client, accessToken: token)
        }
    }

    /// Fetch metadata in bounded concurrent batches. Responses arrive in
    /// completion order; the store is keyed by remote id, so order is irrelevant.
    private static func fetchAll(
        ids: [String],
        client: GmailClient,
        accessToken: String
    ) async throws -> [RawGmailMessage] {
        var fetched: [RawGmailMessage] = []
        fetched.reserveCapacity(ids.count)
        for start in stride(from: 0, to: ids.count, by: fetchConcurrency) {
            let batch = Array(ids[start..<min(start + fetchConcurrency, ids.count)])
            let responses = try await withThrowingTaskGroup(of: RawGmailMessage.self) { group in
                for id in batch {
                    group.addTask {
                        try await client.getMessage(accessToken: accessToken, remoteId: id)
                    }
                }
                var collected: [RawGmailMessage] = []
                for try await response in group { collected.append(response) }
                return collected
            }
            fetched.append(contentsOf: responses)
        }
        return fetched
    }

    /// Diff one poll against the previous one and refresh the baseline. Returns
    /// only new messages and messages whose read state flipped; the rest is
    /// already in the store.
    private func changes(from raw: [RawGmailMessage]) -> [RemoteHeader] {
        var seen = Set<String>()
        seen.reserveCapacity(raw.count)
        var changed: [RemoteHeader] = []
        for message in raw {
            let fingerprint = Self.fingerprint(message)
            seen.insert(fingerprint)
            if !lastSeen.contains(fingerprint) {
                changed.append(Self.remoteHeader(from: message, accountId: account.id))
            }
        }
        lastSeen = seen
        return changed
    }

    private static func fingerprint(_ raw: RawGmailMessage) -> String {
        let unread = (raw.labelIds ?? []).contains("UNREAD")
        return "\(raw.id):\(unread ? "u" : "r")"
    }

    /// Map a Gmail metadata response onto the provider-neutral header row.
    static func remoteHeader(from raw: RawGmailMessage, accountId: UUID) -> RemoteHeader {
        func header(_ name: String) -> String? {
            guard let value = raw.payload?.headers?
                .first(where: { $0.name.lowercased() == name })?
                .value,
                !value.isEmpty else { return nil }
            return value
        }
        let (address, name) = FromHeader.parse(header("from") ?? "")
        let receivedAt = raw.internalDate.flatMap { Int64($0) }
            .map { Date(timeIntervalSince1970: TimeInterval($0) / 1000.0) } ?? Date()
        return RemoteHeader(
            remoteId: raw.id,
            threadId: raw.threadId,
            fromAddress: address,
            fromName: name,
            subject: header("subject"),
            snippet: raw.snippet,
            receivedAt: receivedAt,
            isRead: !(raw.labelIds ?? []).contains("UNREAD"),
            listUnsubscribe: hasListUnsubscribe(raw),
            messageIdHeader: header("message-id"),
            inReplyTo: header("in-reply-to"),
            references: header("references")
        )
    }

    /// Presence of a non-empty List-Unsubscribe header on the metadata response.
    static func hasListUnsubscribe(_ raw: RawGmailMessage) -> Bool {
        raw.payload?.headers?.contains {
            $0.name.lowercased() == "list-unsubscribe"
                && !$0.value.trimmingCharacters(in: .whitespaces).isEmpty
        } ?? false
    }

    // MARK: - Body & headers

    /// M1.6: returns plain text + html + attachment metadata. Attachment
    /// `data` is empty for Gmail because attachments come from a separate
    /// `attachments.get` call — `fetchAttachment(remoteId:attachmentId:)`
    /// does that work and returns the bytes.
    public func fetchBody(remoteId: String) async throws -> FetchedBody {
        // M1.6 cache hit avoids the full Gmail message fetch when the
        // user re-opens an email inside the 60s window.
        if let cached = await MessageBodyCache.shared.get(
            accountId: account.id, remoteId: remoteId
        ) {
            return cached
        }
        let raw = try await perform { token in
            try await self.client.getMessageFull(accessToken: token, remoteId: remoteId)
        }
        let body = GmailBodyExtractor.fetchedBody(from: raw.payload)
        await MessageBodyCache.shared.put(body, accountId: account.id, remoteId: remoteId)
        return body
    }

    /// Fetch one attachment's bytes by Gmail `body.attachmentId`. The
    /// `metadata` arg is the matching `FetchedAttachment` from the body
    /// response — we use it for mimeType and filename without re-walking
    /// the message tree.
    public func fetchAttachment(remoteId: String, attachmentId: String) async throws -> FetchedAttachmentBytes {
        let raw = try await perform { token in
            try await self.client.getAttachment(
                accessToken: token, messageId: remoteId, attachmentId: attachmentId
            )
        }
        guard let data = GmailBodyExtractor.base64URLDecode(raw.data) else {
            throw MailError.protocolError("gmail attachment decode failed")
        }
        guard data.count <= AttachmentLimit.maxBytes else {
            throw AttachmentError.tooLarge
        }
        // We need filename + mimeType for Content-Type / Content-Disposition.
        // Re-fetch the message metadata to fish out the part; on a hot path
        // this is wasteful, but the user's Gmail account is not high-volume
        // and the next M1.6.x pass can cache.
        let body = try await fetchBody(remoteId: remoteId)
        guard let att = body.attachments.first(where: { $0.id == attachmentId }) else {
            throw AttachmentError.notFound
        }
        return FetchedAttachmentBytes(mimeType: att.mimeType, filename: att.filename, data: data)
    }

    /// Raw RFC 5322 bytes. `format=raw` returns a base64url-encoded string
    /// in the Gmail API; we decode and hand the raw bytes back.
    public func fetchRawMessage(remoteId: String) async throws -> Data {
        let raw = try await perform { token in
            try await self.client.getMessageRaw(accessToken: token, remoteId: remoteId)
        }
        guard let data = GmailBodyExtractor.base64URLDecode(raw.raw) else {
            throw MailError.protocolError("gmail raw message decode failed")
        }
        return data
    }

    public func fetchRawHeaderValues(remoteId: String) async throws -> [String: String] {
        let raw = try await perform { token in
            try await self.client.getMessage(accessToken: token, remoteId: remoteId)
        }
        var values: [String: String] = [:]
        for header in raw.payload?.headers ?? [] {
            values[header.name.lowercased()] = header.value
        }
        return values
    }

    // MARK: - Mutations

    public func setRead(remoteId: String, isRead: Bool) async throws {
        try await perform { token in
            try await self.client.modifyMessageLabels(
                accessToken: token,
                remoteId: remoteId,
                addLabelIds: isRead ? [] : ["UNREAD"],
                removeLabelIds: isRead ? ["UNREAD"] : []
            )
        }
    }

    public func archive(remoteId: String) async throws {
        try await perform { token in
            try await self.client.modifyMessageLabels(
                accessToken: token,
                remoteId: remoteId,
                removeLabelIds: ["INBOX"]
            )
        }
    }

    public func unarchive(remoteId: String) async throws {
        try await perform { token in
            try await self.client.modifyMessageLabels(
                accessToken: token,
                remoteId: remoteId,
                addLabelIds: ["INBOX"]
            )
        }
    }

    /// Same wire format as the IMAP path: one `MIMEBuilder` message, uploaded
    /// through the Gmail `raw` endpoint. Gmail threads on the References chain
    /// in the message itself, so no threadId is needed.
    public func send(_ outbound: OutboundMessage) async throws -> String? {
        let messageId = "<\(UUID().uuidString.lowercased())@lagoon>"
        let message = outbound.isReply
            ? MIMEBuilder.reply(outbound, messageId: messageId)
            : MIMEBuilder.newMessage(outbound, messageId: messageId)
        // MIMEBuilder output is pure ASCII (base64 body, encoded-word headers).
        let raw = String(decoding: message, as: UTF8.self)
        return try await perform { token in
            try await self.client.sendMessage(
                accessToken: token,
                threadId: nil,
                rawRFC822: raw
            )
        }
    }

    public func probe() async throws {
        _ = try await perform { token in
            try await self.client.getProfileEmail(accessToken: token)
        }
    }

    // MARK: - Credentials & error mapping

    /// Run one Gmail call under the shared credential policy: proactive refresh
    /// when near expiry, refresh-once/retry-once on a 401, and `authFailed`
    /// when a token that was just refreshed is *still* rejected (spec §3.4 —
    /// auth failures must not be fast-retried).
    private func perform<T>(_ body: (String) async throws -> T) async throws -> T {
        let token: GmailTokenService.Token
        do {
            token = try await tokens.validToken(for: account)
        } catch {
            throw fail(error)
        }
        do {
            return try await body(token.accessToken)
        } catch GmailClientError.unauthorized {
            // If we refreshed moments ago, the stored refresh token is not the
            // problem: the credential itself is dead, so ask for a reconnect.
            guard !token.didRefresh else { throw MailError.authFailed }
            do {
                let refreshed = try await tokens.forceRefresh(for: account)
                return try await body(refreshed)
            } catch {
                throw fail(error)
            }
        } catch {
            throw fail(error)
        }
    }

    /// Map a wire error onto the provider-neutral surface, logging only the
    /// stable label: payloads (Google error text, mail content) stay out of
    /// logs and never reach `last_sync_error` (spec §5.2).
    private func fail(_ error: Error) -> Error {
        let mapped = Self.map(error)
        let label = (mapped as? MailError)?.logLabel ?? "\(type(of: error))"
        logger.warning("gmail call failed", metadata: ["label": .string(label)])
        return mapped
    }

    static func map(_ error: Error) -> Error {
        if error is CancellationError { return error }
        if let mail = error as? MailError { return mail }
        if let gmail = error as? GmailClientError {
            switch gmail {
            case .unauthorized:
                return MailError.authFailed
            case .http(let status, _):
                return status == 404
                    ? MailError.messageGone
                    : MailError.protocolError("gmail http \(status)")
            }
        }
        if let oauth = error as? OAuthClientError {
            switch oauth {
            case .http(let status, let body):
                // `invalid_grant`: the refresh token was revoked or reset.
                if body.contains("invalid_grant") { return MailError.authFailed }
                return MailError.unreachable("oauth http \(status)")
            case .missingRefreshToken:
                return MailError.authFailed
            }
        }
        if error is GmailTokenError {
            return MailError.notConfigured("gmail credentials missing")
        }
        if error is AccountStoreError {
            return MailError.notConfigured("account row missing")
        }
        if error is DecodingError {
            return MailError.protocolError("gmail response shape")
        }
        if let url = error as? URLError {
            return MailError.unreachable("gmail net \(url.code.rawValue)")
        }
        return MailError.unreachable("gmail \(type(of: error))")
    }
}
