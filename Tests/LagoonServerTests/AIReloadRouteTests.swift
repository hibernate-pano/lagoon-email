import XCTest
import Foundation
import Logging
import Hummingbird
import HummingbirdTesting
import NIOCore
import GRDB
@testable import LagoonServer
@testable import LagoonKit
@testable import LagoonAI

/// Covers `POST /api/ai/reload` — the route that makes a new key live
/// without a restart.
///
/// ## Why this route is worth a test file
///
/// The old product said "save your key, then restart the app". That was
/// an architecture accident, and the fix — a gateway behind a holder that
/// the route swaps — has two ways to go wrong that a user would feel and
/// a build would not catch:
///
/// * the reload **silently fails to configure** the gateway (the key is
///   stored, the app says "applied", and every AI call fails with
///   "not configured"), or
/// * the reload **keeps the old key** after the user cleared the field
///   (the AI stays on when the user asked to turn it off).
///
/// Both are covered below, along with the cap, which is a promise about
/// money and must take effect the moment it changes.
final class AIReloadRouteTests: XCTestCase {
    /// A provider config the test controls: one provider, one routing
    /// entry, a placeholder base URL that is never dialled.
    ///
    /// Written to a temp file because `ProviderRegistry` reads a file, and
    /// the repo's `config/providers.json` must not be what a test depends
    /// on — a change there would silently change these assertions.
    private func writeProviderConfig() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lagoon-ai-reload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("providers.json")
        let json = """
            {
              "version": 1,
              "providers": [
                {
                  "name": "test",
                  "baseURL": "https://provider.invalid/v1",
                  "apiKeyEnv": "\(AIEnvironmentKeys.apiKey)",
                  "model": "test-model",
                  "priority": 1,
                  "capabilities": ["summary", "classify", "draft"]
                }
              ],
              "routing": { "summary": "test" }
            }
            """
        try json.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private func makeApp(
        holder: AIGatewayHolder,
        budget: UsageBudget,
        baseEnvironment: [String: String]
    ) -> Application<RouterResponder<BasicRequestContext>> {
        let router = Router<BasicRequestContext>()
        AIRoutes.register(
            on: router,
            holder: holder,
            budget: budget,
            preferences: nil,
            logger: Logger(label: "ai-reload-tests"),
            baseEnvironment: baseEnvironment
        )
        return Application(router: router)
    }

