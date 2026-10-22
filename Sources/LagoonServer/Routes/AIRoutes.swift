import Foundation
import Hummingbird
import Logging
import LagoonKit
import LagoonAI

/// Reloads the AI configuration without a restart.
///
/// ## Why this route exists
///
/// The AI gateway used to be built once, at launch. The user went to
/// 「AI 设置」, pasted a key, pressed 保存 — and the app said "restart to
/// take effect".
///
/// That was an architecture accident, not a requirement. A key is a
/// credential; changing a credential does not require rebuilding the
/// process. What required a restart was that the routes captured the
/// gateway in a `let` at registration time.
///
/// So the gateway now lives behind a holder, and this route swaps it.
///
/// ## What the client sends, and why
///
/// The client sends the **new environment** (the AI keys it just stored)
/// rather than the server reading the Keychain itself. Two reasons:
///
/// 1. The Keychain belongs to the client module. The server is a
///    library that also runs as a standalone CLI with no Keychain
///    access, and it must not grow a dependency on the app's key store.
/// 2. The client already has the merged environment in hand — it wrote
///    it to the Keychain a moment ago. Sending it makes the reload
///    exactly the configuration that was stored, with no second read
///    that could disagree.
///
/// ## What this route does *not* do
///
/// It does not touch the mailbox. The AI is advisory; reloading it
/// changes no mail, creates no undo entry, and writes no audit row.
/// A "reload the AI" button that appeared in the action history would
/// be noise, and an AI-driven reload would violate the advisory-only
/// constitution outright.
public enum AIRoutes {
    /// The keys the client's map owns outright.
    ///
    /// The client sends its whole stored map, so for these keys the
    /// client's answer is the truth — including when the answer is
    /// *absence*. A user who cleared the API key wants the AI off; if
    /// the server merged its own copy of the key back in, "cleared"
    /// would be a lie.
    static let managedKeys = AIEnvironmentKeys.managed

