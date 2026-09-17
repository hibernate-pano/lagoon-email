import Foundation

/// The five Briefing Feed groups from spec §7.1. Order matters: it is the
/// display order and the ⌘1…⌘5 shortcut order.
///
/// Only the identifier travels over the wire; the display name is localized by
/// the client (spec §7.4).
public enum BriefingGroup: String, Codable, Sendable, CaseIterable, Identifiable {
    case needsReply
    case awaitingReply
    case safeToArchive
    case subscriptionNoise
    case pinned

    public var id: String { rawValue }

    /// Language-independent, so it lives with the enum rather than the client.
    public var emoji: String {
        switch self {
        case .needsReply: "🔴"
        case .awaitingReply: "⏳"
        case .safeToArchive: "🟢"
        case .subscriptionNoise: "🆕"
        case .pinned: "📌"
        }
    }

    /// Spec §2 principle 4: sections hide when empty.
    public var collapsedByDefault: Bool { self == .subscriptionNoise }
}

/// Stable code explaining why a message was grouped as it was (the "Why?"
/// affordance, spec §3 step 3).
///
/// The server sends this code, never display text: wording is the client's
/// job, so adding a language never requires a server change.
public enum BriefingReason: String, Codable, Sendable, CaseIterable {
    case pinned
    case listUnsubscribe = "list-unsubscribe"
    case subscriptionSender = "subscription-sender"
    case fromSelf = "from-self"
    case readAndOld = "read-and-old"
    case needsReply = "needs-reply"
    case ai
    case userOverride = "user-override"
    case unclassified
}

/// One row in the Briefing Feed: a message plus the group the classifier put it
/// in, plus a stable reason code.
public struct BriefingItem: Codable, Equatable, Sendable, Identifiable {
    public let message: MessageHeader
    public let group: BriefingGroup
    /// Raw `BriefingReason` value. Optional so an unknown code from a newer
    /// server degrades to "no reason" instead of failing the whole decode.
    public let reasonCode: String?

    public var id: UUID { message.id }

    public var reason: BriefingReason? { reasonCode.flatMap(BriefingReason.init(rawValue:)) }

    public init(message: MessageHeader, group: BriefingGroup, reasonCode: String?) {
        self.message = message
        self.group = group
        self.reasonCode = reasonCode
    }
}

/// Response payload of GET /api/briefing. The client groups by `group` and
/// renders in `BriefingGroup.allCases` order.
public struct BriefingResponse: Codable, Equatable, Sendable {
    public let items: [BriefingItem]

    public init(items: [BriefingItem]) {
        self.items = items
    }
}

/// Response payload of GET /api/messages/{remoteId}/body.
///
/// `text` is plain text: the server prefers `text/plain` and falls back to
/// stripping `text/html`. `html` is the original HTML part when present, capped
/// at 5 MB on the server; the client renders it via WKWebView and resolves
/// `cid:` references against `attachments` whose `disposition == .inline`.
/// `hasMore` is true when either `text` or `html` was truncated server-side
/// (defaults to false on the wire for compat with v0.2.0 clients).
public struct MessageBody: Codable, Equatable, Sendable {
    public let remoteId: String
    public let subject: String?
    public let fromAddress: String
    public let fromName: String?
    public let toAddress: String?
    public let receivedAt: Date
    public let text: String
    public let html: String?
    public let attachments: [Attachment]
    public let hasMore: Bool

