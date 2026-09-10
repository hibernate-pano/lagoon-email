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

/// Response payload of GET /api/messages/{gmailId}/body.
///
/// `text` is plain text: the server prefers Gmail's `text/plain` part and falls
/// back to stripping the `text/html` part. HTML rendering is deliberately not
/// part of this slice.
public struct MessageBody: Codable, Equatable, Sendable {
    public let gmailId: String
    public let subject: String?
    public let fromAddress: String
    public let fromName: String?
    public let toAddress: String?
    public let receivedAt: Date
    public let text: String

    public init(
        gmailId: String,
        subject: String?,
        fromAddress: String,
        fromName: String?,
        toAddress: String?,
        receivedAt: Date,
        text: String
    ) {
        self.gmailId = gmailId
        self.subject = subject
        self.fromAddress = fromAddress
        self.fromName = fromName
        self.toAddress = toAddress
        self.receivedAt = receivedAt
        self.text = text
    }
}

/// Response payload of GET /api/messages/{gmailId}/summary (spec §5 P0:
/// AI summary + action-item extraction).
public struct MessageSummary: Codable, Equatable, Sendable {
    public let gmailId: String
    public let summary: String
    public let actionItems: [String]
    public let provider: String?

    public init(gmailId: String, summary: String, actionItems: [String], provider: String?) {
        self.gmailId = gmailId
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
    /// - Returns: gmailId → group, for the ids the classifier is confident
    ///   about. Ids it omits keep the heuristic/default grouping.
    func classify(_ messages: [MessageHeader], accountEmail: String) async throws -> [String: BriefingGroup]
}

/// Produces the per-conversation summary + action items. Implemented by the AI
/// Gateway; returns `nil`-equivalent (throws) when no provider is configured.
public protocol MessageSummarizing: Sendable {
    /// - Parameter language: BCP-47-ish tag the summary must be written in.
    ///   `nil` uses the gateway's configured default.
    func summarize(_ body: MessageBody, language: String?) async throws -> MessageSummary
}
