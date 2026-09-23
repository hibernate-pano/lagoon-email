import Foundation
import LagoonKit

/// Provider-neutral header row as it arrives from the wire, before it becomes a
/// stored `MessageHeader`. `remoteId` is provider-native (Gmail message id /
/// IMAP UID string) and only unique within one account.
public extension RemoteHeader {
    /// Split a threading header (In-Reply-To/References) into whitespace-
    /// separated tokens, verbatim. Tokens keep their `<...>` brackets: the
    /// store's Message-ID identity is the exact header string, so stripping
    /// brackets would break the match. Shared by the IMAP and Gmail Sent
    /// harvesters.
    static func messageIDTokens(_ value: String) -> Set<String> {
        Set(
            value.split(whereSeparator: { $0.isWhitespace })
                .map(String.init)
                .filter { !$0.isEmpty }
        )
    }
}
public struct RemoteHeader: Sendable, Equatable {
    public var remoteId: String
    public var threadId: String
    public var fromAddress: String
    public var fromName: String?
    public var subject: String?
    public var snippet: String?
    public var receivedAt: Date
    public var isRead: Bool
    public var listUnsubscribe: Bool
    public var messageIdHeader: String?
    public var inReplyTo: String?
    public var references: String?

    public init(
        remoteId: String,
        threadId: String,
        fromAddress: String,
        fromName: String? = nil,
        subject: String? = nil,
        snippet: String? = nil,
        receivedAt: Date,
        isRead: Bool,
        listUnsubscribe: Bool = false,
        messageIdHeader: String? = nil,
        inReplyTo: String? = nil,
        references: String? = nil
    ) {
        self.remoteId = remoteId
        self.threadId = threadId
        self.fromAddress = fromAddress
        self.fromName = fromName
        self.subject = subject
        self.snippet = snippet
        self.receivedAt = receivedAt
        self.isRead = isRead
        self.listUnsubscribe = listUnsubscribe
        self.messageIdHeader = messageIdHeader
        self.inReplyTo = inReplyTo
        self.references = references
    }
}

/// One pull's worth of change. `resetRequired` means the provider's identity
/// space changed (IMAP UIDVALIDITY) and the store must be wiped first.
public struct MailChangeSet: Sendable {
    public var upserts: [RemoteHeader]
    public var resetRequired: Bool
    public var cursor: MailSyncState
    /// When non-nil, this is the complete set of provider IDs currently in the
    /// source mailbox. The store removes any non-archived local row for this
    /// account that is absent from the set. IMAP uses it to reconcile mail
    /// moved or deleted by another client; providers without a cheap complete
    /// view leave it nil.
    public var inboxRemoteIds: Set<String>?
    /// Message-IDs (RFC 5322) this pull saw referenced from sent mail
    /// (In-Reply-To/References of Sent-folder messages). The engine records
    /// them as reply signals so mail answered from another client leaves
    /// "needs reply" (V2 A2). Sent mail itself is never stored as rows.
    public var repliedMessageIds: Set<String>

    public init(
        upserts: [RemoteHeader],
        resetRequired: Bool,
        cursor: MailSyncState,
        inboxRemoteIds: Set<String>? = nil,
        repliedMessageIds: Set<String> = []
    ) {
        self.upserts = upserts
        self.resetRequired = resetRequired
        self.cursor = cursor
        self.inboxRemoteIds = inboxRemoteIds
        self.repliedMessageIds = repliedMessageIds
    }
}

/// A message to send. `inReplyTo`/`references` are the RFC 5322 header values
/// (already bracketed) threaded from the message being replied to.
public struct OutboundMessage: Sendable {
    public var fromEmail: String
    public var fromName: String?
    /// Primary recipients, comma-joined into a single `To:` header. A
    /// reply-to-one passes one address; reply-all passes the sender plus
    /// every other `To` (minus self, minus the Cc set to avoid duplicates).
    public var to: String
    /// Carbon-copy recipients. Empty means the `Cc:` header is omitted
    /// entirely rather than emitted blank.
    public var cc: [String]
    public var subject: String
    public var body: String
    public var inReplyTo: String?
    public var references: String?
    /// New-message sends keep the subject exactly as typed; replies add the
    /// de-duplicated `Re:` prefix.
    public var isReply: Bool

    public init(
        fromEmail: String,
        fromName: String?,
        to: String,
        cc: [String] = [],
        subject: String,
        body: String,
        inReplyTo: String?,
        references: String?,
        isReply: Bool = true
    ) {
        self.fromEmail = fromEmail
        self.fromName = fromName
        self.to = to
        self.cc = cc
        self.subject = subject
        self.body = body
        self.inReplyTo = inReplyTo
        self.references = references
        self.isReply = isReply
    }

