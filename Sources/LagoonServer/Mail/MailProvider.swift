import Foundation
import LagoonKit

/// Provider-neutral header row as it arrives from the wire, before it becomes a
/// stored `MessageHeader`. `remoteId` is provider-native (Gmail message id /
/// IMAP UID string) and only unique within one account.
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

    public init(upserts: [RemoteHeader], resetRequired: Bool, cursor: MailSyncState) {
        self.upserts = upserts
        self.resetRequired = resetRequired
        self.cursor = cursor
    }
}

/// A message to send. `inReplyTo`/`references` are the RFC 5322 header values
/// (already bracketed) threaded from the message being replied to.
public struct OutboundMessage: Sendable {
    public var fromEmail: String
    public var fromName: String?
    public var to: String
    public var subject: String
    public var body: String
    public var inReplyTo: String?
    public var references: String?

    public init(
        fromEmail: String,
        fromName: String?,
        to: String,
        subject: String,
        body: String,
        inReplyTo: String?,
        references: String?
    ) {
        self.fromEmail = fromEmail
        self.fromName = fromName
        self.to = to
        self.subject = subject
        self.body = body
        self.inReplyTo = inReplyTo
        self.references = references
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

    /// Full plain-text body on demand (bodies are never stored).
    func fetchBody(remoteId: String) async throws -> String

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