    public init(
        remoteId: String,
        subject: String?,
        fromAddress: String,
        fromName: String?,
        toAddress: String?,
        receivedAt: Date,
        text: String,
        html: String? = nil,
        attachments: [Attachment] = [],
        hasMore: Bool = false
    ) {
        self.remoteId = remoteId
        self.subject = subject
        self.fromAddress = fromAddress
        self.fromName = fromName
        self.toAddress = toAddress
        self.receivedAt = receivedAt
        self.text = text
        self.html = html
        self.attachments = attachments
        self.hasMore = hasMore
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        remoteId = try c.decode(String.self, forKey: .remoteId)
        subject = try c.decodeIfPresent(String.self, forKey: .subject)
        fromAddress = try c.decode(String.self, forKey: .fromAddress)
        fromName = try c.decodeIfPresent(String.self, forKey: .fromName)
        toAddress = try c.decodeIfPresent(String.self, forKey: .toAddress)
        receivedAt = try c.decode(Date.self, forKey: .receivedAt)
        text = try c.decode(String.self, forKey: .text)
        // v0.2.0 clients do not know about these fields. Decode as missing
        // → no attachments, no HTML, no truncation flag. The forward path
        // (v0.2.0 server, M1.6 client) sees the same defaults and renders
        // the plain-text path, which is correct.
        html = try c.decodeIfPresent(String.self, forKey: .html)
        attachments = try c.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
        hasMore = try c.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case remoteId, subject, fromAddress, fromName, toAddress
        case receivedAt, text, html, attachments, hasMore
    }
}

/// One file attached to a message (M1.6 spec §1.1). `id` is the server's
/// stable per-message identifier for the part — opaque to the client, used
/// in `GET /api/messages/{remoteId}/attachments/{id}`. For IMAP this is the
/// dotted part path; for Gmail it is `body.attachmentId`.
public struct Attachment: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let filename: String?
    public let mimeType: String
    public let size: Int
    public let contentId: String?
    public let disposition: Disposition

    public enum Disposition: String, Codable, Sendable, Equatable {
        /// User-visible download in the attachment list.
        case attachment
        /// Referenced by the HTML body via `cid:<contentId>`. Usually an
        /// image; the client resolves these against the attachment list
        /// when rendering.
        case inline
    }

    public init(
        id: String,
        filename: String?,
        mimeType: String,
        size: Int,
        contentId: String? = nil,
        disposition: Disposition = .attachment
    ) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.size = size
        self.contentId = contentId
        self.disposition = disposition
    }
}

/// Response payload of GET /api/messages/{remoteId}/summary (spec §5 P0:
/// AI summary + action-item extraction).
public struct MessageSummary: Codable, Equatable, Sendable {
    public let remoteId: String
    public let summary: String
    public let actionItems: [String]
    public let provider: String?

    public init(remoteId: String, summary: String, actionItems: [String], provider: String?) {
        self.remoteId = remoteId
        self.summary = summary
        self.actionItems = actionItems
        self.provider = provider
    }
}

/// Classifies headers into Briefing groups. Implemented by the AI Gateway
/// (`Sources/LagoonServer/AI`) and, when no LLM is configured, by the
/// deterministic heuristic classifier in `Sources/LagoonServer/AI/Heuristics.swift`.
/// Server routes depend only on this protocol.
public protocol BriefingClassifying: Sendable {
    /// - Returns: remoteId → group, for the ids the classifier is confident
    ///   about. Ids it omits keep the heuristic/default grouping.
    func classify(
        _ messages: [MessageHeader],
        accountEmail: String,
        language: String?
    ) async throws -> [String: BriefingGroup]
}

/// Produces the per-conversation summary + action items. Implemented by the AI
/// Gateway; returns `nil`-equivalent (throws) when no provider is configured.
public protocol MessageSummarizing: Sendable {
    /// - Parameters:
    ///   - body: the email to summarize,
    ///   - language: BCP-47-ish tag the summary must be written in,
    ///   - accountEmail: used for the per-account usage audit log.
func summarize(
        _ body: MessageBody,
        language: String?,
        accountEmail: String
    ) async throws -> MessageSummary
}

/// Generates send-ready reply variants for one message. This is deliberately
/// separate from summarization: a summary answers "what does this say?", while
/// a reply draft answers "what should I write back?".
public protocol MessageDrafting: Sendable {
    func draftReplies(
        _ body: MessageBody,
        language: String?,
        accountEmail: String,
        count: Int
    ) async throws -> [String]
}