    /// Split a comma-separated `To:` string back into addresses. Used by
    /// the route when it needs the recipient count for validation.
    public var recipientAddresses: [String] {
        to.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

/// Typed provider failures. `.authFailed` is special: the sync loop stops
/// retrying and asks the user to re-enter credentials.
public enum MailError: Error, Equatable {
    case authFailed
    case unreachable(String)
    case protocolError(String)
    case messageGone
    case archiveUnavailable
    case notConfigured(String)

    /// Stable, log-safe label (never interpolate payloads into user-facing text).
    public var logLabel: String {
        switch self {
        case .authFailed: return "auth-failed"
        case .unreachable: return "unreachable"
        case .protocolError: return "protocol-error"
        case .messageGone: return "message-gone"
        case .archiveUnavailable: return "archive-unavailable"
        case .notConfigured: return "not-configured"
        }
    }
}

/// A provider whose archive target is a server-side folder (IMAP). The connect
/// flow persists the resolved name into the account's sync cursor so the undo
/// route can move a message back without re-listing folders.
public protocol ArchiveFolderResolving: Sendable {
    /// The resolved remote archive mailbox, `nil` when the server has none.
    func archiveFolder() async -> String?
}

/// The one seam every mailbox backend implements. Routes and the sync engine
/// talk to this, never to Gmail/IMAP directly.
public protocol MailProvider: Sendable {
    var kind: MailProviderKind { get }

    /// Negotiated once after connect and cached on the account row.
    func capabilities() async -> MailCapabilities

    /// Fetch changes newer than `cursor`, waiting up to `waitUpTo` for
    /// something to happen (long-poll for Gmail, IDLE for IMAP).
    func pullChanges(after cursor: MailSyncState, waitUpTo: Duration) async throws -> MailChangeSet

    /// Body on demand: plain text, optional HTML, attachment metadata +
    /// decoded bytes, and a truncation flag (M1.6).
    func fetchBody(remoteId: String) async throws -> FetchedBody

    /// One attachment's raw bytes by its provider-native id. Throws
    /// `MailError.messageGone` if the message or attachment no longer exists.
    /// Throws `LagoonServer.AttachmentTooLarge` if the bytes exceed the
    /// server's per-attachment cap (currently 25 MB).
    func fetchAttachment(remoteId: String, attachmentId: String) async throws -> FetchedAttachmentBytes

    /// Original RFC 5322 message bytes (for `.eml` export). Implementations
    /// may re-fetch the body; the user picked "every fetch on demand" so
    /// there's no server-side cache.
    func fetchRawMessage(remoteId: String) async throws -> Data

    /// Raw header values for one message (e.g. List-Unsubscribe at click time).
    func fetchRawHeaderValues(remoteId: String) async throws -> [String: String]

    func setRead(remoteId: String, isRead: Bool) async throws
    func archive(remoteId: String) async throws
    func unarchive(remoteId: String) async throws

    /// Returns the provider-assigned Message-ID when it reports one.
    func send(_ outbound: OutboundMessage) async throws -> String?

    /// Connectivity + credential check used by the connect flow.
    func probe() async throws
}

/// Provider-internal body shape (M1.6). `attachments[i].data` is the
/// decoded bytes — stripped before the wire response goes out, since the
/// client fetches each attachment through the dedicated route.
public struct FetchedBody: Sendable, Equatable {
    public var text: String
    public var html: String?
    public var attachments: [FetchedAttachment]
    public var hasMore: Bool
    /// Recipient addresses from the message's `To:` header. Reply-all
    /// needs these; before M1.7 the wire `toAddress` was hardcoded nil.
    public var to: [String]
    /// Recipient addresses from the message's `Cc:` header.
    public var cc: [String]

    public init(
        text: String,
        html: String?,
        attachments: [FetchedAttachment],
        hasMore: Bool,
        to: [String] = [],
        cc: [String] = []
    ) {
        self.text = text
        self.html = html
        self.attachments = attachments
        self.hasMore = hasMore
        self.to = to
        self.cc = cc
    }
}

public struct FetchedAttachment: Sendable, Equatable {
    public var id: String
    public var filename: String?
    public var mimeType: String
    public var size: Int
    public var contentId: String?
    public var disposition: Attachment.Disposition
    public var data: Data

    public init(
        id: String,
        filename: String?,
        mimeType: String,
        size: Int,
        contentId: String?,
        disposition: Attachment.Disposition,
        data: Data
    ) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.size = size
        self.contentId = contentId
        self.disposition = disposition
        self.data = data
    }

    /// Strip the byte payload before sending over the wire. The client
    /// re-fetches the bytes via `GET /api/messages/{id}/attachments/{aid}`.
    public func toWire() -> Attachment {
        Attachment(
            id: id,
            filename: filename,
            mimeType: mimeType,
            size: size,
            contentId: contentId,
            disposition: disposition
        )
    }
}

/// The bytes for a single attachment, plus the metadata needed to set
/// Content-Type / Content-Disposition correctly on the way out.
public struct FetchedAttachmentBytes: Sendable, Equatable {
    public var mimeType: String
    public var filename: String?
    public var data: Data

    public init(mimeType: String, filename: String?, data: Data) {
        self.mimeType = mimeType
        self.filename = filename
        self.data = data
    }
}

/// Single-attachment response cap. Gmail caps at 25 MB, so we use the
/// same number for IMAP to give the client a uniform UX.
public enum AttachmentLimit {
    public static let maxBytes = 25 * 1024 * 1024
}

public enum AttachmentError: Error, Equatable {
    case tooLarge
    case notFound
}
