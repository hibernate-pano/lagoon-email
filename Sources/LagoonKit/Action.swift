import Foundation

/// Append-only audit log of every action Lagoon takes on the user's behalf.
/// The UI's undo panel and the budget report both read from this table.
public struct AIAction: Codable, Sendable, Identifiable, Equatable {
    public let id: Int64
    public let accountId: UUID
    public let kind: AIActionKind
    /// Structured payload; schema depends on `kind` (see `AIActionPayload`).
    public let payload: [String: String]
    public let createdAt: Date

    public init(id: Int64, accountId: UUID, kind: AIActionKind,
                payload: [String: String], createdAt: Date) {
        self.id = id
        self.accountId = accountId
        self.kind = kind
        self.payload = payload
        self.createdAt = createdAt
    }
}

public enum AIActionKind: String, Codable, Sendable, CaseIterable {
    case archive
    case markRead = "read"
    case pin
    case unpin
    case unsubscribe
    case classifyOverride = "classify_override"
    case draftCreate = "draft_create"
    case send
}

/// AI-generated reply drafts. `variants` is three (or however many) tones;
/// `chosenVariant` is `nil` until the user picks one in the UI.
public struct DraftReply: Codable, Sendable, Identifiable, Equatable {
    public let id: Int64
    public let accountId: UUID
    public let remoteId: String
    public let variants: [String]
    public let chosenVariant: Int?
    public let createdAt: Date

    public init(id: Int64, accountId: UUID, remoteId: String,
                variants: [String], chosenVariant: Int?, createdAt: Date) {
        self.id = id
        self.accountId = accountId
        self.remoteId = remoteId
        self.variants = variants
        self.chosenVariant = chosenVariant
        self.createdAt = createdAt
    }
}

/// `GET /api/actions?since=...` response.
public struct AIActionListResponse: Codable, Sendable, Equatable {
    public let actions: [AIAction]
    public init(actions: [AIAction]) { self.actions = actions }
}

/// User override on AI classification. The heuristic applies these so future
/// calls to the same sender land in the group the user actually wanted.
public struct ClassifyOverrideRequest: Codable, Sendable, Equatable {
    public let remoteId: String
    public let fromGroup: String
    public let toGroup: String
    public init(remoteId: String, fromGroup: String, toGroup: String) {
        self.remoteId = remoteId
        self.fromGroup = fromGroup
        self.toGroup = toGroup
    }
}

/// `GET /api/search?q=...` response.
public struct SearchResponse: Codable, Sendable, Equatable {
    public let results: [MessageHeader]
    public let query: String
    public init(results: [MessageHeader], query: String) {
        self.results = results
        self.query = query
    }
}

/// `GET /api/usage` response: this month's spend and the configured cap.
public struct UsageReport: Codable, Sendable, Equatable {
    public let monthUSD: Double
    public let capUSD: Double
    public let callCount: Int
    public init(monthUSD: Double, capUSD: Double, callCount: Int) {
        self.monthUSD = monthUSD
        self.capUSD = capUSD
        self.callCount = callCount
    }
}
