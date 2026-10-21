import XCTest
import Foundation
import Logging
import Hummingbird
import HummingbirdTesting
import NIOCore
import GRDB
@testable import LagoonServer
@testable import LagoonKit

/// P2-07 (task B): the usage panel must be able to say **which account**
/// spent the money.
///
/// ## Why this is a real behavioural test
///
/// The data was always there — `usage_log.account_email` is `NOT NULL` and
/// every `record(...)` writes it — but `GET /api/usage` only ever answered
/// with the month's sum. A multi-account user could see the total and not
/// the split, which is the one number that tells them whether the AI is
/// being paid for by the mailbox they care about.
///
/// These tests exercise the store and the wire format, so they fail if the
/// grouping is wrong (not just if a string is missing).
final class UsageBreakdownTests: XCTestCase {
    private static let logger = Logger(label: "usage-breakdown-tests")

    private func makeBudget(_ conn: LagoonDB) async throws -> UsageBudget {
        try await UsageBudget(db: conn, capUSDPerMonth: 10, logger: Self.logger)
    }

    /// Two accounts, two costs: the breakdown must split them and order by
    /// cost, largest first.
    func test_breakdownSplitsTheMonthByAccount() async throws {
        try await TestDatabase.withConnection { conn in
            let budget = try await makeBudget(conn)
            try await budget.record(
                capability: "summary", model: "m", accountEmail: "big@example.com",
                promptTokens: 100, completionTokens: 50, costMicrosUSD: 300_000
            )
            try await budget.record(
                capability: "summary", model: "m", accountEmail: "small@example.com",
                promptTokens: 100, completionTokens: 50, costMicrosUSD: 100_000
            )
            // A second call on the same account must be folded into its row,
            // not listed separately.
            try await budget.record(
                capability: "classify", model: "m", accountEmail: "big@example.com",
                promptTokens: 100, completionTokens: 50, costMicrosUSD: 200_000
            )

            let shares = try await budget.accountBreakdown()

            XCTAssertEqual(shares.count, 2, "two accounts must produce two rows")
            // Indexed through the collection, not `shares[0]`: a broken
            // GROUP BY returns three rows, and a bare subscript would crash
            // the whole test bundle instead of failing this one assertion.
            let big = try XCTUnwrap(shares.first { $0.accountEmail == "big@example.com" })
            let small = try XCTUnwrap(shares.first { $0.accountEmail == "small@example.com" })
            XCTAssertEqual(big.monthUSD, 0.50, accuracy: 0.0001)
            XCTAssertEqual(big.callCount, 2, "two calls on one account must fold into one row")
            XCTAssertEqual(small.monthUSD, 0.10, accuracy: 0.0001)
            XCTAssertEqual(small.callCount, 1)
            XCTAssertEqual(
                shares.first?.accountEmail, "big@example.com",
                "the biggest spender must come first"
            )
        }
    }

    /// The rows must sum to the month's total.
    ///
    /// This is the property that makes the panel honest: a breakdown that
    /// does not add up to the headline is two numbers contradicting each
    /// other on one screen.
    func test_theSharesSumToTheMonthlyTotal() async throws {
        try await TestDatabase.withConnection { conn in
            let budget = try await makeBudget(conn)
            for (email, micros) in [
                ("a@example.com", Int64(123_456)),
                ("b@example.com", Int64(654_321)),
                ("c@example.com", Int64(1_000_000)),
            ] {
                try await budget.record(
                    capability: "summary", model: "m", accountEmail: email,
                    promptTokens: 1, completionTokens: 1, costMicrosUSD: micros
                )
            }

            let shares = try await budget.accountBreakdown()
            let total = await budget.currentMonthUSD
            let summed = shares.reduce(0) { $0 + $1.monthUSD }
            XCTAssertEqual(summed, total, accuracy: 0.000001)
        }
    }