    public static func register(
        on router: Router<BasicRequestContext>,
        holder: AIGatewayHolder,
        budget: UsageBudget,
        preferences: (any AdvicePreferenceProviding)? = nil,
        logger: Logger,
        baseEnvironment: [String: String] = [:],
        /// The session the probe talks to the provider with.
        ///
        /// Injected rather than created per request so a test can point it
        /// at a stub instead of the network — the probe's whole job is to
        /// make a request, and a test that cannot intercept it could only
        /// assert on the error path.
        session: URLSession = ProviderHTTP.makeSession()
    ) {
        // POST /api/ai/reload {environment: {...}}
        // 200 AIStatus | 400 malformed-environment
        router.post("api/ai/reload") { request, _ -> Response in
            struct ReloadRequest: Decodable {
                /// The AI keys, as the client stored them.
                let environment: [String: String]
            }
            let body: ReloadRequest
            do {
                body = try RouteJSON.decoder().decode(
                    ReloadRequest.self,
                    from: try await RouteParams.collectBody(request)
                )
            } catch {
                return RouteJSON.error(.badRequest, "malformed-environment")
            }
            // An empty environment is not "reload with nothing" — it is a
            // malformed request. A reload with an empty key means "turn
            // the AI off", and that is expressed by *omitting* the key,
            // not by sending an empty map.
            guard !body.environment.isEmpty else {
                return RouteJSON.error(.badRequest, "malformed-environment")
            }

            // The environment the gateway is built from: the server's own
            // base (the process environment plus what the launcher
            // injected — the providers.json path lives there, and without
            // it the gateway cannot resolve any provider at all), with
            // the client's map laid over it.
            var merged = baseEnvironment
            for (key, value) in body.environment {
                merged[key] = value
            }
            // …and for the keys the client owns, absence is an answer:
            // the user cleared the field, so the old value must not
            // survive in the process.
            for key in managedKeys where body.environment[key] == nil {
                merged.removeValue(forKey: key)
            }

            // The process environment follows, so anything else that reads
            // it — the provider registry, a future route — sees the same
            // values the app stored. The old values are *replaced*, not
            // merged: a key the user removed must not survive because it
            // was there before.
            for key in managedKeys {
                if let value = merged[key] {
                    setenv(key, value, 1)
                } else {
                    unsetenv(key)
                }
            }
            for (key, value) in body.environment where !managedKeys.contains(key) {
                setenv(key, value, 1)
            }

            // The budget cap can change with the key, and the budget
            // reads it at construction. A cap that was raised must take
            // effect now, not at the next launch — and a cap that was
            // *lowered* must stop the old, higher one from applying right
            // away. A cap is a promise about money; a promise that only
            // takes effect after a relaunch is not a promise.
            //
            // A cap that is not a number of dollars is refused here,
            // where it can still be answered with a 400. `Double("inf")`
            // parses, and the budget's conversion to micro-USD traps on a
            // non-finite value — which takes the whole server process
            // down with it, and the app with that.
            let capUSD = Double(merged[AIEnvironmentKeys.budget] ?? "")
            if let capUSD, !AIBudget.isValidCap(capUSD) {
                return RouteJSON.error(.badRequest, "invalid-budget-cap")
            }
            await budget.setCapUSDPerMonth(capUSD ?? 0)

            let gateway = AIGateway.fromEnvironment(
                environment: merged,
                budget: budget,
                preferences: preferences,
                logger: logger
            )
            holder.replace(with: gateway)
            if gateway == nil {
                logger.info("AI gateway disabled by reload")
            } else {
                logger.info("AI gateway reloaded")
            }
            return RouteJSON.response(AIStatus(
                configured: gateway?.isConfigured ?? false,
                creditExhausted: gateway?.creditExhausted ?? false,
                circuitOpen: gateway?.circuitOpen ?? false
            ))
        }

        // POST /api/ai/probe {environment: {...}}
        // 200 AIProbeResult | 400 malformed-environment
        router.post("api/ai/probe") { request, _ -> Response in
            struct ProbeRequest: Decodable {
                /// The AI keys, as the client would store them.
                let environment: [String: String]
            }
            let body: ProbeRequest
            do {
                body = try RouteJSON.decoder().decode(
                    ProbeRequest.self,
                    from: try await RouteParams.collectBody(request)
                )
            } catch {
                return RouteJSON.error(.badRequest, "malformed-environment")
            }
            guard !body.environment.isEmpty else {
                return RouteJSON.error(.badRequest, "malformed-environment")
            }

            // The same merge the reload route does — the server's own base
            // under the client's map — so the probe tests the same
            // configuration the app would run with. The difference is what
            // happens next: **nothing**. The probe does not touch the
            // process environment, does not rebuild the gateway and does
            // not write to the budget. Testing is not saving, and a
            // button that says 「测试连接」 must not leave the app
            // configured differently from how it found it.
            var merged = baseEnvironment
            for (key, value) in body.environment {
                merged[key] = value
            }
            for key in managedKeys where body.environment[key] == nil {
                merged.removeValue(forKey: key)
            }

            let result = await Self.probe(environment: merged, session: session)
            return RouteJSON.response(result)
        }
    }

    /// The largest monthly cap that can be expressed in micro-USD without
    /// overflowing, and that anybody could plausibly mean.
    ///
    /// The client enforces the same bound, so the two cannot disagree
    /// about what a saveable cap is.
    static let maximumCapUSD: Double = 1_000_000

    /// The probe's prompt.
    ///
    /// The smallest request that still proves the whole path: the
    /// endpoint answers, the key is accepted, the model exists and the
    /// answer comes back as a completion. It carries no mail text — the
    /// probe asks about nothing but itself.
    static let probeSystemPrompt = "You are a connectivity check. Reply with one word: ok"
    static let probeUserPrompt = "ping"

    /// Really talk to the provider.
    ///
    /// ## Why the provider, and not a hand-rolled request
    ///
    /// The provider is the only place in the codebase allowed to speak
    /// HTTP to a model vendor, and it is where the policy lives: https
    /// only, an explicit host allowlist, and never following a redirect
    /// (a redirect could hand the API key to a host that was never allowed
    /// to see it). A probe that bypassed it would be the one request in
    /// the app that could leak the key.
    ///
    /// ## What it costs
    ///
    /// One minimal completion — a fraction of a cent. It is deliberately
    /// *not* charged to the monthly budget or written to `usage_log`: it
    /// is not the user's mail being analysed, and a connectivity check
    /// that showed up in 「本月 AI 用量」 would be a number the user cannot
    /// explain.
    private static func probe(
        environment: [String: String],
        session: URLSession
    ) async -> AIProbeResult {
        let key = (environment[AIEnvironmentKeys.apiKey] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            return AIProbeResult(outcome: .invalidSettings, detail: "missing-api-key")
        }

        let resolved: [ResolvedProvider]
        do {
            resolved = try ProviderRegistry.load(environment: environment)
        } catch let error as LLMError {
            if case .invalidBaseURL = error {
                return AIProbeResult(outcome: .invalidSettings, detail: "invalid-base-url")
            }
            return AIProbeResult(outcome: .serviceError, detail: error.code)
        } catch {
            return AIProbeResult(outcome: .serviceError, detail: "provider-config-unavailable")
        }

        guard let target = pickPrimary(resolved, environment: environment, key: key) else {
            return AIProbeResult(outcome: .invalidSettings, detail: "no-provider")
        }

        do {
            let provider = try OpenAICompatibleProvider(resolved: target, session: session)
            _ = try await provider.complete(
                capability: .classify,
                system: probeSystemPrompt,
                user: probeUserPrompt
            )
            return AIProbeResult(outcome: .reachable, httpStatus: 200)
        } catch {
            return classify(error)
        }
    }

