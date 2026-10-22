import XCTest
import Foundation
import Logging
import GRDB
import LagoonKit
@testable import LagoonServer

/// `usage_log` is the only cost ledger Lagoon keeps, and it used to be the
/// only table in the app that nothing ever deleted from: one row per LLM
/// call, forever.
///
/// It is partitioned by month, so the fix is a retention window — keep the
/// months a user might still want to look back over, drop the rest. The
/// window is six months: long enough that a user who spots a surprise
/// charge can find the month it landed in, short enough that the table does
/// not grow for the life of the install.
///
/// The trigger is the moment the set of months in the table can change
/// without a write: startup, and every month rollover.
final class UsageLogRetentionTests: XCTestCase {
    private static let logger = Logger(label: "usage-log-retention-tests")

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

    /// Writes a ledger row directly — the ledger is what the app writes, and
    /// the retention rule is about rows that already exist.
    private func insertRow(
        _ db: LagoonDB,
        month: String,
        costMicros: Int64 = 1_000,
        email: String = "a@example.com"
    ) throws {
        try db.write { db in
            try db.execute(
                sql: """
                    INSERT INTO usage_log (
                        year_month, account_email, capability, model,
                        prompt_tokens, completion_tokens, cost_micro_usd
                    ) VALUES (?, ?, 'summary', 'm', 10, 5, ?)
                    """,
                arguments: [month, email, costMicros]
            )
        }
    }

    private func months(_ db: LagoonDB) throws -> [String] {
        try db.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT DISTINCT year_month FROM usage_log ORDER BY year_month"
            )
        }
    }

    private func rowCount(_ db: LagoonDB) throws -> Int {
        try db.read { db in
            try Row.fetchOne(db, sql: "SELECT COUNT(*) AS c FROM usage_log")?["c"] ?? 0
        }
    }

    // MARK: - Startup prune

    /// The months that fell out of the window are dropped; the window itself
    /// and the current month are not.
    ///
    /// At 2026-10 a six-month window holds 2026-05 … 2026-10.
    func test_startupPrunesTheMonthsOlderThanTheWindow() async throws {
        try await TestDatabase.withConnection { db in
            try insertRow(db, month: "2026-03")
            try insertRow(db, month: "2026-04")
            try insertRow(db, month: "2026-05")
            try insertRow(db, month: "2026-09")
            try insertRow(db, month: "2026-10")

            let clock = TestClock(try month(2026, 10))
            _ = try await UsageBudget(
                db: db, capUSDPerMonth: 10, logger: Self.logger, now: { clock.now() }
            )

            XCTAssertEqual(
                try months(db), ["2026-05", "2026-09", "2026-10"],
                "months older than the window go, the window and the current month stay"
            )
        }
    }

    /// The current month is the one month that must never be a candidate for
    /// deletion — it is the month the cap is being enforced against.
    func test_theCurrentMonthIsNeverPruned() async throws {
        try await TestDatabase.withConnection { db in
            try insertRow(db, month: "2026-10", costMicros: 250_000)

            let clock = TestClock(try month(2026, 10))
            let budget = try await UsageBudget(
                db: db, capUSDPerMonth: 10, logger: Self.logger, now: { clock.now() }
            )

            let currentRows: Int = try db.read { db in
                try Row.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) AS c FROM usage_log WHERE year_month = '2026-10'"
                )?["c"] ?? 0
            }
            XCTAssertEqual(currentRows, 1)
            let total = await budget.currentMonthUSD
            XCTAssertEqual(total, 0.25, accuracy: 0.0001)
        }
    }

    /// The prune must not disturb what the panel shows: the month's totals
    /// are read from the rows the prune leaves alone.
    func test_pruningDoesNotChangeTheCurrentMonthsTotal() async throws {
        try await TestDatabase.withConnection { db in
            try insertRow(db, month: "2026-01", costMicros: 999_000)
            try insertRow(db, month: "2026-10", costMicros: 250_000)

            let clock = TestClock(try month(2026, 10))
            let budget = try await UsageBudget(
                db: db, capUSDPerMonth: 10, logger: Self.logger, now: { clock.now() }
            )

            let total = await budget.currentMonthUSD
            let calls = await budget.callCount
            XCTAssertEqual(total, 0.25, accuracy: 0.0001)
            XCTAssertEqual(calls, 1)

            let shares = try await budget.accountBreakdown()
            XCTAssertEqual(shares.count, 1)
            XCTAssertEqual(shares.first?.monthUSD ?? -1, 0.25, accuracy: 0.0001)
        }
    }

    // MARK: - Rollover prune

    /// The second trigger: when the calendar rolls over, the window moves and
    /// the months it leaves behind go.
    ///
    /// From 2026-10 to 2027-04 the window moves from 2026-05 … 2026-10 to
    /// 2026-11 … 2027-04, so the October rows fall out of it.
    func test_rollingOverPrunesTheMonthsTheWindowLeftBehind() async throws {
        try await TestDatabase.withConnection { db in
            let clock = TestClock(try month(2026, 10))
            let budget = try await UsageBudget(
                db: db, capUSDPerMonth: 10, logger: Self.logger, now: { clock.now() }
            )
            try await budget.record(
                capability: "summary", model: "m", accountEmail: "a@example.com",
                promptTokens: 100, completionTokens: 50, costMicrosUSD: 100_000
            )
            XCTAssertEqual(try months(db), ["2026-10"])

            clock.date = try month(2027, 4)
            try await budget.record(
                capability: "summary", model: "m", accountEmail: "a@example.com",
                promptTokens: 100, completionTokens: 50, costMicrosUSD: 250_000
            )

            XCTAssertEqual(
                try months(db), ["2027-04"],
                "the month the window left behind is dropped on rollover"
            )
            let total = await budget.currentMonthUSD
            XCTAssertEqual(total, 0.25, accuracy: 0.0001)
        }
    }

    /// A month inside the window survives a rollover: the window is a
    /// window, not "keep one month".
    func test_monthsInsideTheWindowSurviveARollover() async throws {
        try await TestDatabase.withConnection { db in
            let clock = TestClock(try month(2026, 10))
            let budget = try await UsageBudget(
                db: db, capUSDPerMonth: 10, logger: Self.logger, now: { clock.now() }
            )
            try insertRow(db, month: "2026-08", costMicros: 300_000)

            clock.date = try month(2026, 11)
            try await budget.record(
                capability: "summary", model: "m", accountEmail: "a@example.com",
                promptTokens: 100, completionTokens: 50, costMicrosUSD: 250_000
            )

            XCTAssertEqual(try months(db), ["2026-08", "2026-11"])
            XCTAssertEqual(try rowCount(db), 2)
        }
    }
}
