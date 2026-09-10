import Foundation
import Logging
import LagoonKit

/// The single module allowed to talk to LLM providers (spec §6.5). It receives
/// tasks, never raw mailbox state beyond the prompt payload it must send.
///
/// `ponytail:` ceiling — the per-account monthly budget cap from §6.5 is not
/// implemented; there is no cost accounting source yet. Add it when a second
/// account or a metered plan exists.
public final class AIGateway: BriefingClassifying, MessageSummarizing, @unchecked Sendable {
    /// Language the model must write user-facing text in. Group identifiers
    /// and JSON keys stay English because they are parsed, not displayed.
    public static let defaultOutputLanguage = "zh-Hans"

    private let providers: [LLMProvider]
    private let routing: [String: String]
    private let breaker: CircuitBreaker
    private let logger: Logger
    public let outputLanguage: String

    public init(
        providers: [LLMProvider],
        routing: [String: String],
        outputLanguage: String = AIGateway.defaultOutputLanguage,
        logger: Logger = Logger(label: "lagoon.ai")
    ) {
        self.providers = providers
        self.routing = routing
        self.outputLanguage = outputLanguage
        self.breaker = CircuitBreaker()
        self.logger = logger
    }

    /// Human-readable name for a BCP-47-ish language tag, used in prompts.
    public static func languageName(for tag: String) -> String {
        switch tag.lowercased() {
        case "zh-hans", "zh-cn", "zh": "Simplified Chinese (简体中文)"
        case "zh-hant", "zh-tw", "zh-hk": "Traditional Chinese (繁體中文)"
        case "en", "en-us", "en-gb": "English"
        case "ja", "ja-jp": "Japanese (日本語)"
        case "ko", "ko-kr": "Korean (한국어)"
        default: tag
        }
    }

    /// Returns nil when no provider is configured (missing key or base URL).
    /// The server then stays heuristic-only instead of failing.
    public static func fromEnvironment(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileURL: URL? = nil,
        session: URLSession = ProviderHTTP.makeSession(),
        logger: Logger = Logger(label: "lagoon.ai")
    ) -> AIGateway? {
        do {
            let resolved = try ProviderRegistry.load(environment: environment, fileURL: fileURL)
            guard !resolved.isEmpty else { return nil }
            let providers = try resolved.map { try OpenAICompatibleProvider(resolved: $0, session: session) }
            let routing = (try? loadRouting(environment: environment, fileURL: fileURL)) ?? [:]
            let language = environment["LAGOON_AI_LANGUAGE"].flatMap { $0.isEmpty ? nil : $0 }
                ?? AIGateway.defaultOutputLanguage
            return AIGateway(
                providers: providers,
                routing: routing,
                outputLanguage: language,
                logger: logger
            )
        } catch {
            logger.warning("AI gateway disabled", metadata: ["reason": .string("\(error)")])
            return nil
        }
    }

