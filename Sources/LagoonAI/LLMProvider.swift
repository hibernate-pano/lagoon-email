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

    public init(
        text: String,
        promptTokens: Int?,
        completionTokens: Int?,
        model: String,
        latencyMs: Int
    ) {
        self.text = text
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.model = model
        self.latencyMs = latencyMs
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

    public var description: String {
        switch self {
        case .notConfigured: "no LLM provider configured"
        case .invalidBaseURL(let raw): "invalid provider base URL: \(raw)"
        case .blockedHost(let host): "provider host not allowed: \(host)"
        case .redirectBlocked: "provider redirect blocked"
        case .http(let status): "provider returned HTTP \(status)"
        case .badResponse(let detail): "unparseable provider response: \(detail)"
        case .circuitOpen(let provider): "provider circuit open: \(provider)"
        }
    }
}

/// The only seam between Lagoon and a model vendor (spec §6.5). Implementations
/// live under `Sources/LagoonAI/Providers/`; no other file may speak HTTP to a
/// model provider.
public protocol LLMProvider: Sendable {
    var name: String { get }
    var model: String { get }
    func complete(capability: LLMCapability, system: String, user: String) async throws -> LLMCompletion
}
