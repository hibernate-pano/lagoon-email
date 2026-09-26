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
    public let expiresAt: Date?

    public init(id: Int64, accountId: UUID, kind: AIActionKind,
                payload: [String: String], createdAt: Date, expiresAt: Date? = nil) {
        self.id = id
        self.accountId = accountId
        self.kind = kind
        self.payload = payload
        self.createdAt = createdAt
        self.expiresAt = expiresAt
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
    case undo
    /// Moved to the server's Trash; undo restores it to the INBOX.
    case delete

    public var isUndoable: Bool {
        switch self {
        case .archive, .markRead, .pin, .unpin, .classifyOverride, .delete:
            true
        case .unsubscribe, .draftCreate, .send, .undo:
            false
        }
    }
}

/// 一条用户自定义聚合（归集规则）。命中的邮件自动归入该聚合：
/// `sender` 精确匹配 `from_address`；`keyword` 对主题做大小写不敏感的
/// 包含匹配。求值发生在读取时，未来的邮件无需登记即自动归入。
public struct StackRule: Codable, Sendable, Identifiable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case sender
        case keyword

        public var displayName: String {
            switch self {
            case .sender: return "发件人"
            case .keyword: return "关键词"
            }
        }
    }

    public let id: UUID
    public let accountId: UUID
    public let name: String
    public let kind: Kind
    /// Match value: an exact address (sender) or a subject substring (keyword).
    public let value: String
    public let createdAt: Date

    public init(id: UUID, accountId: UUID, name: String, kind: Kind,
                value: String, createdAt: Date) {
        self.id = id
        self.accountId = accountId
        self.name = name
        self.kind = kind
        self.value = value
        self.createdAt = createdAt
    }
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

/// `GET /api/ai-status` response: the global AI degraded signal (V2 C1).
/// The client polls it with the directory and banners when the gateway
/// cannot serve: unconfigured (heuristic-only), out of credit (top up),
/// or circuit-open (transient provider errors, recovers on its own).
public struct AIStatus: Codable, Sendable, Equatable {
    public let configured: Bool
    public let creditExhausted: Bool
    public let circuitOpen: Bool
    public init(configured: Bool, creditExhausted: Bool, circuitOpen: Bool) {
        self.configured = configured
        self.creditExhausted = creditExhausted
        self.circuitOpen = circuitOpen
    }
}
public struct UsageReport: Codable, Sendable, Equatable {
    public let monthUSD: Double
    public let capUSD: Double
    public let callCount: Int
    /// False when the provider has no token rates. Tokens can still be counted,
    /// but a dollar-denominated cap cannot be enforced truthfully.
    public let costTrackingAvailable: Bool
    public init(
        monthUSD: Double,
        capUSD: Double,
        callCount: Int,
        costTrackingAvailable: Bool = true
    ) {
        self.monthUSD = monthUSD
        self.capUSD = capUSD
        self.callCount = callCount
        self.costTrackingAvailable = costTrackingAvailable
    }
}
