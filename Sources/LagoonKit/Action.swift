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
    /// 彻底删除：the message is gone from the server and from every local
    /// table. Recorded so the history still says what Lagoon did (constitution
    /// §3), and explicitly **not** undoable — there is nothing left to undo.
    ///
    /// This is the one place the product's "every change is reversible" rule is
    /// deliberately broken, by the user's decision on 2026-10-05. It is recorded
    /// here as an enum case with `isUndoable == false` rather than left out of
    /// the audit stream, because "Lagoon did nothing" and "Lagoon did something
    /// irreversible" must be distinguishable in the history.
    case purge

    public var isUndoable: Bool {
        switch self {
        case .archive, .markRead, .pin, .unpin, .classifyOverride, .delete:
            true
        case .unsubscribe, .draftCreate, .send, .undo, .purge:
            false
        }
    }
}

/// 一条用户自定义聚合（归集条件）。命中的邮件自动归入该聚合：
/// `sender` 精确匹配 `from_address`；`keyword` 对主题做大小写不敏感的
/// 包含匹配。求值发生在读取时，未来的邮件无需登记即自动归入。
public struct StackRule: Codable, Sendable, Identifiable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case sender
        case keyword

        // There is deliberately no `displayName` here any more. It returned
        // hardcoded Chinese ("发件人" / "关键词") and the client printed it
        // straight into the group row — so an English user read 「按发件人」
        // next to a group they had just named in English. `LagoonKit` is
        // shared with the server and owns no user-facing copy, so the wording
        // lives in the client's `L10n` instead (`L10n.stackKindName(_:)`).
        // What the API and the database store is `rawValue`.
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
    /// How many rows the history holds, ignoring `limit` and the cursor.
    ///
    /// Optional so the field's absence is distinguishable from a zero: an
    /// older server that does not count must not be read as "there is
    /// nothing else", and that is exactly the lie this field exists to stop.
    public let totalCount: Int?
    /// Whether an older page exists. Measured by the server (it fetches one
    /// row more than it returns), not inferred from `actions.count == limit`
    /// — that inference is also true on a last page that lands exactly on a
    /// page boundary.
    public let hasMore: Bool?

    public init(actions: [AIAction], totalCount: Int? = nil, hasMore: Bool? = nil) {
        self.actions = actions
        self.totalCount = totalCount
        self.hasMore = hasMore
    }
}

/// User override on AI classification. The heuristic applies these so future
/// calls to the same sender land in the group the user actually wanted.
/// Response for the local-state mutations that joined the undo audit log
/// (read toggle, pin toggle). Lives in LagoonKit, not in the server's route
/// file, because the macOS client decodes it — a wire type both sides share
/// has to sit in the shared module or one of them cannot see it.
///
/// `actionId` is nil when the caller did not ask for the change to be
/// recorded; see the `record` parameter on the read route for why that
/// distinction has to exist.
public struct StateChangeResponse: Codable, Sendable, Equatable {
    public let ok: Bool
    public let remoteId: String
    public let actionId: Int64?
    public init(ok: Bool, remoteId: String, actionId: Int64?) {
        self.ok = ok
        self.remoteId = remoteId
        self.actionId = actionId
    }
}

/// `POST /api/actions/undo-bulk` request.
///
/// Bulk operations ("mark all as read", sweep) record one audit row per
/// message, and a single ⌘Z that reverses only the newest one would leave the
/// other N-1 changes in place — which reads to the user as "undo did nothing".
/// The ids are capped server-side the same way `archive-bulk` caps its input.
public struct UndoBulkRequest: Codable, Sendable, Equatable {
    public let actionIds: [Int64]
    public init(actionIds: [Int64]) { self.actionIds = actionIds }
}

/// One item of a bulk undo. `ok` false with `alreadyUndone` is normal and not
/// an error: the action may have been undone individually before the bulk
/// call arrived.
public struct UndoBulkItem: Codable, Sendable, Equatable {
    public let actionId: Int64
    public let ok: Bool
    public let errorCode: String?
    public init(actionId: Int64, ok: Bool, errorCode: String? = nil) {
        self.actionId = actionId
        self.ok = ok
        self.errorCode = errorCode
    }
}

