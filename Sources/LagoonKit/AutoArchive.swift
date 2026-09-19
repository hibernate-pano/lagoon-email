import Foundation

/// One whitelist autopilot rule (spec 2026-09-19 §3): mail from
/// `senderAddress` is archived remotely the moment it lands, recorded in
/// `ai_actions` with `autoRule = true`, and reversible through the standard
/// 30-day undo window.
public struct AutoArchiveRule: Codable, Sendable, Equatable, Identifiable {
    public let id: Int64
    public let accountId: UUID
    /// Lowercased at the boundary; matching is case-insensitive.
    public let senderAddress: String
    public let createdAt: Date

    public init(id: Int64, accountId: UUID, senderAddress: String, createdAt: Date) {
        self.id = id
        self.accountId = accountId
        self.senderAddress = senderAddress
        self.createdAt = createdAt
    }
}

/// `GET /api/auto-archive` response.
public struct AutoArchiveRuleListResponse: Codable, Sendable, Equatable {
    public let rules: [AutoArchiveRule]
    public init(rules: [AutoArchiveRule]) { self.rules = rules }
}

/// `POST /api/auto-archive` request body. The account comes from the
/// `accountId` query parameter, like every other POST route.
public struct AutoArchiveRuleCreateRequest: Codable, Sendable, Equatable {
    public let senderAddress: String
    public init(senderAddress: String) {
        self.senderAddress = senderAddress
    }
}
