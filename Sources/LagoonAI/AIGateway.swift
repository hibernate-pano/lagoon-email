import Foundation
import Logging
import LagoonKit

/// The single module allowed to talk to LLM providers (spec §6.5). It receives
/// tasks, never raw mailbox state beyond the prompt payload it must send.
///
/// Cost accounting is injected through `BudgetPolicy`; the server supplies the
/// database-backed implementation so the API and restart behavior share one
/// monthly total.
public final class AIGateway: BriefingClassifying, MessageSummarizing, MessageDrafting, @unchecked Sendable {
    /// Language the model must write user-facing text in. Group identifiers
    /// and JSON keys stay English because they are parsed, not displayed.
    public static let defaultOutputLanguage = "zh-Hans"

    private let providers: [LLMProvider]
    private let routing: [String: String]
    private let breaker: CircuitBreaker
    private let logger: Logger
    public let outputLanguage: String
    private let budget: BudgetPolicy

    /// Dollar caps are enforceable only when every active provider exposes both
    /// prompt and completion rates.
    public var hasConfiguredRates: Bool {
        !providers.isEmpty && providers.allSatisfy {
            $0.costPer1kPromptUsd != nil && $0.costPer1kCompletionUsd != nil
        }
    }

    public init(
        providers: [LLMProvider],
        routing: [String: String],
        outputLanguage: String = AIGateway.defaultOutputLanguage,
        budget: BudgetPolicy = NoBudgetPolicy(),
        logger: Logger = Logger(label: "lagoon.ai")
    ) {
        self.providers = providers
        self.routing = routing
        self.outputLanguage = outputLanguage
        self.budget = budget
        self.breaker = CircuitBreaker()
        self.logger = logger
    }

    /// Conservative upper bound for completion tokens used in pre-call cost
    /// estimation. The actual value is recorded after the call; this only
    /// prevents an obviously-too-large call from crossing the cap.
    private static let estimatedCompletionTokens = 1_500
    /// A single 50-message response can exceed the provider's 4k completion
    /// cap and arrive as truncated, unparseable text. Twelve keeps each strict
    /// JSON answer comfortably below that ceiling.
    private static let classificationBatchSize = 12