public struct UndoBulkResponse: Codable, Sendable, Equatable {
    public let items: [UndoBulkItem]
    /// How many inverses actually ran. The client shows this so a partially
    /// successful undo does not claim more than it did.
    public let undone: Int
    public init(items: [UndoBulkItem], undone: Int) {
        self.items = items
        self.undone = undone
    }
}

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
    /// How many messages matched, before the server's cap.
    ///
    /// The search used to stop at 100 hits and say nothing about it. A user
    /// who searched "发票" and got 100 rows had no way to know whether that
    /// was all of them or the first hundred — and "the first hundred" reads
    /// as "all of them" every time. The count is what turns a silent cap
    /// into a statement the user can act on.
    ///
    /// Nil means "the server did not say", which is the honest answer for an
    /// older server; the client then falls back to the old behaviour rather
    /// than claiming a number it does not have.
    public let totalCount: Int?
    /// True when the server stopped at its cap and more matched.
    public let truncated: Bool?
    /// How many messages were **not** searched inside their sealed text.
    ///
    /// The body and the preview are encrypted at rest, so finding a word
    /// inside one costs an AES-GCM open. The server opens a bounded number
    /// of them per request — the newest first — and when the mailbox holds
    /// more than that budget, the rest were not searched.
    ///
    /// This is how many of those messages there were. A search that quietly
    /// stopped early reads as a complete search, and "no match" is the
    /// answer a user is least able to check for themselves.
    ///
    /// Nil means "the server did not say" — an older server that searches
    /// everything and has no budget to report.
    public let bodyScanSkipped: Int?
    /// The body-scan budget this request ran under.
    ///
    /// The number of sealed bodies the server was willing to open. Together
    /// with `bodyScanSkipped` it says what was searched: the newest
    /// `bodyScanLimit` of them, minus the ones that matched nothing.
    public let bodyScanLimit: Int?
    public init(
        results: [MessageHeader],
        query: String,
        totalCount: Int? = nil,
        truncated: Bool? = nil,
        bodyScanSkipped: Int? = nil,
        bodyScanLimit: Int? = nil
    ) {
        self.results = results
        self.query = query
        self.totalCount = totalCount
        self.truncated = truncated
        self.bodyScanSkipped = bodyScanSkipped
        self.bodyScanLimit = bodyScanLimit
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
/// One account's share of the month's LLM spend.
///
/// The account is identified by **email**, not id, because that is what
/// `usage_log` records: the AI gateway is handed an account's address on
/// every call, and the log has stored it since the table existed. An id
/// would have to be joined back to `accounts` — and then a spend row would
/// disappear from the panel the moment the account was removed, which
/// silently rewrites history: the money was still spent.
public struct UsageAccountShare: Codable, Sendable, Equatable {
    public let accountEmail: String
    public let monthUSD: Double
    public let callCount: Int
    public init(accountEmail: String, monthUSD: Double, callCount: Int) {
        self.accountEmail = accountEmail
        self.monthUSD = monthUSD
        self.callCount = callCount
    }
}

public struct UsageReport: Codable, Sendable, Equatable {
    public let monthUSD: Double
    public let capUSD: Double
    public let callCount: Int
    /// False when the provider has no token rates. Tokens can still be counted,
    /// but a dollar-denominated cap cannot be enforced truthfully.
    public let costTrackingAvailable: Bool
    /// The month's spend grouped by account, cost descending.
    ///
    /// ## Why this is decoded by hand, with a default
    ///
    /// It was added after `UsageReport` shipped, so a client built before
    /// it existed must still be able to read this response. The synthesised
    /// `Decodable` would treat a missing key as an error and the usage
    /// panel would fail to load against a server that is merely newer —
    /// which is exactly the failure this default prevents. An **older**
    /// server answers without the key, and that decodes to an empty array;
    /// the panel then says nothing about accounts rather than showing a
    /// fabricated split.
    ///
    /// An empty array is therefore load-bearing and must not be rendered as
    /// "every account spent $0" — see `UsageSheet`.
    public let accounts: [UsageAccountShare]

    public init(
        monthUSD: Double,
        capUSD: Double,
        callCount: Int,
        costTrackingAvailable: Bool = true,
        accounts: [UsageAccountShare] = []
    ) {
        self.monthUSD = monthUSD
        self.capUSD = capUSD
        self.callCount = callCount
        self.costTrackingAvailable = costTrackingAvailable
        self.accounts = accounts
    }

    private enum CodingKeys: String, CodingKey {
        case monthUSD, capUSD, callCount, costTrackingAvailable, accounts
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        monthUSD = try c.decode(Double.self, forKey: .monthUSD)
        capUSD = try c.decode(Double.self, forKey: .capUSD)
        callCount = try c.decode(Int.self, forKey: .callCount)
        costTrackingAvailable = try c.decodeIfPresent(Bool.self, forKey: .costTrackingAvailable) ?? true
        accounts = try c.decodeIfPresent([UsageAccountShare].self, forKey: .accounts) ?? []
    }
}
