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
        baseEnvironment: [String: String] = [:]
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
            let capUSD = Double(
                merged["LAGOON_BUDGET_USD_PER_MONTH"] ?? ""
            ) ?? 0
            await budget.setCapUSDPerMonth(capUSD)

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
    }
}
