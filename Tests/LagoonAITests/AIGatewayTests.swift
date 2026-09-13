import XCTest
import Foundation
import LagoonKit
@testable import LagoonAI

final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var captured: [URLRequest] = []
    private static let lock = NSLock()

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        handler = nil
        captured = []
    }

    static func set(_ handler: @escaping (URLRequest) -> (Int, Data)) {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler
        captured = []
    }

    static var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return captured
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.lock.lock()
        Self.captured.append(request)
        let handler = Self.handler
        Self.lock.unlock()
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, data) = handler(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private actor RecordingBudget: BudgetPolicy {
    struct RecordedCall: Equatable {
        let capability: String
        let accountEmail: String
        let promptTokens: Int
        let completionTokens: Int
    }

    private(set) var checks: [String] = []
    private(set) var records: [RecordedCall] = []

    func checkBeforeCall(
        capability: String,
        model: String,
        estimatedPromptTokens: Int,
        estimatedCompletionTokens: Int,
        promptRate: Double?,
        completionRate: Double?
    ) async throws {
        checks.append(capability)
    }

    func record(
        capability: String,
        model: String,
        accountEmail: String,
        promptTokens: Int,
        completionTokens: Int,
        costMicrosUSD: Int64
    ) async throws {
        records.append(RecordedCall(
            capability: capability,
            accountEmail: accountEmail,
            promptTokens: promptTokens,
            completionTokens: completionTokens
        ))
    }
}

final class AIGatewayTests: XCTestCase {
    private var configURL: URL!

    /// Inside a `URLProtocol`, `httpBody` is nil — the bytes live in `httpBodyStream`.
    private func bodyData(_ request: URLRequest?) -> Data {
        if let body = request?.httpBody { return body }
        guard let stream = request?.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    override func setUpWithError() throws {
        StubURLProtocol.reset()
        configURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lagoon-providers-\(UUID().uuidString).json")
        try """
            {
              "version": 1,
              "providers": [
                {
                  "name": "stub",
                  "baseURL": "https://llm.example.com/v1",
                  "apiKeyEnv": "STUB_LLM_KEY",
                  "model": "stub-model",
                  "priority": 1,
                  "capabilities": ["summary", "classify"]
                }
              ],
              "routing": { "summary": "stub", "classify": "stub" }
            }
            """.write(to: configURL, atomically: true, encoding: .utf8)
    }

    override func tearDown() {
        StubURLProtocol.reset()
        try? FileManager.default.removeItem(at: configURL)
        super.tearDown()
    }

    private func stubSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    private func gateway(budget: BudgetPolicy = NoBudgetPolicy()) throws -> AIGateway {
        let resolved = try ProviderRegistry.load(
            environment: ["STUB_LLM_KEY": "test-key"],
            fileURL: configURL
        )
        XCTAssertEqual(resolved.count, 1)
        let provider = try OpenAICompatibleProvider(resolved: resolved[0], session: stubSession())
        return AIGateway(
            providers: [provider],
            routing: ["summary": "stub", "classify": "stub", "draft": "stub"],
            budget: budget
        )
    }

    private func message(remoteId: String, from: String = "alice@example.com") -> MessageHeader {
        MessageHeader(
            id: UUID(),
            accountId: UUID(),
            remoteId: remoteId,
            threadId: "t-\(remoteId)",
            fromAddress: from,
            fromName: "Alice",
            subject: "Subject \(remoteId)",
            snippet: "snippet",
            receivedAt: Date().addingTimeInterval(-3600),
            isRead: false,
            isArchived: false
        )
    }

    // MARK: - Config

    func test_fromEnvironment_returnsNilWithoutKey() {
        let ai = AIGateway.fromEnvironment(environment: [:], fileURL: configURL, session: stubSession())
        XCTAssertNil(ai, "no API key configured must disable the gateway, not crash")
    }

    func test_fromEnvironment_buildsGatewayWhenKeyPresent() {
        let ai = AIGateway.fromEnvironment(
            environment: ["STUB_LLM_KEY": "k"],
            fileURL: configURL,
            session: stubSession()
        )
        XCTAssertNotNil(ai)
    }

    func test_registry_envOverrideWinsOverFile() throws {
        let resolved = try ProviderRegistry.load(
            environment: [
                "STUB_LLM_KEY": "k",
                "LLM_PROVIDER_PRIMARY_BASE_URL": "https://override.example.com/v2",
                "LLM_PROVIDER_PRIMARY_MODEL": "override-model"
            ],
            fileURL: configURL
        )
        XCTAssertEqual(resolved[0].config.baseURL, "https://override.example.com/v2")
        XCTAssertEqual(resolved[0].model, "override-model")
    }

    func test_registry_rejectsNonHTTPSBaseURL() {
        XCTAssertThrowsError(
            try ProviderRegistry.load(
                environment: [
                    "STUB_LLM_KEY": "k",
                    "LLM_PROVIDER_PRIMARY_BASE_URL": "http://llm.example.com/v1"
                ],
                fileURL: configURL
            )
        )
    }

    // MARK: - classify

    func test_classify_sendsHeadersOnlyNeverBodies() async throws {
        StubURLProtocol.set { _ in
            (200, Data(#"{"choices":[{"message":{"content":"{\"g1\":\"needsReply\"}"}}],"usage":{"prompt_tokens":10,"completion_tokens":5}}"#.utf8))
        }
        let ai = try gateway()
        let result = try await ai.classify([message(remoteId: "g1")], accountEmail: "me@example.com", language: nil)
        XCTAssertEqual(result["g1"], .needsReply)

        let body = bodyData(StubURLProtocol.requests.first)
        let text = String(data: body, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("\"model\":\"stub-model\""))
        XCTAssertTrue(text.contains("\"temperature\":0"))
        XCTAssertTrue(text.contains("g1"))
        XCTAssertFalse(text.lowercased().contains("\"body\""), "classify prompt must not carry a body field")
        XCTAssertEqual(StubURLProtocol.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
    }

    func test_classify_batchesLargeFeedsIntoParseableResponses() async throws {
        nonisolated(unsafe) var call = 0
        StubURLProtocol.set { _ in
            let start = call * 12
            call += 1
            let content = try! JSONSerialization.data(
                withJSONObject: Dictionary(uniqueKeysWithValues: (start..<min(start + 12, 25)).map {
                    ("m\($0)", "needsReply")
                })
            )
            let envelope: [String: Any] = [
                "choices": [["message": ["content": String(decoding: content, as: UTF8.self)]]]
            ]
            let data = try! JSONSerialization.data(withJSONObject: envelope)
            return (200, data)
        }

        let ai = try gateway()
        let messages = (0..<25).map { message(remoteId: "m\($0)") }
        let result = try await ai.classify(messages, accountEmail: "me@example.com", language: nil)

        XCTAssertEqual(call, 3)
        XCTAssertEqual(result.count, 25)
        XCTAssertEqual(result["m0"], .needsReply)
        XCTAssertEqual(result["m24"], .needsReply)
    }

    func test_classify_ignoresUnknownIdsAndGroups() async throws {
        StubURLProtocol.set { _ in
            (200, Data(#"{"choices":[{"message":{"content":"{\"g1\":\"needsReply\",\"g2\":\"nonsense\",\"g3\":\"pinned\"}"}}]}"#.utf8))
        }
        let ai = try gateway()
        let result = try await ai.classify(
            [message(remoteId: "g1"), message(remoteId: "g2"), message(remoteId: "g3")],
            accountEmail: "me@example.com",
            language: nil
        )
        XCTAssertEqual(result, ["g1": .needsReply], "unknown group and local-only pinned must be dropped")
    }

    func test_classify_toleratesFencedJSON() async throws {
        StubURLProtocol.set { _ in
            (200, Data(#"{"choices":[{"message":{"content":"```json\n{\"g1\":\"safeToArchive\"}\n```"}}]}"#.utf8))
        }
        let ai = try gateway()
        let result = try await ai.classify([message(remoteId: "g1")], accountEmail: "me@example.com", language: nil)
        XCTAssertEqual(result["g1"], .safeToArchive)
    }

    func test_classify_throwsOnGarbage() async throws {
        StubURLProtocol.set { _ in
            (200, Data(#"{"choices":[{"message":{"content":"I cannot help with that"}}]}"#.utf8))
        }
        let ai = try gateway()
        do {
            _ = try await ai.classify([message(remoteId: "g1")], accountEmail: "me@example.com", language: nil)
            XCTFail("expected badResponse")
        } catch let error as LLMError {
            guard case .badResponse = error else { return XCTFail("unexpected \(error)") }
        }
    }

    // MARK: - summarize

    func test_summarize_parsesSummaryAndActionItems() async throws {
        StubURLProtocol.set { _ in
            (200, Data(#"{"choices":[{"message":{"content":"{\"summary\":\"Short.\",\"actionItems\":[\"Reply\",\"Pay invoice\"]}"}}],"usage":{"prompt_tokens":100,"completion_tokens":20}}"#.utf8))
        }
        let ai = try gateway()
        let body = MessageBody(
            remoteId: "g1",
            subject: "Invoice",
            fromAddress: "billing@example.com",
            fromName: "Billing",
            toAddress: "me@example.com",
            receivedAt: Date(),
            text: "Please pay by Friday."
        )
        let summary = try await ai.summarize(body, language: nil, accountEmail: "test@example.com")
        XCTAssertEqual(summary.summary, "Short.")
        XCTAssertEqual(summary.actionItems, ["Reply", "Pay invoice"])
        XCTAssertEqual(summary.provider, "stub-model")
    }

    /// The summary and action items must come back in the configured language,
    /// while the JSON keys stay English (they are parsed, not displayed).
    func test_summarize_requestsConfiguredOutputLanguage() async throws {
        StubURLProtocol.set { _ in
            (200, Data(#"{"choices":[{"message":{"content":"{\"summary\":\"简短。\",\"actionItems\":[\"回复\"]}"}}]}"#.utf8))
        }
        let resolved = try ProviderRegistry.load(
            environment: ["STUB_LLM_KEY": "test-key"],
            fileURL: configURL
        )
        let provider = try OpenAICompatibleProvider(resolved: resolved[0], session: stubSession())
        let ai = AIGateway(
            providers: [provider],
            routing: ["summary": "stub", "classify": "stub"],
            outputLanguage: "zh-Hans"
        )
        let body = MessageBody(
            remoteId: "g1",
            subject: "Invoice",
            fromAddress: "billing@example.com",
            fromName: "Billing",
            toAddress: "me@example.com",
            receivedAt: Date(),
            text: "Please pay by Friday."
        )
        let summary = try await ai.summarize(body, language: nil, accountEmail: "test@example.com")
        XCTAssertEqual(summary.summary, "简短。")
        XCTAssertEqual(summary.actionItems, ["回复"])

        let prompt = String(data: bodyData(StubURLProtocol.requests.first), encoding: .utf8) ?? ""
        XCTAssertTrue(
            prompt.contains("Simplified Chinese"),
            "the prompt must name the output language"
        )
        XCTAssertTrue(
            prompt.contains("Keep the JSON keys exactly"),
            "JSON keys must stay English or parsing breaks"
        )
    }

    /// Classification identifiers are parsed, so they must never be translated.
    func test_classify_prompt_pinsIdentifiersToASCII() async throws {
        StubURLProtocol.set { _ in
            (200, Data(#"{"choices":[{"message":{"content":"{\"g1\":\"needsReply\"}"}}]}"#.utf8))
        }
        let ai = try gateway()
        _ = try await ai.classify([message(remoteId: "g1")], accountEmail: "me@example.com", language: nil)
        let prompt = String(data: bodyData(StubURLProtocol.requests.first), encoding: .utf8) ?? ""
        XCTAssertTrue(prompt.contains("never translated"))
    }

    func test_languageName_mapsTags() {
        XCTAssertEqual(AIGateway.languageName(for: "zh-Hans"), "Simplified Chinese (简体中文)")
        XCTAssertEqual(AIGateway.languageName(for: "zh-TW"), "Traditional Chinese (繁體中文)")
        XCTAssertEqual(AIGateway.languageName(for: "en"), "English")
        XCTAssertEqual(AIGateway.languageName(for: "xx"), "xx")
    }

    func test_summarize_truncatesHugeBody() async throws {
        StubURLProtocol.set { _ in
            (200, Data(#"{"choices":[{"message":{"content":"{\"summary\":\"s\",\"actionItems\":[]}"}}]}"#.utf8))
        }
        let ai = try gateway()
        let body = MessageBody(
            remoteId: "g1",
            subject: nil,
            fromAddress: "a@b.com",
            fromName: nil,
            toAddress: nil,
            receivedAt: Date(),
            text: String(repeating: "x", count: 50_000)
        )
        _ = try await ai.summarize(body, language: nil, accountEmail: "test@example.com")
        let text = String(data: bodyData(StubURLProtocol.requests.first), encoding: .utf8) ?? ""
        XCTAssertLessThan(text.count, 20_000, "body must be truncated before leaving the process")
    }

    // MARK: - draft

    func test_draftReplies_usesDedicatedPromptAndRecordsBudget() async throws {
        StubURLProtocol.set { _ in
            (200, Data(#"{"choices":[{"message":{"content":"{\"variants\":[\"Short reply\",\"Warm reply\",\"Formal reply\"]}"}}],"usage":{"prompt_tokens":120,"completion_tokens":30}}"#.utf8))
        }
        let budget = RecordingBudget()
        let ai = try gateway(budget: budget)
        let body = MessageBody(
            remoteId: "g1",
            subject: "Project update",
            fromAddress: "alice@example.com",
            fromName: "Alice",
            toAddress: "me@example.com",
            receivedAt: Date(),
            text: "Can you confirm the deadline?"
        )

        let variants = try await ai.draftReplies(
            body,
            language: "en",
            accountEmail: "me@example.com",
            count: 3
        )

        XCTAssertEqual(variants, ["Short reply", "Warm reply", "Formal reply"])
        let prompt = String(data: bodyData(StubURLProtocol.requests.first), encoding: .utf8) ?? ""
        XCTAssertTrue(prompt.contains("send-ready reply variants"))
        XCTAssertTrue(prompt.contains("Do not summarize"))
        let records = await budget.records
        XCTAssertEqual(records, [
            RecordingBudget.RecordedCall(
                capability: "draft",
                accountEmail: "me@example.com",
                promptTokens: 120,
                completionTokens: 30
            )
        ])
    }

    func test_classify_recordsBudgetAfterSuccessfulCall() async throws {
        StubURLProtocol.set { _ in
            (200, Data(#"{"choices":[{"message":{"content":"{\"g1\":\"needsReply\"}"}}],"usage":{"prompt_tokens":10,"completion_tokens":5}}"#.utf8))
        }
        let budget = RecordingBudget()
        let ai = try gateway(budget: budget)
        _ = try await ai.classify(
            [message(remoteId: "g1")],
            accountEmail: "me@example.com",
            language: nil
        )
        let records = await budget.records
        XCTAssertEqual(records.map(\.capability), ["classify"])
    }

    // MARK: - reasoning-model robustness

    /// Reasoning models intermittently answer with prose or truncated JSON.
    /// The gateway retries once instead of failing the user's summary.
    func test_summarize_retriesOnceOnUnparseableOutput() async throws {
        nonisolated(unsafe) var call = 0
        StubURLProtocol.set { _ in
            call += 1
            if call == 1 {
                return (200, Data(#"{"choices":[{"message":{"content":"I cannot help with that"},"finish_reason":"stop"}]}"#.utf8))
            }
            return (200, Data(#"{"choices":[{"message":{"content":"{\"summary\":\"ok\",\"actionItems\":[]}"},"finish_reason":"stop"}]}"#.utf8))
        }
        let ai = try gateway()
        let body = MessageBody(
            remoteId: "g1",
            subject: "s",
            fromAddress: "a@b.com",
            fromName: nil,
            toAddress: nil,
            receivedAt: Date(),
            text: "body"
        )
        let summary = try await ai.summarize(body, language: "en", accountEmail: "test@example.com")
        XCTAssertEqual(summary.summary, "ok")
        XCTAssertEqual(StubURLProtocol.requests.count, 2, "exactly one retry")

        let sent = String(data: bodyData(StubURLProtocol.requests.first), encoding: .utf8) ?? ""
        XCTAssertTrue(sent.contains("\"max_tokens\""), "a small default cap truncates the JSON")
    }

    /// A model that keeps answering garbage must fail after the retry, not loop.
    func test_summarize_givesUpAfterOneRetry() async throws {
        StubURLProtocol.set { _ in
            (200, Data(#"{"choices":[{"message":{"content":"no json here"},"finish_reason":"length"}]}"#.utf8))
        }
        let ai = try gateway()
        let body = MessageBody(
            remoteId: "g1",
            subject: nil,
            fromAddress: "a@b.com",
            fromName: nil,
            toAddress: nil,
            receivedAt: Date(),
            text: "body"
        )
        do {
            _ = try await ai.summarize(body, language: nil, accountEmail: "test@example.com")
            XCTFail("expected badResponse")
        } catch let error as LLMError {
            guard case .badResponse = error else { return XCTFail("unexpected \(error)") }
        }
        XCTAssertEqual(StubURLProtocol.requests.count, 2, "one attempt + one retry, then stop")
    }

    // MARK: - circuit breaker

    func test_circuitBreaker_opensAfterFiveConsecutive5xx() async throws {
        StubURLProtocol.set { _ in (500, Data("{}".utf8)) }
        let ai = try gateway()
        for _ in 0..<5 {
            _ = try? await ai.classify([message(remoteId: "g1")], accountEmail: "me@example.com", language: nil)
        }
        let callsBefore = StubURLProtocol.requests.count
        do {
            _ = try await ai.classify([message(remoteId: "g1")], accountEmail: "me@example.com", language: nil)
            XCTFail("expected circuitOpen")
        } catch let error as LLMError {
            guard case .circuitOpen = error else { return XCTFail("unexpected \(error)") }
        }
        XCTAssertEqual(StubURLProtocol.requests.count, callsBefore, "open circuit must not call the provider")
    }

    func test_circuitBreaker_successResetsFailureCount() async throws {
        var failNext = true
        StubURLProtocol.set { _ in
            defer { failNext = false }
            return failNext ? (500, Data("{}".utf8)) : (200, Data(#"{"choices":[{"message":{"content":"{\"g1\":\"needsReply\"}"}}]}"#.utf8))
        }
        let ai = try gateway()
        _ = try? await ai.classify([message(remoteId: "g1")], accountEmail: "me@example.com", language: nil)
        _ = try await ai.classify([message(remoteId: "g1")], accountEmail: "me@example.com", language: nil)
        // After a success, four more failures must not open the breaker.
        StubURLProtocol.set { _ in (500, Data("{}".utf8)) }
        for _ in 0..<4 {
            _ = try? await ai.classify([message(remoteId: "g1")], accountEmail: "me@example.com", language: nil)
        }
        let callsBefore = StubURLProtocol.requests.count
        _ = try? await ai.classify([message(remoteId: "g1")], accountEmail: "me@example.com", language: nil)
        XCTAssertEqual(StubURLProtocol.requests.count, callsBefore + 1, "four failures must not open the breaker")
    }

    // MARK: - outbound guard

    func test_providerHTTP_blocksUnlistedHost() {
        XCTAssertThrowsError(
            try ProviderHTTP.validate(
                URL(string: "https://evil.example.com/v1/chat/completions")!,
                allowedHosts: ["llm.example.com"]
            )
        )
    }

    func test_providerHTTP_blocksNonHTTPS() {
        XCTAssertThrowsError(
            try ProviderHTTP.validate(
                URL(string: "http://llm.example.com/v1")!,
                allowedHosts: ["llm.example.com"]
            )
        )
    }

    func test_providerHTTP_blocksRedirect() async throws {
        let session = stubSession()
        StubURLProtocol.set { _ in (302, Data()) }
        var request = URLRequest(url: URL(string: "https://llm.example.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        do {
            _ = try await ProviderHTTP.data(for: request, session: session, allowedHosts: ["llm.example.com"])
            XCTFail("expected redirectBlocked")
        } catch let error as LLMError {
            guard case .redirectBlocked = error else { return XCTFail("unexpected \(error)") }
        }
    }
}
