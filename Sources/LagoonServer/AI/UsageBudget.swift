import Foundation
import Logging
import GRDB
import LagoonKit
import LagoonAI

/// Per-month LLM cost cap (spec §6.5).
///
/// `usage_log` is the source of truth; the in-memory total is hydrated once at
/// startup and updated on every record. Designed for a single lagoon process
/// talking to one Postgres; concurrent multi-instance writes race and can let
/// the cap drift upward by one in-flight call's cost.
public actor UsageBudget: BudgetPolicy {
    private let db: LagoonDB
    /// The monthly cap, in micro-USD. `var` because the user can change
    /// it from 「AI 设置」 and the new value must take effect without a
    /// restart — see `setCapUSDPerMonth(_:)`.
    private var capMicrosUSD: Int64
    private let yearMonth: String
    private var totalMicrosUSD: Int64 = 0
    private var callsThisMonth = 0
    /// First crossing of 80% within the current month is logged as a warning;
    /// later calls suppress the message.
    private var warnedAt80 = false
    private let logger: Logger

    /// `capUSDPerMonth <= 0` disables enforcement (and warns once on startup).
    public init(
        db: LagoonDB,
        capUSDPerMonth: Double,
        logger: Logger
    ) async throws {
        self.db = db
        self.capMicrosUSD = Int64((max(0, capUSDPerMonth) * 1_000_000).rounded())
        self.logger = logger
        self.yearMonth = Self.currentYearMonth()
        let summary = try await Self.summary(db: db, yearMonth: yearMonth)
        self.totalMicrosUSD = summary.costMicrosUSD
        self.callsThisMonth = summary.callCount
        self.warnedAt80 = summary.costMicrosUSD >= capForWarn(capMicros: capMicrosUSD)
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
    public var callCount: Int { callsThisMonth }
    public var isEnforced: Bool { capMicrosUSD > 0 }

    /// Replaces the monthly cap.
    ///
    /// The cap used to be fixed at construction, so a user who raised
    /// their limit in 「AI 设置」 had to restart the app before the new
    /// limit meant anything — and a user who *lowered* it had to restart
    /// before the old, higher limit stopped applying. Neither is
    /// acceptable: the cap is a promise about money, and a promise that
    /// only takes effect after a relaunch is not a promise.
    ///
    /// A cap of zero or less disables enforcement, which is what an
    /// empty budget field means.
    public func setCapUSDPerMonth(_ value: Double) {
        capMicrosUSD = Int64((max(0, value) * 1_000_000).rounded())
        if capMicrosUSD <= 0 {
            logger.warning("llm.budget.disabled", metadata: [
                "reason": .string("the monthly cap was set to 0"),
            ])
        } else {
            logger.info("llm.budget.capChanged", metadata: [
                "capUSD": .string(String(format: "%.4f", capUSD)),
            ])
        }
    }

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
        callsThisMonth += 1
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

    private struct MonthSummary {
        let costMicrosUSD: Int64
        let callCount: Int
    }

    private static func summary(db: LagoonDB, yearMonth: String) async throws -> MonthSummary {
        let row = try db.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT COALESCE(SUM(cost_micro_usd), 0) AS total, COUNT(*) AS calls FROM usage_log WHERE year_month = ?",
                arguments: [yearMonth]
            )
        }
        guard let row else {
            return MonthSummary(costMicrosUSD: 0, callCount: 0)
        }
        return MonthSummary(
            costMicrosUSD: row["total"],
            callCount: row["calls"]
        )
    }

    /// This month's spend and call count, grouped by the account that made
    /// the calls.
    ///
    /// `usage_log` has recorded `account_email` since the table existed —
    /// every `record(...)` writes it — so this is a read of data that is
    /// already there, not a new ledger. The grouping is what makes the
    /// monthly total legible for a multi-account user: one number tells
    /// them *how much*, and no number told them *on which account*.
    ///
    /// Read straight from the store rather than from the in-memory totals:
    /// the actor only keeps the sum, and re-deriving per-account shares by
    /// subtracting would be a guess.
    ///
    /// Ordered by cost descending, then by email so two accounts at the same
    /// spend keep a stable order between refreshes — a list that reorders
    /// itself under the user's eyes reads as data changing.
    public static func accountBreakdown(
        db: LagoonDB,
        yearMonth: String
    ) async throws -> [UsageAccountShare] {
        // `read` is synchronous on this pool (the write is what blocks), so
        // there is no `await` here — the warning gate caught the first
        // version spelling one, which is the compiler saying the actor is
        // not actually suspending at this point.
        let rows = try db.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT account_email,
                           COALESCE(SUM(cost_micro_usd), 0) AS total,
                           COUNT(*) AS calls
                    FROM usage_log
                    WHERE year_month = ?
                    GROUP BY account_email
                    ORDER BY total DESC, account_email ASC
                    """,
                arguments: [yearMonth]
            )
        }
        // Decoded with `as?` rather than GRDB's `row["key"]` subscript.
        //
        // The subscript force-tries its conversion: a NULL in the grouped
        // column would `Fatal error` inside the library and take the whole
        // process with it — a crash in the usage panel, not a failed
        // request. `account_email` is NOT NULL in the schema, so a NULL
        // means the store is not what this code thinks it is, and the
        // honest response is to leave that row out and let the caller
        // report a breakdown that does not cover it, rather than kill the
        // app. Measured: the mutation that dropped `GROUP BY` produced a
        // NULL email and crashed the test bundle through this exact path.
        return rows.compactMap { row -> UsageAccountShare? in
            guard let email = row["account_email"] as String?,
                  let micros = row["total"] as Int64?,
                  let calls = row["calls"] as Int?
            else { return nil }
            return UsageAccountShare(
                accountEmail: email,
                monthUSD: Double(micros) / 1_000_000,
                callCount: calls
            )
        }
    }

    /// The breakdown for the month this actor is tracking.
    ///
    /// `yearMonth` is fixed at construction, so asking this actor rather
    /// than passing a date keeps the report and the cap describing the same
    /// month — including across a month boundary, where a freshly computed
    /// "now" and the cap's month would disagree for one request.
    public func accountBreakdown() async throws -> [UsageAccountShare] {
        try await Self.accountBreakdown(db: db, yearMonth: yearMonth)
    }

    private static func insert(
        db: LagoonDB,
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
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
        """
        try db.write {
            try $0.execute(sql: sql, arguments: [
                yearMonth,
                accountEmail,
                capability,
                model,
                promptTokens,
                completionTokens,
                costMicrosUSD,
            ])
        }
    }
}
