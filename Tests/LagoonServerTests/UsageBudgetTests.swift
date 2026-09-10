import XCTest
import Logging
import PostgresNIO
import LagoonAI
import LagoonKit
@testable import LagoonServer

/// Covers the monthly LLM cost cap (spec §6.5). Runs against the shared
/// `lagoon_test` DB; each test uses a unique account email so cleanup is
/// row-scoped.
final class UsageBudgetTests: XCTestCase {
    private static let testLogger = Logger(label: "usage-budget-tests")
    private let account = "budget-\(UUID().uuidString)"

    private final class Fixture {
        let budget: UsageBudget
        let connection: PostgresConnection

        init(budget: UsageBudget, connection: PostgresConnection) {
            self.budget = budget
            self.connection = connection
        }

        func close() async {
            try? await connection.close()
        }
    }

    override func tearDown() async throws {
        let clean = account
        _ = try? await TestDatabase.withConnection { conn in
            try? await conn.query(
                "DELETE FROM usage_log WHERE account_email = $1",
                [PostgresData(string: clean)]
            ).get()
        }
    }

    private func makeBudget(capUSD: Double) async throws -> Fixture {
        guard let conn = try await TestDatabase.connect() else {
            throw XCTSkip("no safe test database; set DATABASE_URL to a *_test loopback")
        }
        let budget = try await UsageBudget(
            db: conn,
            capUSDPerMonth: capUSD,
            logger: Self.testLogger
        )
        return Fixture(budget: budget, connection: conn)
    }

    func test_disabledBudget_neverThrows() async throws {
        let f = try await makeBudget(capUSD: 0)
        defer { Task { await f.close() } }
        try await f.budget.checkBeforeCall(
            capability: "summary",
            model: "m",
            estimatedPromptTokens: 1_000_000,
            estimatedCompletionTokens: 1_000_000,
            promptRate: 100,
            completionRate: 100
        )
        try await f.budget.record(
            capability: "summary", model: "m", accountEmail: account,
            promptTokens: 1_000_000, completionTokens: 1_000_000,
            costMicrosUSD: 200_000_000
        )
    }

    func test_underCap_passAndAccumulates() async throws {
        let f = try await makeBudget(capUSD: 1.0)
        defer { Task { await f.close() } }
        try await f.budget.record(
            capability: "summary", model: "m", accountEmail: account,
            promptTokens: 100_000, completionTokens: 100_000,
            costMicrosUSD: 100_000   // $0.10
        )
        try await f.budget.record(
            capability: "summary", model: "m", accountEmail: account,
            promptTokens: 100_000, completionTokens: 100_000,
            costMicrosUSD: 200_000   // $0.20
        )
        let total = await f.budget.currentMonthUSD
        XCTAssertEqual(total, 0.30, accuracy: 0.0001)
    }

    func test_overCap_preCheckThrows() async throws {
        let f = try await makeBudget(capUSD: 0.10)
        defer { Task { await f.close() } }
        try await f.budget.record(
            capability: "summary", model: "m", accountEmail: account,
            promptTokens: 1_000, completionTokens: 1_000,
            costMicrosUSD: 80_000   // $0.08
        )
        do {
            try await f.budget.checkBeforeCall(
                capability: "summary", model: "m",
                estimatedPromptTokens: 10_000, estimatedCompletionTokens: 10_000,
                promptRate: 5, completionRate: 5  // estimated $0.10+
            )
            XCTFail("approaching the cap must throw")
        } catch {
            // expected
        }
    }

    /// Regression: a real classify-shape call (8k prompt + 2k completion)
    /// at $0.005/$0.015 per 1k tokens must exceed a $0.001 cap. This is the
    /// exact case the live AIGateway hits on the first refresh after a fresh
    /// server start with rates configured.
    func test_realisticCall_exceedsTinyCap() async throws {
        let f = try await makeBudget(capUSD: 0.001)
        defer { Task { await f.close() } }
        do {
            try await f.budget.checkBeforeCall(
                capability: "classify", model: "MiniMax-M3",
                estimatedPromptTokens: 8_000,
                estimatedCompletionTokens: 2_000,
                promptRate: 0.005,
                completionRate: 0.015
            )
            XCTFail("a real classify call must exceed a $0.001 cap")
        } catch let error as LLMError {
            guard case .budgetExceeded = error else {
                return XCTFail("expected budgetExceeded, got \(error)")
            }
        }
    }

    /// Regression: record actually inserts. Without it the audit log stays
    /// empty and the cap cannot be enforced after restart.
    func test_recordInsertsRow() async throws {
        let f = try await makeBudget(capUSD: 1)
        defer { Task { await f.close() } }
        let clean = account
        try await f.budget.record(
            capability: "summary", model: "m", accountEmail: clean,
            promptTokens: 100, completionTokens: 50,
            costMicrosUSD: 1234
        )
        let verify = try await TestDatabase.connect()!
        defer { Task { try? await verify.close() } }
        let count = try await verify.query(
            "SELECT count(*) AS c FROM usage_log WHERE account_email = $1",
            [PostgresData(string: clean)]
        ).get()
        let n = try count.rows.first!.makeRandomAccess()["c"].decode(Int.self)
        XCTAssertEqual(n, 1)
    }

    func test_ratesMissing_preCheckPasses() async throws {
        let f = try await makeBudget(capUSD: 0.001)
        defer { Task { await f.close() } }
        try await f.budget.checkBeforeCall(
            capability: "summary", model: "m",
            estimatedPromptTokens: 1_000_000, estimatedCompletionTokens: 1_000_000,
            promptRate: nil, completionRate: nil
        )
        try await f.budget.record(
            capability: "summary", model: "m", accountEmail: account,
            promptTokens: 5_000, completionTokens: 1_000,
            costMicrosUSD: 0
        )
    }

    func test_recordPersistsAcrossRestart() async throws {
        do {
            let f = try await makeBudget(capUSD: 10)
            try await f.budget.record(
                capability: "summary", model: "m", accountEmail: account,
                promptTokens: 1_000, completionTokens: 500,
                costMicrosUSD: 250_000   // $0.25
            )
            await f.close()
        }
        let f2 = try await makeBudget(capUSD: 10)
        defer { Task { await f2.close() } }
        let total = await f2.budget.currentMonthUSD
        XCTAssertEqual(total, 0.25, accuracy: 0.0001)
    }
}