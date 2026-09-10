import Foundation

/// OpenAI-compatible chat-completions provider. Works for MiniMax-M3 国内版本
/// and any other endpoint that speaks `POST {base}/chat/completions`.
public struct OpenAICompatibleProvider: LLMProvider {
    public let name: String
    public let model: String
    public let costPer1kPromptUsd: Double?
    public let costPer1kCompletionUsd: Double?
    private let apiKey: String
    private let chatURL: URL
    private let session: URLSession
    private let allowedHosts: Set<String>

    public init(
        resolved: ResolvedProvider,
        session: URLSession = ProviderHTTP.makeSession()
    ) throws {
        let path = resolved.config.chatPath ?? "/chat/completions"
        guard let url = URL(string: resolved.config.baseURL + path),
              let host = url.host?.lowercased()
        else {
            throw LLMError.invalidBaseURL(resolved.config.baseURL)
        }
        self.name = resolved.name
        self.model = resolved.model
        self.costPer1kPromptUsd = resolved.config.costPer1kPromptUsd
        self.costPer1kCompletionUsd = resolved.config.costPer1kCompletionUsd
        self.apiKey = resolved.apiKey
        self.chatURL = url
        self.session = session
        self.allowedHosts = [host]
    }

    public func complete(
        capability: LLMCapability,
        system: String,
        user: String
    ) async throws -> LLMCompletion {
        var request = URLRequest(url: chatURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": model,
            "temperature": capability == .classify ? 0 : 0.2,
            // Reasoning models spend output tokens on the think block before
            // the answer; a small cap truncates the JSON and parses as garbage.
            "max_tokens": 4_096,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let started = Date()
        let (data, http) = try await ProviderHTTP.data(
            for: request,
            session: session,
            allowedHosts: allowedHosts
        )
        let latencyMs = Int(Date().timeIntervalSince(started) * 1000)
        guard (200..<300).contains(http.statusCode) else {
            throw LLMError.http(http.statusCode)
        }

        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = root["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"] as? String
        else {
            throw LLMError.badResponse("missing choices[0].message.content")
        }
        let usage = root["usage"] as? [String: Any]
        let promptTokens = usage?["prompt_tokens"] as? Int ?? 0
        let completionTokens = usage?["completion_tokens"] as? Int ?? 0
        let finishReason = choices.first?["finish_reason"] as? String
        return LLMCompletion(
            text: content,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            model: model,
            latencyMs: latencyMs,
            finishReason: finishReason,
            costMicrosUSD: Self.costMicros(
                promptTokens: promptTokens,
                completionTokens: completionTokens,
                promptRate: costPer1kPromptUsd,
                completionRate: costPer1kCompletionUsd
            )
        )
    }

    static func costMicros(
        promptTokens: Int,
        completionTokens: Int,
        promptRate: Double?,
        completionRate: Double?
    ) -> Int64? {
        guard let promptRate, let completionRate else { return nil }
        let usd = Double(promptTokens) / 1000.0 * promptRate
            + Double(completionTokens) / 1000.0 * completionRate
        return Int64((usd * 1_000_000).rounded())
    }
}
