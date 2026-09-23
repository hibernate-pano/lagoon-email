import XCTest
import Foundation
import Logging
import Hummingbird
import NIOCore
import PostgresNIO
@testable import LagoonServer
@testable import LagoonKit

/// Covers `GET /api/ai-status` (V2 C1): the heuristic-only install reports
/// unconfigured-but-healthy, never down.
final class AIStatusRoutesTests: XCTestCase {
    func test_unconfiguredGateway_reportsHealthyUnconfigured() async throws {
        try await TestDatabase.withConnection { conn in
            let budget = try await UsageBudget(
                db: conn, capUSDPerMonth: 0,
                logger: Logger(label: "ai-status-tests")
            )
            let router = Router<BasicRequestContext>()
            BudgetRoutes.register(
                on: router, budget: budget,
                costTrackingAvailable: false, gateway: nil
            )
            let app = Application(router: router)
            try await app.test(.router) { client in
                try await client.execute(uri: "/api/ai-status", method: .get) { response in
                    XCTAssertEqual(response.status, .ok)
                    let decoded = try JSONDecoder().decode(
                        AIStatus.self, from: Data(buffer: response.body)
                    )
                    XCTAssertEqual(
                        decoded,
                        AIStatus(configured: false, creditExhausted: false, circuitOpen: false)
                    )
                }
            }
        }
    }
}