    /// Rough English token estimate: ~4 chars per token.
    private static func estimatePromptTokens(_ text: String) -> Int {
        max(1, text.count / 4)
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
        budget: BudgetPolicy = NoBudgetPolicy(),
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
                budget: budget,
                logger: logger
            ) // fromEnvironment has no Postgres connection; budget is NoBudgetPolicy. App.swift wires the real one.
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
        accountEmail: String,
        language: String?
    ) async throws -> [String: BriefingGroup] {
        guard !messages.isEmpty else { return [:] }
        let provider = provider(for: .classify)
        var result: [String: BriefingGroup] = [:]

        for start in stride(from: 0, to: messages.count, by: Self.classificationBatchSize) {
            let end = min(start + Self.classificationBatchSize, messages.count)
            let batch = Array(messages[start..<end])
            let user = classificationPrompt(for: batch)
            try await chargeBudgetPreCheck(
                capability: .classify,
                provider: provider,
                systemPrompt: systemPrompt,
                userPrompt: user,
                accountEmail: accountEmail
            )
            let (parsed, _) = try await completeJSON(
                capability: .classify,
                system: systemPrompt,
                user: user,
                accountEmail: accountEmail
            )
            for (id, raw) in parsed {
                guard let raw = raw as? String,
                      let group = BriefingGroup(rawValue: raw),
                      group != .pinned
                else { continue }
                result[id] = group
            }
        }
        return result
    }

    private func classificationPrompt(for messages: [MessageHeader]) -> String {
        // Only headers/snippet/age — never a body (spec §6.6 rule 5).
        let rows: [[String: Any]] = messages.map { message in
            var row: [String: Any] = [
                "id": message.remoteId,
                "from": message.fromAddress,
                "read": message.isRead,
                "ageDays": Int(Date().timeIntervalSince(message.receivedAt) / 86400)
            ]
            if let subject = message.subject { row["subject"] = subject }
            if let snippet = message.snippet { row["snippet"] = String(snippet.prefix(200)) }
            return row
        }
        return """
            Classify each email into exactly one group.
            Groups: needsReply (a human is waiting on the user), awaitingReply (the \
            user sent the last message), safeToArchive (already handled / no action), \
            subscriptionNoise (newsletters, notifications, marketing).
            Reply with STRICT JSON only: {"<id>":"<group>"}. Use the group \
            identifiers and message ids exactly as given (ASCII, never translated). \
            Omit any email you are unsure about.
            Emails: \(jsonString(rows))
            """
    }

    // MARK: - MessageSummarizing

    public func summarize(
        _ body: MessageBody,
        language: String?,
        accountEmail: String
    ) async throws -> MessageSummary {
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
        let provider = provider(for: .summary)
        try await chargeBudgetPreCheck(
            capability: .summary,
            provider: provider,
            systemPrompt: systemPrompt,
            userPrompt: user,
            accountEmail: accountEmail
        )
        let (parsed, completion) = try await completeJSON(
            capability: .summary,
            system: systemPrompt,
            user: user,
            accountEmail: accountEmail
        )
        guard let summary = parsed["summary"] as? String, !summary.isEmpty else {
            throw LLMError.badResponse("summary: missing summary field")
        }
        let actionItems = (parsed["actionItems"] as? [Any])?
            .compactMap { $0 as? String }
            .filter { !$0.isEmpty } ?? []
        return MessageSummary(
            remoteId: body.remoteId,
            summary: summary,
            actionItems: actionItems,
            provider: completion.model
        )
    }

    // MARK: - MessageDrafting

    public func draftReplies(
        _ body: MessageBody,
        language: String?,
        accountEmail: String,
        count: Int
    ) async throws -> [String] {
        let languageTag = language.flatMap { $0.isEmpty ? nil : $0 } ?? outputLanguage
        let requested = max(1, min(count, 5))
        let text = String(body.text.prefix(12_000))
        let user = """
            Write \(requested) send-ready reply variants to this email. Each variant \
            must contain only the reply body, ready to send as plain text. Do not \
            summarize the email, do not explain your reasoning, and do not invent \
            facts, commitments, dates, or attachments. If essential information is \
            missing, keep the reply neutral and use a clear placeholder instead of \
            guessing. Make the variants meaningfully different in tone: concise, \
            warm, and formal. Keep signatures minimal. Write every variant in \
            \(Self.languageName(for: languageTag)).
            Reply with STRICT JSON only: {"variants":["...","..."]}.
            From: \(body.fromAddress)
            Subject: \(body.subject ?? "(none)")
            Body:
            \(text)
            """
        let provider = provider(for: .draft)
        try await chargeBudgetPreCheck(
            capability: .draft,
            provider: provider,
            systemPrompt: systemPrompt,
            userPrompt: user,
            accountEmail: accountEmail
        )
        let (parsed, _) = try await completeJSON(
            capability: .draft,
            system: systemPrompt,
            user: user,
            accountEmail: accountEmail
        )
        let variants = (parsed["variants"] as? [Any])?
            .compactMap { $0 as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        guard !variants.isEmpty else {
            throw LLMError.badResponse("draft: missing variants")
        }
        return variants
    }

    // MARK: - Budget helpers

    private func chargeBudgetPreCheck(
        capability: LLMCapability,
        provider: LLMProvider?,
        systemPrompt: String,
        userPrompt: String,
        accountEmail: String
    ) async throws {
        guard let provider else { return }
        let estPrompt = Self.estimatePromptTokens(systemPrompt) + Self.estimatePromptTokens(userPrompt)
        do {
            try await budget.checkBeforeCall(
                capability: capability.rawValue,
                model: provider.model,
                estimatedPromptTokens: estPrompt,
                estimatedCompletionTokens: Self.estimatedCompletionTokens,
                promptRate: provider.costPer1kPromptUsd,
                completionRate: provider.costPer1kCompletionUsd
            )
        } catch {
            logger.error("llm.budget.preCheckFailed", metadata: [
                "capability": .string(capability.rawValue),
                "model": .string(provider.model),
                "account": .string(accountEmail),
                "err": .string("\(error)"),
            ])
            throw error
        }
    }

    private func recordBudgetPostCall(
        capability: LLMCapability,
        provider: LLMProvider?,
        accountEmail: String,
        completion: LLMCompletion,
    ) async {
        guard provider != nil else { return }
        do {
            try await budget.record(
                capability: capability.rawValue,
                model: completion.model,
                accountEmail: accountEmail,
                promptTokens: completion.promptTokens ?? 0,
                completionTokens: completion.completionTokens ?? 0,
                costMicrosUSD: completion.costMicrosUSD ?? 0
            )
        } catch {
            logger.error("llm.budget.recordFailed", metadata: [
                "capability": .string(capability.rawValue),
                "model": .string(completion.model),
                "account": .string(accountEmail),
                "err": .string("\(error)"),
            ])
        }
    }

    // MARK: - Provider call + observability

    /// Calls the provider and parses strict JSON, retrying once when the model
    /// answers with prose or truncated JSON (observed intermittently with
    /// reasoning models). Logs size/finish reason only — never the content.
    private func completeJSON(
        capability: LLMCapability,
        system: String,
        user: String,
        accountEmail: String,
        attempts: Int = 2
    ) async throws -> (json: [String: Any], completion: LLMCompletion) {
        var lastError: Error = LLMError.badResponse("\(capability.rawValue): no attempt")
        for attempt in 1...max(1, attempts) {
            let completion = try await complete(capability: capability, system: system, user: user)
            await recordBudgetPostCall(
                capability: capability,
                provider: provider(for: capability),
                accountEmail: accountEmail,
                completion: completion
            )
            if let parsed = parseJSONObject(completion.text) {
                return (parsed, completion)
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
            let normalized = Self.normalize(error)
            // 5xx (transient) AND out-of-credit (401/402) both trip the
            // breaker. The latter is permanent until the user tops up,
            // so retrying it on every briefing refresh just burns
            // requests and fills the log — the log showed 104 identical
            // 402s before this change.
            switch normalized {
            case LLMError.http(let status) where (500..<600).contains(status):
                breaker.recordFailure(provider.name)
            case LLMError.insufficientCredit:
                breaker.recordFailure(provider.name)
            default:
                break
            }
            log(capability: capability, provider: provider, completion: nil, outcome: "\(normalized)")
            throw normalized
        }
    }

    /// Map a raw provider error onto the public `LLMError` surface so the
    /// route layer never has to know about vendor status codes. 401/402
    /// mean the vendor's account is unusable — surfacing them as
    /// `insufficientCredit` lets the client render "top up your provider"
    /// instead of a generic "AI error".
    static func normalize(_ error: Error) -> Error {
        if let llmError = error as? LLMError {
            if case .http(let status) = llmError, status == 401 || status == 402 {
                return LLMError.insufficientCredit(status: status)
            }
            return llmError
        }
        return error
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
