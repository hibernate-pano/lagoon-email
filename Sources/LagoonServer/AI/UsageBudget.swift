import Foundation
import Logging
import PostgresNIO
import LagoonKit
import LagoonAI

/// Per-month LLM cost cap (spec §6.5).
///
/// `usage_log` is the source of truth; the in-memory total is hydrated once at
/// startup and updated on every record. Designed for a single lagoon process
/// talking to one Postgres; concurrent multi-instance writes race and can let
/// the cap drift upward by one in-flight call's cost.
public actor UsageBudget: BudgetPolicy {
    private let db: PostgresConnection
    private let capMicrosUSD: Int64
    private let yearMonth: String
    private var totalMicrosUSD: Int64 = 0
    /// First crossing of 80% within the current month is logged as a warning;
    /// later calls suppress the message.
    private var warnedAt80 = false
    private let logger: Logger

    /// `capUSDPerMonth <= 0` disables enforcement (and warns once on startup).
    public init(
        db: PostgresConnection,
        capUSDPerMonth: Double,
        logger: Logger
    ) async throws {
        self.db = db
        self.capMicrosUSD = Int64((max(0, capUSDPerMonth) * 1_000_000).rounded())
        self.logger = logger
        self.yearMonth = Self.currentYearMonth()
        let initial = try await Self.sum(db: db, yearMonth: yearMonth)
        self.totalMicrosUSD = initial
        self.warnedAt80 = initial >= capForWarn(capMicros: capMicrosUSD)
        if capMicrosUSD <= 0 {
            logger.warning("llm.budget.disabled", metadata: [
                "reason": .string("LAGOON_BUDGET_USD_PER_MONTH is unset or <= 0"),
            ])
        } else {
            logger.info("llm.budget.ready", metadata: [
                "capUSD": .string(String(format: "%.4f", capUSD)),
                "initialMonthUSD": .string(String(format: "%.4f", currentMonthUSD)),
            ])
        }
    }

    public var capUSD: Double { Double(capMicrosUSD) / 1_000_000 }
    public var currentMonthUSD: Double { Double(totalMicrosUSD) / 1_000_000 }
    public var isEnforced: Bool { capMicrosUSD > 0 }

    /// Rough pre-call check using a known prompt size and a conservative
    /// completion estimate. Throws `budgetExceeded` if the call would breach
    /// the cap, so the API call (and its cost) never happens.
    public func checkBeforeCall(
        capability: String,
        model: String,
        estimatedPromptTokens: Int,
        estimatedCompletionTokens: Int,
        promptRate: Double?,
        completionRate: Double?
    ) throws {
        guard isEnforced else { return }
        let projected = Self.costMicros(
            promptTokens: estimatedPromptTokens,
            completionTokens: estimatedCompletionTokens,
            promptRate: promptRate,
            completionRate: completionRate
        )
        let next = totalMicrosUSD + projected
        if next > capMicrosUSD {
            throw LLMError.budgetExceeded(currentUSD: currentMonthUSD, capUSD: capUSD)
        }
        if !warnedAt80, capForWarn(capMicros: capMicrosUSD) > 0, next >= capForWarn(capMicros: capMicrosUSD) {
            logger.warning("llm.budget.warn80", metadata: [
                "currentUSD": .string(String(format: "%.4f", currentMonthUSD)),
                "capUSD": .string(String(format: "%.2f", capUSD)),
            ])
            warnedAt80 = true
        }
    }

    /// Records an actual call and updates the in-memory total. Does NOT throw
    /// on the cap: a single over-budget call is allowed so the user keeps the
    /// answer, but the next call's pre-check rejects.
    public func record(
        capability: String,
        model: String,
        accountEmail: String,
        promptTokens: Int,
        completionTokens: Int,
        costMicrosUSD: Int64,
    ) async throws {
        try await Self.insert(
            db: db,
            yearMonth: yearMonth,
            accountEmail: accountEmail,
            capability: capability,
            model: model,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            costMicrosUSD: costMicrosUSD
        )
        totalMicrosUSD += costMicrosUSD
        logger.info("llm.budget.charge", metadata: [
            "capability": .string(capability),
            "model": .string(model),
            "account": .string(accountEmail),
            "promptTokens": .string("\(promptTokens)"),
            "completionTokens": .string("\(completionTokens)"),
            "costMicros": .string("\(costMicrosUSD)"),
            "monthTotalMicros": .string("\(totalMicrosUSD)"),
        ])
    }

    private func capForWarn(capMicros: Int64) -> Int64 { capMicros * 80 / 100 }

    private static func currentYearMonth() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM"
        return f.string(from: Date())
    }

    private static func costMicros(
        promptTokens: Int,
        completionTokens: Int,
        promptRate: Double?,
        completionRate: Double?
    ) -> Int64 {
        guard let promptRate, let completionRate else { return 0 }
        let usd = Double(promptTokens) / 1000.0 * promptRate
            + Double(completionTokens) / 1000.0 * completionRate
        return Int64((usd * 1_000_000).rounded())
    }

    private static func sum(db: PostgresConnection, yearMonth: String) async throws -> Int64 {
        let rows = try await db.query(
            "SELECT COALESCE(SUM(cost_micro_usd), 0)::bigint AS total FROM usage_log WHERE year_month = $1",
            [PostgresData(string: yearMonth)]
        ).get()
        guard let row = rows.rows.first else { return 0 }
        return try row.makeRandomAccess()["total"].decode(Int64.self)
    }

    private static func insert(
        db: PostgresConnection,
        yearMonth: String,
        accountEmail: String,
        capability: String,
        model: String,
        promptTokens: Int,
        completionTokens: Int,
        costMicrosUSD: Int64,
    ) async throws {
        let sql = """
            INSERT INTO usage_log (
                year_month, account_email, capability, model,
                prompt_tokens, completion_tokens, cost_micro_usd
            ) VALUES ($1, $2, $3, $4, $5, $6, $7)
        """
        try await db.query(sql, [
            PostgresData(string: yearMonth),
            PostgresData(string: accountEmail),
            PostgresData(string: capability),
            PostgresData(string: model),
            PostgresData(int: promptTokens),
            PostgresData(int: completionTokens),
            PostgresData(int64: costMicrosUSD),
        ]).get()
    }
}