    private static func loadRouting(
        environment: [String: String],
        fileURL: URL?
    ) throws -> [String: String] {
        let url: URL
        if let fileURL { url = fileURL }
        else if let override = environment["LAGOON_PROVIDER_CONFIG"], !override.isEmpty {
            url = URL(fileURLWithPath: override)
        } else {
            url = URL(fileURLWithPath: ProviderRegistry.defaultConfigPath)
        }
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode(ProviderRegistryFile.self, from: data))?.routing ?? [:]
    }

    // MARK: - BriefingClassifying

    public func classify(
        _ messages: [MessageHeader],
        accountEmail: String
    ) async throws -> [String: BriefingGroup] {
        guard !messages.isEmpty else { return [:] }
        // Only headers/snippet/age — never a body (spec §6.6 rule 5).
        let rows: [[String: Any]] = messages.map { message in
            var row: [String: Any] = [
                "id": message.gmailId,
                "from": message.fromAddress,
                "read": message.isRead,
                "ageDays": Int(Date().timeIntervalSince(message.receivedAt) / 86400)
            ]
            if let subject = message.subject { row["subject"] = subject }
            if let snippet = message.snippet { row["snippet"] = String(snippet.prefix(200)) }
            return row
        }
        let user = """
            Classify each email into exactly one group.
            Groups: needsReply (a human is waiting on the user), awaitingReply (the \
            user sent the last message), safeToArchive (already handled / no action), \
            subscriptionNoise (newsletters, notifications, marketing).
            Reply with STRICT JSON only: {"<id>":"<group>"}. Use the group \
            identifiers and message ids exactly as given (ASCII, never translated). \
            Omit any email you are unsure about.
            Emails: \(jsonString(rows))
            """

        let parsed = try await completeJSON(capability: .classify, system: systemPrompt, user: user).json
        var result: [String: BriefingGroup] = [:]
        for (id, raw) in parsed {
            guard let raw = raw as? String,
                  let group = BriefingGroup(rawValue: raw),
                  group != .pinned
            else { continue }
            result[id] = group
        }
        return result
    }

    // MARK: - MessageSummarizing

    public func summarize(_ body: MessageBody, language: String?) async throws -> MessageSummary {
        let languageTag = language.flatMap { $0.isEmpty ? nil : $0 } ?? outputLanguage
        let text = String(body.text.prefix(12_000))
        let user = """
            Summarize this email in at most 3 sentences and extract concrete action \
            items addressed to the reader. Reply with STRICT JSON only:
            {"summary":"…","actionItems":["…"]}
            Write the summary and every action item in \
            \(Self.languageName(for: languageTag)). Keep the JSON keys exactly \
            as given (English) — translate only the values. Leave product names, \
            people names and code identifiers unchanged.
            From: \(body.fromAddress)
            Subject: \(body.subject ?? "(none)")
            Body:
            \(text)
            """
        let (parsed, model) = try await completeJSON(
            capability: .summary,
            system: systemPrompt,
            user: user
        )
        guard let summary = parsed["summary"] as? String, !summary.isEmpty else {
            throw LLMError.badResponse("summary: missing summary field")
        }
        let actionItems = (parsed["actionItems"] as? [Any])?
            .compactMap { $0 as? String }
            .filter { !$0.isEmpty } ?? []
        return MessageSummary(
            gmailId: body.gmailId,
            summary: summary,
            actionItems: actionItems,
            provider: model
        )
    }

    // MARK: - Provider call + observability

    /// Calls the provider and parses strict JSON, retrying once when the model
    /// answers with prose or truncated JSON (observed intermittently with
    /// reasoning models). Logs size/finish reason only — never the content.
    private func completeJSON(
        capability: LLMCapability,
        system: String,
        user: String,
        attempts: Int = 2
    ) async throws -> (json: [String: Any], model: String) {
        var lastError: Error = LLMError.badResponse("\(capability.rawValue): no attempt")
        for attempt in 1...max(1, attempts) {
            let completion = try await complete(capability: capability, system: system, user: user)
            if let parsed = parseJSONObject(completion.text) {
                return (parsed, completion.model)
            }
            lastError = LLMError.badResponse("\(capability.rawValue): not a JSON object")
            logger.warning("llm.unparseable", metadata: [
                "capability": .string(capability.rawValue),
                "attempt": .string("\(attempt)"),
                "chars": .string("\(completion.text.count)"),
                "finishReason": .string(completion.finishReason ?? "unknown")
            ])
        }
        throw lastError
    }

    private var systemPrompt: String {
        "You are Lagoon, an email assistant. You never invent facts. You answer only with the requested JSON."
    }

    private func complete(
        capability: LLMCapability,
        system: String,
        user: String
    ) async throws -> LLMCompletion {
        guard let provider = provider(for: capability) else { throw LLMError.notConfigured }
        if breaker.isOpen(provider.name) {
            throw LLMError.circuitOpen(provider: provider.name)
        }
        do {
            let completion = try await provider.complete(capability: capability, system: system, user: user)
            breaker.recordSuccess(provider.name)
            log(capability: capability, provider: provider, completion: completion, outcome: "ok")
            return completion
        } catch {
            if case LLMError.http(let status) = error, (500..<600).contains(status) {
                breaker.recordFailure(provider.name)
            }
            log(capability: capability, provider: provider, completion: nil, outcome: "\(error)")
            throw error
        }
    }

    private func provider(for capability: LLMCapability) -> LLMProvider? {
        if let name = routing[capability.rawValue],
           let routed = providers.first(where: { $0.name == name }) {
            return routed
        }
        return providers.first
    }

    private func log(
        capability: LLMCapability,
        provider: LLMProvider,
        completion: LLMCompletion?,
        outcome: String
    ) {
        let promptTokens = completion?.promptTokens ?? 0
        let completionTokens = completion?.completionTokens ?? 0
        logger.info("llm.call", metadata: [
            "capability": .string(capability.rawValue),
            "provider": .string(provider.name),
            "model": .string(provider.model),
            "promptTokens": .string("\(promptTokens)"),
            "completionTokens": .string("\(completionTokens)"),
            "latencyMs": .string("\(completion?.latencyMs ?? 0)"),
            "outcome": .string(outcome)
        ])
    }

    // MARK: - Helpers

    private func jsonString(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value),
              let text = String(data: data, encoding: .utf8)
        else { return "[]" }
        return text
    }

    /// Accepts a bare JSON object, one wrapped in a ```json fence, or one
    /// preceded by a reasoning block.
    ///
    /// MiniMax-M3 and other reasoning models emit `<think>…</think>` before the
    /// answer. The block can contain braces, so it is removed before slicing
    /// from the first `{` to the last `}`.
    private func parseJSONObject(_ raw: String) -> [String: Any]? {
        var text = raw
            .replacingOccurrences(
                of: "(?is)<think\\b.*?</think\\s*>",
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") {
            text = String(text[start...end])
        }
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }
}

/// Per-provider circuit breaker: open after 5 consecutive 5xx within 60s,
/// half-open probe after 5 minutes (spec §6.5).
final class CircuitBreaker: @unchecked Sendable {
    private struct State {
        var failureCount = 0
        var firstFailureAt: Date?
        var openUntil: Date?
    }

    private let lock = NSLock()
    private var states: [String: State] = [:]
    private let failureThreshold = 5
    private let window: TimeInterval = 60
    private let cooldown: TimeInterval = 300

    func isOpen(_ provider: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard var state = states[provider], let openUntil = state.openUntil else { return false }
        if Date() >= openUntil {
            // half-open: allow one probe
            state.openUntil = nil
            state.failureCount = 0
            state.firstFailureAt = nil
            states[provider] = state
            return false
        }
        return true
    }

    func recordSuccess(_ provider: String) {
        lock.lock(); defer { lock.unlock() }
        states[provider] = State()
    }

    func recordFailure(_ provider: String) {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        var state = states[provider] ?? State()
        if let first = state.firstFailureAt, now.timeIntervalSince(first) > window {
            state.failureCount = 0
            state.firstFailureAt = nil
        }
        if state.firstFailureAt == nil { state.firstFailureAt = now }
        state.failureCount += 1
        if state.failureCount >= failureThreshold {
            state.openUntil = now.addingTimeInterval(cooldown)
        }
        states[provider] = state
    }
}