    /// The provider the running app would actually use.
    ///
    /// The registry applies the client's overrides to the **primary**
    /// provider only and returns the providers in priority order. The
    /// primary is the one carrying the base URL, model and key the client
    /// asked for; with a single provider in the file it is the first
    /// entry anyway. Matching on all three cannot pick the wrong one: a
    /// provider sharing all three would answer this request identically.
    private static func pickPrimary(
        _ resolved: [ResolvedProvider],
        environment: [String: String],
        key: String
    ) -> ResolvedProvider? {
        guard !resolved.isEmpty else { return nil }
        let base = normalizedBaseURL(environment[AIEnvironmentKeys.baseURL])
        let model = (environment[AIEnvironmentKeys.model] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = resolved.first(where: {
            $0.apiKey == key && $0.config.baseURL == base && $0.model == model
        }) {
            return match
        }
        return resolved.first
    }

    /// The base URL as the registry normalizes it: trimmed, and without a
    /// trailing slash.
    private static func normalizedBaseURL(_ raw: String?) -> String {
        let base = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return base.hasSuffix("/") ? String(base.dropLast()) : base
    }

    /// Map what came back onto the outcome the user is told.
    ///
    /// The distinctions that matter are the ones with different fixes: a
    /// refused key, a wrong endpoint, no credit, a rate limit and a
    /// provider that is simply down.
    private static func classify(_ error: Error) -> AIProbeResult {
        if let llm = error as? LLMError {
            switch llm {
            case .http(let status):
                return httpOutcome(status)
            case .invalidBaseURL:
                return AIProbeResult(outcome: .invalidSettings, detail: "invalid-base-url")
            case .redirectBlocked:
                return AIProbeResult(outcome: .redirected, detail: "redirect-blocked")
            case .blockedHost:
                return AIProbeResult(outcome: .invalidSettings, detail: "blocked-host")
            case .badResponse:
                return AIProbeResult(outcome: .unexpectedResponse, detail: "bad-response")
            case .notConfigured:
                return AIProbeResult(outcome: .invalidSettings, detail: "not-configured")
            case .insufficientCredit(let status):
                return AIProbeResult(outcome: .outOfCredit, httpStatus: status)
            case .circuitOpen, .budgetExceeded:
                return AIProbeResult(outcome: .serviceError, detail: llm.code)
            }
        }
        if let urlError = error as? URLError {
            if urlError.code == .timedOut {
                return AIProbeResult(outcome: .timedOut, detail: "timed-out")
            }
            return AIProbeResult(outcome: .unreachable, detail: String(urlError.code.rawValue))
        }
        return AIProbeResult(outcome: .serviceError, detail: "unknown-error")
    }

    /// A status code, named.
    private static func httpOutcome(_ status: Int) -> AIProbeResult {
        switch status {
        case 200..<300:
            return AIProbeResult(outcome: .reachable, httpStatus: status)
        case 401, 403:
            return AIProbeResult(outcome: .unauthorized, httpStatus: status)
        case 402:
            return AIProbeResult(outcome: .outOfCredit, httpStatus: status)
        case 404:
            return AIProbeResult(outcome: .notFound, httpStatus: status)
        case 429:
            return AIProbeResult(outcome: .rateLimited, httpStatus: status)
        case 400..<500:
            return AIProbeResult(outcome: .rejected, httpStatus: status)
        default:
            return AIProbeResult(outcome: .providerError, httpStatus: status)
        }
    }
}
