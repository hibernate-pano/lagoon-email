import Foundation
import Logging
import GRDB
import LagoonKit
import LagoonAI

/// Per-month LLM cost cap (spec §6.5).
///
/// `usage_log` is the source of truth; the in-memory total is hydrated from
/// the ledger when the calendar rolls into a new month and updated on every
/// record. Designed for a single lagoon process talking to one Postgres;
/// concurrent multi-instance writes race and can let the cap drift upward by
/// one in-flight call's cost.
public actor UsageBudget: BudgetPolicy {
    private let db: LagoonDB
    /// The monthly cap, in micro-USD. `var` because the user can change
    /// it from 「AI 设置」 and the new value must take effect without a
    /// restart — see `setCapUSDPerMonth(_:)`.
    private var capMicrosUSD: Int64
    /// The month this actor is accounting for, as `yyyy-MM`.
    ///
    /// `var`, not `let`: the actor lives as long as the process, and a macOS
    /// app stays running for months, so the month it was built in is not
    /// necessarily the month the user is in.
    private var yearMonth: String
    private var totalMicrosUSD: Int64 = 0
    private var callsThisMonth = 0
    /// First crossing of 80% within the current month is logged as a warning;
    /// later calls suppress the message.
    private var warnedAt80 = false
    private let logger: Logger
    /// The clock. Injectable so a test can move the calendar forward.
    private let now: @Sendable () -> Date

    /// How many months of `usage_log` to keep.
    ///
    /// Six months covers a half-year of bill review — long enough for a user
    /// who spots a surprise charge to find the month it landed in — and short
    /// enough that the ledger does not grow for the life of the install.
    /// `usage_log` is the only cost record Lagoon keeps, so it is also the
    /// only place the answer to "what did I spend" can come from.
    static let retentionMonths = 6

    /// `capUSDPerMonth <= 0` disables enforcement (and warns once on startup).
    public init(
        db: LagoonDB,
        capUSDPerMonth: Double,
        logger: Logger,
        now: @escaping @Sendable () -> Date = { Date() }
    ) async throws {
        self.db = db
        // The conversion to micro-USD used to be done here with a bare
        // `Int64(...)`, which **traps** on a non-finite cap: `Int64(inf)`
        // is a crash, not a number. A cap of "inf" could reach this line
        // from the environment, and the process died with it — the whole
        // server, and the app that hosts it. `AIBudget.micros` refuses
        // what it cannot express and reads an unusable cap as "no cap".
        self.capMicrosUSD = AIBudget.micros(capUSDPerMonth) ?? 0
        self.logger = logger
        self.now = now
        let window = Self.monthWindow(for: now(), keepMonths: Self.retentionMonths)
        self.yearMonth = window.current
        // Startup: adopt the ledger's numbers for this month and drop the
        // months that fell out of the retention window. One transaction, so
        // the totals and the table agree on what "this month" means.
        let summary = try db.write { db -> MonthSummary in
            let summary = try Self.summary(in: db, yearMonth: window.current)
            let removed = try Self.prune(in: db, keepingFrom: window.oldestKept)
            if removed > 0 {
                logger.info("llm.budget.pruned", metadata: [
                    "removedRows": .string("\(removed)"),
                    "keepMonths": .string("\(Self.retentionMonths)"),
                ])
            }
            return summary
        }
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
        // Same guard as the constructor: the conversion traps on a
        // non-finite value, so a cap that cannot be expressed is no cap.
        capMicrosUSD = AIBudget.micros(value) ?? 0
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
        // The cap is a promise about *this* month: when the calendar rolls
        // over, last month's spending stops counting against it.
        try refreshMonthIfNeeded()
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
        let window = Self.monthWindow(for: now(), keepMonths: Self.retentionMonths)
        let knownMonth = yearMonth
        let knownTotal = totalMicrosUSD
        let knownCalls = callsThisMonth
        // One write transaction: the totals the row is charged against and
        // the `year_month` the row is filed under are the same month's, even
        // when the call lands on the first of the month.
        let ledger = try db.write { db -> MonthLedger in
            let rolledOver = window.current != knownMonth
            var summary = MonthSummary(costMicrosUSD: knownTotal, callCount: knownCalls)
            if rolledOver {
                summary = try Self.summary(in: db, yearMonth: window.current)
                try Self.prune(in: db, keepingFrom: window.oldestKept)
            }
            try Self.insert(
                in: db,
                yearMonth: window.current,
                accountEmail: accountEmail,
                capability: capability,
                model: model,
                promptTokens: promptTokens,
                completionTokens: completionTokens,
                costMicrosUSD: costMicrosUSD
            )
            return MonthLedger(month: window.current, summary: summary, rolledOver: rolledOver)
        }
        yearMonth = ledger.month
        if ledger.rolledOver {
            warnedAt80 = ledger.summary.costMicrosUSD >= capForWarn(capMicros: capMicrosUSD)
        }
        totalMicrosUSD = ledger.summary.costMicrosUSD + costMicrosUSD
        callsThisMonth = ledger.summary.callCount + 1
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

    /// Re-reads the month's totals when the calendar has moved on, and prunes
    /// the months that fell out of the retention window.
    ///
    /// The actor is built once per process and the app is a menu-bar app
    /// that stays running for months, so the month it was constructed in is
    /// not necessarily the month it is accounting for now. The hydration and
    /// the prune share one write transaction: the totals the cap is checked
    /// against and the table they came from have to describe the same month.
    private func refreshMonthIfNeeded() throws {
        let window = Self.monthWindow(for: now(), keepMonths: Self.retentionMonths)
        guard window.current != yearMonth else { return }
        let summary = try db.write { db -> MonthSummary in
            let summary = try Self.summary(in: db, yearMonth: window.current)
            let removed = try Self.prune(in: db, keepingFrom: window.oldestKept)
            if removed > 0 {
                logger.info("llm.budget.pruned", metadata: [
                    "removedRows": .string("\(removed)"),
                    "keepMonths": .string("\(Self.retentionMonths)"),
                ])
            }
            return summary
        }
        yearMonth = window.current
        totalMicrosUSD = summary.costMicrosUSD
        callsThisMonth = summary.callCount
        warnedAt80 = summary.costMicrosUSD >= capForWarn(capMicros: capMicrosUSD)
    }

    private func capForWarn(capMicros: Int64) -> Int64 { capMicros * 80 / 100 }

    /// `yyyy-MM` — the key `usage_log` is partitioned by.
    ///
    /// Fixed locale so the layout follows the calendar and not the user's
    /// region. Lexicographic order over this format is chronological order,
    /// which is what lets the retention prune compare months with `<`.
    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM"
        return f
    }()

    /// The month a date falls in, plus the oldest month a ledger that keeps
    /// `keepMonths` months must still hold.
    private struct MonthWindow {
        let current: String
        let oldestKept: String
    }

    /// The ledger state a charge is filed against: which month, and what
    /// that month had already spent when the charge was made.
    private struct MonthLedger {
        let month: String
        let summary: MonthSummary
        let rolledOver: Bool
    }

    private struct MonthSummary {
        let costMicrosUSD: Int64
        let callCount: Int
    }

    private static func monthWindow(for date: Date, keepMonths: Int) -> MonthWindow {
        let current = monthFormatter.string(from: date)
        return MonthWindow(
            current: current,
            oldestKept: monthKey(offsetBy: -(max(1, keepMonths) - 1), from: current)
        )
    }

    /// The `yyyy-MM` key `offset` months away from `month`.
    ///
    /// Plain integer arithmetic on the key: a month is a calendar month, so
    /// counting months on the number is both simpler and more predictable
    /// than moving a `Date` around a calendar.
    private static func monthKey(offsetBy offset: Int, from month: String) -> String {
        let parts = month.split(separator: "-")
        guard parts.count == 2, let year = Int(parts[0]), let mon = Int(parts[1]) else {
            return month
        }
        let total = year * 12 + (mon - 1) + offset
        let shiftedYear = total / 12
        let shiftedMonth = total % 12 + 1
        return String(format: "%04d-%02d", shiftedYear, shiftedMonth)
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

    private static func summary(in db: Database, yearMonth: String) throws -> MonthSummary {
        let row = try Row.fetchOne(
            db,
            sql: "SELECT COALESCE(SUM(cost_micro_usd), 0) AS total, COUNT(*) AS calls FROM usage_log WHERE year_month = ?",
            arguments: [yearMonth]
        )
        guard let row else {
            return MonthSummary(costMicrosUSD: 0, callCount: 0)
        }
        return MonthSummary(
            costMicrosUSD: row["total"],
            callCount: row["calls"]
        )
    }

    /// Drops the ledger rows whose month fell out of the retention window.
    ///
    /// `usage_log` is the only cost record Lagoon keeps and it had no other
    /// deletion path, so the table grew for the life of the install and every
    /// monthly aggregate read more rows than the month it was about. The
    /// comparison is `<`: the current month and the rest of the window are
    /// never touched.
    @discardableResult
    private static func prune(in db: Database, keepingFrom oldestKept: String) throws -> Int {
        try db.execute(
            sql: "DELETE FROM usage_log WHERE year_month < ?",
            arguments: [oldestKept]
        )
        return db.changesCount
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

    /// The breakdown for the month this actor is accounting for.
    ///
    /// The month is read from the clock, not remembered from construction:
    /// asking this actor rather than passing a date is what keeps the report
    /// and the cap describing the same month.
    public func accountBreakdown() async throws -> [UsageAccountShare] {
        try refreshMonthIfNeeded()
        return try await Self.accountBreakdown(db: db, yearMonth: yearMonth)
    }

    private static func insert(
        in db: Database,
        yearMonth: String,
        accountEmail: String,
        capability: String,
        model: String,
        promptTokens: Int,
        completionTokens: Int,
        costMicrosUSD: Int64,
    ) throws {
        let sql = """
            INSERT INTO usage_log (
                year_month, account_email, capability, model,
                prompt_tokens, completion_tokens, cost_micro_usd
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
        """
        try db.execute(sql: sql, arguments: [
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