    /// An account whose calls had no token rates records $0 and must still
    /// appear: the call happened, and hiding the row would make the panel's
    /// account list disagree with the call count above it.
    func test_anAccountWithZeroCostStillAppears() async throws {
        try await TestDatabase.withConnection { conn in
            let budget = try await makeBudget(conn)
            try await budget.record(
                capability: "summary", model: "m", accountEmail: "unpriced@example.com",
                promptTokens: 100, completionTokens: 50, costMicrosUSD: 0
            )

            let shares = try await budget.accountBreakdown()
            XCTAssertEqual(shares.map(\.accountEmail), ["unpriced@example.com"])
            XCTAssertEqual(shares[0].monthUSD, 0, accuracy: 0.0001)
            XCTAssertEqual(shares[0].callCount, 1)
        }
    }

    /// No calls this month = no rows. Not a row per known account with $0:
    /// that would be a fabricated split.
    func test_noCalls_producesNoRows() async throws {
        try await TestDatabase.withConnection { conn in
            let budget = try await makeBudget(conn)
            let shares = try await budget.accountBreakdown()
            XCTAssertTrue(shares.isEmpty, "an empty month must not invent per-account rows")
        }
    }

    /// `GET /api/usage` must carry the breakdown, and the headline fields
    /// must keep their old meaning.
    func test_theUsageRouteCarriesTheBreakdown() async throws {
        try await TestDatabase.withConnection { conn in
            let budget = try await makeBudget(conn)
            try await budget.record(
                capability: "summary", model: "m", accountEmail: "one@example.com",
                promptTokens: 1, completionTokens: 1, costMicrosUSD: 250_000
            )
            let router = Router<BasicRequestContext>()
            BudgetRoutes.register(
                on: router, budget: budget,
                costTrackingAvailable: true, gateway: nil,
                logger: Self.logger
            )
            let app = Application(router: router)
            try await app.test(.router) { client in
                try await client.execute(uri: "/api/usage", method: .get) { response in
                    XCTAssertEqual(response.status, .ok)
                    let report = try JSONDecoder().decode(
                        UsageReport.self, from: Data(buffer: response.body)
                    )
                    XCTAssertEqual(report.monthUSD, 0.25, accuracy: 0.0001)
                    XCTAssertEqual(report.capUSD, 10, accuracy: 0.0001)
                    XCTAssertEqual(report.callCount, 1)
                    // The cap is over the **combined** spend of every
                    // account: the row amounts add up to it, they are not
                    // each measured against it.
                    XCTAssertEqual(report.accounts.count, 1)
                    XCTAssertEqual(report.accounts.first?.accountEmail, "one@example.com")
                    XCTAssertEqual(report.accounts.first?.monthUSD ?? -1, 0.25, accuracy: 0.0001)
                }
            }
        }
    }

    /// A client built before `accounts` existed must still decode the
    /// response — the field is optional on the wire.
    ///
    /// This is the compatibility half of adding a field: the server is free
    /// to ship it, and an older client must not start failing to load the
    /// usage panel against a newer server.
    func test_anOlderResponseWithoutAccountsStillDecodes() throws {
        let json = Data(#"{"monthUSD":1.5,"capUSD":10,"callCount":3,"costTrackingAvailable":true}"#.utf8)
        let report = try JSONDecoder().decode(UsageReport.self, from: json)
        XCTAssertEqual(report.monthUSD, 1.5, accuracy: 0.0001)
        XCTAssertEqual(report.callCount, 3)
        XCTAssertTrue(
            report.accounts.isEmpty,
            "a response without the key must decode to an empty breakdown, not fail"
        )
    }

    /// …and the reverse: a **new** client reading an old server's answer.
    /// Same JSON, same requirement, stated for the direction that actually
    /// ships (the client updates first).
    func test_aMissingCostTrackingFlagDefaultsToTrue() throws {
        let json = Data(#"{"monthUSD":0,"capUSD":0,"callCount":0}"#.utf8)
        let report = try JSONDecoder().decode(UsageReport.self, from: json)
        XCTAssertTrue(report.costTrackingAvailable)
        XCTAssertTrue(report.accounts.isEmpty)
    }
}