    private func post(
        _ app: Application<RouterResponder<BasicRequestContext>>,
        _ environment: [String: String]
    ) async throws -> (status: HTTPResponse.Status, body: Data) {
        var thrown: (status: HTTPResponse.Status, body: Data)?
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/ai/reload",
                method: .post,
                body: ByteBuffer(data: try JSONSerialization.data(withJSONObject: [
                    "environment": environment
                ]))
            ) { response in
                thrown = (response.status, Data(buffer: response.body))
            }
        }
        return try XCTUnwrap(thrown, "the route answered nothing")
    }

    /// A reload with a key must leave the holder holding a **configured**
    /// gateway.
    ///
    /// Before the fix, saving a key could only be recorded in the
    /// Keychain; the running server kept the gateway it built at launch.
    /// This asserts the swap actually happened.
    func test_reloadWithAKey_configuresTheGateway() async throws {
        try await TestDatabase.withConnection { conn in
            let budget = try await UsageBudget(
                db: conn, capUSDPerMonth: 0,
                logger: Logger(label: "ai-reload-tests")
            )
            let holder = AIGatewayHolder(gateway: nil)
            let config = try writeProviderConfig()
            let app = makeApp(
                holder: holder,
                budget: budget,
                baseEnvironment: ["LAGOON_PROVIDER_CONFIG": config.path]
            )

            let (status, body) = try await post(app, [
                AIEnvironmentKeys.apiKey: "sk-test-key",
                AIEnvironmentKeys.baseURL: "https://provider.invalid/v1",
                AIEnvironmentKeys.model: "test-model",
            ])
            XCTAssertEqual(status, .ok)
            let decoded = try JSONDecoder().decode(AIStatus.self, from: body)
            XCTAssertTrue(decoded.configured, "the reload must report a configured AI")
            XCTAssertNotNil(holder.current, "the holder must hold the new gateway")
            XCTAssertTrue(holder.isConfigured)
        }
    }

    /// The status route must report the *reloaded* gateway, not the one
    /// that existed before the reload.
    ///
    /// The two used to be the same object because there was only ever
    /// one; now there are two, and the status route has to read the live
    /// one or the banner would lie.
    func test_aiStatusReportsTheReloadedGateway() async throws {
        try await TestDatabase.withConnection { conn in
            let budget = try await UsageBudget(
                db: conn, capUSDPerMonth: 0,
                logger: Logger(label: "ai-reload-tests")
            )
            let holder = AIGatewayHolder(gateway: nil)
            let config = try writeProviderConfig()
            let router = Router<BasicRequestContext>()
            AIRoutes.register(
                on: router, holder: holder, budget: budget, preferences: nil,
                logger: Logger(label: "ai-reload-tests"),
                baseEnvironment: ["LAGOON_PROVIDER_CONFIG": config.path]
            )
            BudgetRoutes.register(
                on: router, budget: budget, costTrackingAvailable: false, gateway: holder
            )
            let app = Application(router: router)

            // Before: no key, so no gateway.
            try await app.test(.router) { client in
                try await client.execute(uri: "/api/ai-status", method: .get) { response in
                    let decoded = try JSONDecoder().decode(
                        AIStatus.self, from: Data(buffer: response.body)
                    )
                    XCTAssertFalse(decoded.configured)
                }
            }

            _ = try await post(app, [AIEnvironmentKeys.apiKey: "sk-test-key"])

            // After: the same route must now say configured.
            try await app.test(.router) { client in
                try await client.execute(uri: "/api/ai-status", method: .get) { response in
                    let decoded = try JSONDecoder().decode(
                        AIStatus.self, from: Data(buffer: response.body)
                    )
                    XCTAssertTrue(decoded.configured, "the status route must read the live gateway")
                }
            }
        }
    }

    /// Clearing the key must turn the AI **off**.
    ///
    /// The client sends its whole stored map, and for the keys it owns
    /// absence is an answer. If the server merged its own copy of the key
    /// back in, "cleared the field" would be a lie and the AI would stay
    /// on — spending the user's money after they asked it to stop.
    ///
    /// The base environment deliberately carries an **old** key, because
    /// that is what production looks like: the app launched with a key in
    /// the Keychain, so the process environment still has it. A merge that
    /// let the base win would keep the AI alive forever, and the user
    /// would have no way to turn it off short of reinstalling.
    func test_reloadWithoutTheKey_turnsTheAIOff() async throws {
        try await TestDatabase.withConnection { conn in
            let budget = try await UsageBudget(
                db: conn, capUSDPerMonth: 0,
                logger: Logger(label: "ai-reload-tests")
            )
            let holder = AIGatewayHolder(gateway: nil)
            let config = try writeProviderConfig()
            let app = makeApp(
                holder: holder,
                budget: budget,
                baseEnvironment: [
                    "LAGOON_PROVIDER_CONFIG": config.path,
                    // The key the app booted with.
                    AIEnvironmentKeys.apiKey: "sk-the-old-key",
                ]
            )

            // The base environment alone already has a key, so the app
            // would boot with the AI on.
            let (status, body) = try await post(app, [
                AIEnvironmentKeys.baseURL: "https://provider.invalid/v1",
                AIEnvironmentKeys.model: "test-model",
            ])
            XCTAssertEqual(status, .ok)
            let decoded = try JSONDecoder().decode(AIStatus.self, from: body)
            XCTAssertFalse(decoded.configured, "clearing the key must turn the AI off")
            XCTAssertNil(holder.current)
        }
    }

    /// The monthly cap must take effect **now**.
    ///
    /// The budget read its cap at construction, so a user who raised their
    /// limit had to restart before the new limit meant anything — and a
    /// user who *lowered* it had to restart before the old, higher limit
    /// stopped applying. A cap is a promise about money.
    func test_reloadAppliesTheNewBudgetCapImmediately() async throws {
        try await TestDatabase.withConnection { conn in
            let budget = try await UsageBudget(
                db: conn, capUSDPerMonth: 10,
                logger: Logger(label: "ai-reload-tests")
            )
            let holder = AIGatewayHolder(gateway: nil)
            let config = try writeProviderConfig()
            let app = makeApp(
                holder: holder,
                budget: budget,
                baseEnvironment: ["LAGOON_PROVIDER_CONFIG": config.path]
            )

            let cap = await budget.capUSD
            XCTAssertEqual(cap, 10, accuracy: 0.0001)

            _ = try await post(app, [
                AIEnvironmentKeys.apiKey: "sk-test-key",
                AIEnvironmentKeys.budget: "2.5",
            ])
            let lowered = await budget.capUSD
            XCTAssertEqual(lowered, 2.5, accuracy: 0.0001, "the new cap must apply at once")
            let enforced = await budget.isEnforced
            XCTAssertTrue(enforced)
        }
    }

    /// A malformed body is a 400, not a 500 and not a silent success.
    func test_reloadRejectsAMalformedBody() async throws {
        try await TestDatabase.withConnection { conn in
            let budget = try await UsageBudget(
                db: conn, capUSDPerMonth: 0,
                logger: Logger(label: "ai-reload-tests")
            )
            let holder = AIGatewayHolder(gateway: nil)
            let app = makeApp(holder: holder, budget: budget, baseEnvironment: [:])

            var thrown: HTTPResponse.Status?
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/api/ai/reload",
                    method: .post,
                    body: ByteBuffer(string: "{not json")
                ) { response in
                    thrown = response.status
                }
            }
            XCTAssertEqual(thrown, .badRequest)
        }
    }

    /// An empty environment is not "reload with nothing".
    ///
    /// It is a malformed request: "turn the AI off" is expressed by
    /// omitting the key, not by sending an empty map.
    func test_reloadRejectsAnEmptyEnvironment() async throws {
        try await TestDatabase.withConnection { conn in
            let budget = try await UsageBudget(
                db: conn, capUSDPerMonth: 0,
                logger: Logger(label: "ai-reload-tests")
            )
            let holder = AIGatewayHolder(gateway: nil)
            let app = makeApp(holder: holder, budget: budget, baseEnvironment: [:])

            let (status, _) = try await post(app, [:])
            XCTAssertEqual(status, .badRequest)
        }
    }

    /// The base environment must survive the reload.
    ///
    /// `LAGOON_PROVIDER_CONFIG` lives there — it is the path to
    /// providers.json. A reload that dropped it would resolve no provider
    /// at all and report the AI as unconfigured, which reads as "your key
    /// is wrong" when the key is perfectly fine.
    func test_reloadKeepsTheProviderConfigPath() async throws {
        try await TestDatabase.withConnection { conn in
            let budget = try await UsageBudget(
                db: conn, capUSDPerMonth: 0,
                logger: Logger(label: "ai-reload-tests")
            )
            let holder = AIGatewayHolder(gateway: nil)
            let config = try writeProviderConfig()
            let app = makeApp(
                holder: holder,
                budget: budget,
                baseEnvironment: ["LAGOON_PROVIDER_CONFIG": config.path]
            )

            let (status, body) = try await post(app, [
                AIEnvironmentKeys.apiKey: "sk-test-key",
            ])
            XCTAssertEqual(status, .ok)
            let decoded = try JSONDecoder().decode(AIStatus.self, from: body)
            XCTAssertTrue(
                decoded.configured,
                "the providers.json path must survive the reload, or no provider resolves"
            )
        }
    }
}
