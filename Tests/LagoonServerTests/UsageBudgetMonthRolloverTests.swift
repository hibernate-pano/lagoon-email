import XCTest
import Foundation
import Logging
import GRDB
import LagoonKit
@testable import LagoonServer

/// The budget has to follow the calendar, not the process.
///
/// Lagoon is a menu-bar app: it stays running for months, so the month the
/// budget actor was constructed in is regularly not the month the user is in.
/// The ledger is partitioned by month, the cap is a monthly promise and the
/// panel says "本月" — all three have to move together, or the user is told
/// what they spent on *last* month.
///
/// The clock is injected so the month can be moved without touching the
/// machine's clock.
final class UsageBudgetMonthRolloverTests: XCTestCase {
    private static let logger = Logger(label: "usage-budget-rollover-tests")

    /// A clock the test can move.
    ///
    /// `@unchecked Sendable` because the lock is what makes it safe: the
    /// budget reads it from whichever thread the actor happens to run on.
    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var _date: Date

        init(_ date: Date) { _date = date }

        var date: Date {
            get {
                lock.lock()
                defer { lock.unlock() }
                return _date
            }
            set {
                lock.lock()
                _date = newValue
                lock.unlock()
            }
        }

        func now() -> Date { date }
    }

    /// A Gregorian local date in the given month.
    ///
    /// Day 15 at noon keeps the month stable across every timezone, and the
    /// Gregorian calendar keeps it stable across locales that count years
    /// differently.
    private func month(_ year: Int, _ monthNumber: Int) throws -> Date {
        var components = DateComponents()
        components.year = year
        components.month = monthNumber
        components.day = 15
        components.hour = 12
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return try XCTUnwrap(calendar.date(from: components))
    }

    /// Every row in the ledger, in insertion order.
    private func ledger(_ db: LagoonDB) throws -> [(month: String, micros: Int64)] {
        try db.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT year_month, cost_micro_usd FROM usage_log ORDER BY id"
            ).map { row in
                (month: row["year_month"] as String, micros: row["cost_micro_usd"] as Int64)
            }
        }
    }

    private func months(_ db: LagoonDB) throws -> [String] {
        try ledger(db).map(\.month)
    }

    // MARK: - The row lands in the month the call happened in

    /// One actor, two months: the January call stays in January and the
    /// February call is filed under February.
    func test_recordAfterRolloverFilesTheRowUnderTheNewMonth() async throws {
        try await TestDatabase.withConnection { db in
            let clock = TestClock(try month(2026, 1))
            let budget = try await UsageBudget(
                db: db, capUSDPerMonth: 10, logger: Self.logger, now: { clock.now() }
            )
            try await budget.record(
                capability: "summary", model: "m", accountEmail: "a@example.com",
                promptTokens: 100, completionTokens: 50, costMicrosUSD: 100_000
            )
            clock.date = try month(2026, 2)
            try await budget.record(
                capability: "summary", model: "m", accountEmail: "a@example.com",
                promptTokens: 100, completionTokens: 50, costMicrosUSD: 250_000
            )

            let rows = try ledger(db)
            XCTAssertEqual(
                rows.map(\.month), ["2026-01", "2026-02"],
                "each charge must be filed under the month it was made in"
            )
            XCTAssertEqual(rows.map(\.micros), [100_000, 250_000])
        }
    }

    /// The same, two months on: a call made in March must not be filed under
    /// February — the month it skipped over never existed for this actor.
    func test_recordAfterTwoMonthsFilesTheRowUnderTheCurrentMonth() async throws {
        try await TestDatabase.withConnection { db in
            let clock = TestClock(try month(2026, 1))
            let budget = try await UsageBudget(
                db: db, capUSDPerMonth: 10, logger: Self.logger, now: { clock.now() }
            )
            try await budget.record(
                capability: "summary", model: "m", accountEmail: "a@example.com",
                promptTokens: 100, completionTokens: 50, costMicrosUSD: 100_000
            )
            clock.date = try month(2026, 3)
            try await budget.record(
                capability: "summary", model: "m", accountEmail: "a@example.com",
                promptTokens: 100, completionTokens: 50, costMicrosUSD: 250_000
            )

            XCTAssertEqual(
                try months(db), ["2026-01", "2026-03"],
                "no charge may be filed under a month the actor never charged in"
            )
            let march = try XCTUnwrap(try ledger(db).first { $0.month == "2026-03" })
            XCTAssertEqual(march.micros, 250_000)
        }
    }

    /// The in-memory total must be the new month's total, not last month's
    /// plus this month's.
    func test_currentMonthUSDAfterRolloverCountsOnlyTheNewMonth() async throws {
        try await TestDatabase.withConnection { db in
            let clock = TestClock(try month(2026, 1))
            let budget = try await UsageBudget(
                db: db, capUSDPerMonth: 10, logger: Self.logger, now: { clock.now() }
            )
            try await budget.record(
                capability: "summary", model: "m", accountEmail: "a@example.com",
                promptTokens: 100, completionTokens: 50, costMicrosUSD: 100_000
            )
            clock.date = try month(2026, 2)
            try await budget.record(
                capability: "summary", model: "m", accountEmail: "a@example.com",
                promptTokens: 100, completionTokens: 50, costMicrosUSD: 250_000
            )

            let total = await budget.currentMonthUSD
            let calls = await budget.callCount
            XCTAssertEqual(total, 0.25, accuracy: 0.0001, "February's spend is $0.25, not $0.35")
            XCTAssertEqual(calls, 1, "only the February call belongs to February")
        }
    }

    /// The panel says "本月" — so the breakdown has to be February's rows
    /// only. With the month frozen it would report January *and* February
    /// under one heading.
    func test_accountBreakdownAfterRolloverCoversOnlyTheNewMonth() async throws {
        try await TestDatabase.withConnection { db in
            let clock = TestClock(try month(2026, 1))
            let budget = try await UsageBudget(
                db: db, capUSDPerMonth: 10, logger: Self.logger, now: { clock.now() }
            )
            try await budget.record(
                capability: "summary", model: "m", accountEmail: "a@example.com",
                promptTokens: 100, completionTokens: 50, costMicrosUSD: 100_000
            )
            clock.date = try month(2026, 2)
            try await budget.record(
                capability: "summary", model: "m", accountEmail: "a@example.com",
                promptTokens: 100, completionTokens: 50, costMicrosUSD: 250_000
            )

            let shares = try await budget.accountBreakdown()
            XCTAssertEqual(shares.count, 1)
            let share = try XCTUnwrap(shares.first)
            XCTAssertEqual(share.monthUSD, 0.25, accuracy: 0.0001)
            XCTAssertEqual(share.callCount, 1)
        }
    }

    // MARK: - The cap follows the calendar too

    /// The cap is a monthly allowance: February's spending starts from zero.
    /// Charging January's $0.08 against February's $0.10 cap would tell the
    /// user their budget is blown when it is not.
    func test_previousMonthSpendIsNotChargedAgainstTheNewMonthsCap() async throws {
        try await TestDatabase.withConnection { db in
            let clock = TestClock(try month(2026, 1))
            let budget = try await UsageBudget(
                db: db, capUSDPerMonth: 0.10, logger: Self.logger, now: { clock.now() }
            )
            try await budget.record(
                capability: "summary", model: "m", accountEmail: "a@example.com",
                promptTokens: 100, completionTokens: 50, costMicrosUSD: 80_000  // $0.08
            )
            clock.date = try month(2026, 2)

            // $0.05 projected: over January's $0.08 + $0.05, under
            // February's $0.05.
            try await budget.checkBeforeCall(
                capability: "summary", model: "m",
                estimatedPromptTokens: 1_000, estimatedCompletionTokens: 1_000,
                promptRate: 0.025, completionRate: 0.025
            )
        }
    }

    /// And the cap is still enforced *within* the new month.
    func test_theNewMonthsOwnSpendIsStillCapped() async throws {
        try await TestDatabase.withConnection { db in
            let clock = TestClock(try month(2026, 1))
            let budget = try await UsageBudget(
                db: db, capUSDPerMonth: 0.10, logger: Self.logger, now: { clock.now() }
            )
            clock.date = try month(2026, 2)
            try await budget.record(
                capability: "summary", model: "m", accountEmail: "a@example.com",
                promptTokens: 100, completionTokens: 50, costMicrosUSD: 90_000  // $0.09
            )

            do {
                try await budget.checkBeforeCall(
                    capability: "summary", model: "m",
                    estimatedPromptTokens: 1_000, estimatedCompletionTokens: 1_000,
                    promptRate: 0.025, completionRate: 0.025  // $0.05 more
                )
                XCTFail("a call that breaches the current month's cap must be rejected")
            } catch {
                // expected
            }
        }
    }

    // MARK: - The ledger and the running total describe the same month

    /// The total the actor reports and the rows it wrote have to be the same
    /// month's — a charge filed under February must not be counted in
    /// January's total, or the panel contradicts the ledger.
    func test_theRunningTotalMatchesTheRowsOfTheCurrentMonth() async throws {
        try await TestDatabase.withConnection { db in
            let clock = TestClock(try month(2026, 1))
            let budget = try await UsageBudget(
                db: db, capUSDPerMonth: 10, logger: Self.logger, now: { clock.now() }
            )
            try await budget.record(
                capability: "summary", model: "m", accountEmail: "a@example.com",
                promptTokens: 100, completionTokens: 50, costMicrosUSD: 100_000
            )
            clock.date = try month(2026, 2)
            try await budget.record(
                capability: "summary", model: "m", accountEmail: "a@example.com",
                promptTokens: 100, completionTokens: 50, costMicrosUSD: 250_000
            )

            let february: Int64 = try db.read { db in
                try Row.fetchOne(
                    db,
                    sql: "SELECT COALESCE(SUM(cost_micro_usd), 0) AS t FROM usage_log WHERE year_month = '2026-02'"
                )?["t"] ?? 0
            }
            let total = await budget.currentMonthUSD
            XCTAssertEqual(february, 250_000)
            XCTAssertEqual(total * 1_000_000, Double(february), accuracy: 0.5)
        }
    }
}
