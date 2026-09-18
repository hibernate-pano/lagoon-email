import Foundation

/// Capability tags from spec §6.5. The gateway routes by capability, not by
/// call site, so adding a provider never changes callers.
public enum LLMCapability: String, Codable, Sendable, CaseIterable {
    case summary
    case classify
    case actionItem = "action_item"
    case bundleReason = "bundle_reason"
    case draft
}

public struct LLMCompletion: Sendable {
    public let text: String
    public let promptTokens: Int?
    public let completionTokens: Int?
    public let model: String
    public let latencyMs: Int
    /// Provider `finish_reason`. `length` means the answer was truncated and
    /// JSON parsing may legitimately fail, so it is worth logging/retrying.
    public let finishReason: String?
    /// Estimated cost in micro-USD (rate * tokens). nil when the provider has
    /// no rate configured; the budget cap cannot be enforced then.
    public let costMicrosUSD: Int64?

    public init(
        text: String,
        promptTokens: Int?,
        completionTokens: Int?,
        model: String,
        latencyMs: Int,
        finishReason: String? = nil,
        costMicrosUSD: Int64? = nil
    ) {
        self.text = text
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.model = model
        self.latencyMs = latencyMs
        self.finishReason = finishReason
        self.costMicrosUSD = costMicrosUSD
    }
}

public enum LLMError: Error, CustomStringConvertible {
    case notConfigured
    case invalidBaseURL(String)
    case blockedHost(String)
    case redirectBlocked
    case http(Int)
    case badResponse(String)
    case circuitOpen(provider: String)
    /// The configured monthly budget is exhausted.
    case budgetExceeded(currentUSD: Double, capUSD: Double)
    /// The *vendor's* account is out of credit or the key was revoked
    /// (HTTP 401/402). Distinguished from `budgetExceeded` because the
    /// remedy is different: the user tops up their provider account
    /// rather than raising the local cap. Also trips the circuit breaker
    /// so a background classifier does not hammer a dead account.
    case insufficientCredit(status: Int)

    public var description: String {
        switch self {
        case .notConfigured: "no LLM provider configured"
        case .invalidBaseURL(let raw): "invalid provider base URL: \(raw)"
        case .blockedHost(let host): "provider host not allowed: \(host)"
        case .redirectBlocked: "provider HTTP redirect blocked"
        case .http(let status): "provider returned HTTP \(status)"
        case .badResponse(let detail): "unparseable provider response: \(detail)"
        case .circuitOpen(let provider): "provider circuit open: \(provider)"
        case .budgetExceeded(let cur, let cap):
            String(
                format: "LLM budget exceeded: $%.4f of $%.2f",
                cur, cap
            )
        case .insufficientCredit(let status):
            "provider account out of credit (HTTP \(status))"
        }
    }

    /// Stable machine code for the route layer to map onto a client-facing
    /// error code. Distinct from `description`, which is for logs.
    public var code: String {
        switch self {
        case .notConfigured: "not-configured"
        case .invalidBaseURL: "invalid-base-url"
        case .blockedHost: "blocked-host"
        case .redirectBlocked: "redirect-blocked"
        case .http: "http"
        case .badResponse: "bad-response"
        case .circuitOpen: "circuit-open"
        case .budgetExceeded: "budget-exceeded"
        case .insufficientCredit: "insufficient-credit"
        }
    }
}

/// The only seam between Lagoon and a model vendor (spec §6.5). Implementations
/// live under `Sources/LagoonAI/Providers/`; no other file may speak HTTP to a
/// model provider.
public protocol LLMProvider: Sendable {
    var name: String { get }
    var model: String { get }
    /// USD per 1k prompt / completion tokens. nil disables budget enforcement
    /// for this provider.
    var costPer1kPromptUsd: Double? { get }
    var costPer1kCompletionUsd: Double? { get }
    func complete(capability: LLMCapability, system: String, user: String) async throws -> LLMCompletion
}

/// Per-month cost cap (spec §6.5).
///
/// `checkBeforeCall` runs before the HTTP request with a best-effort estimate;
/// `record` runs after with actual tokens. Both are no-ops when no provider
/// rate is configured.
public protocol BudgetPolicy: Sendable {
    /// Throws `LLMError.budgetExceeded` if the call would breach the cap.
    func checkBeforeCall(
        capability: String,
        model: String,
        estimatedPromptTokens: Int,
        estimatedCompletionTokens: Int,
        promptRate: Double?,
        completionRate: Double?
    ) async throws

    /// Records the actual call and updates the running total. The cap is not
    /// re-checked here: a single over-budget call is allowed so the user keeps
    /// the answer; the next call's pre-check rejects.
    func record(
        capability: String,
        model: String,
        accountEmail: String,
        promptTokens: Int,
        completionTokens: Int,
        costMicrosUSD: Int64
    ) async throws
}

/// A no-op budget policy for deployments that don't configure a cap.
public struct NoBudgetPolicy: BudgetPolicy {
    public init() {}
    public func checkBeforeCall(
        capability: String,
        model: String,
        estimatedPromptTokens: Int,
        estimatedCompletionTokens: Int,
        promptRate: Double?,
        completionRate: Double?
    ) async throws {}
    public func record(
        capability: String,
        model: String,
        accountEmail: String,
        promptTokens: Int,
        completionTokens: Int,
        costMicrosUSD: Int64
    ) async throws {}
}
