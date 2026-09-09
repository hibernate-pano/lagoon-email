import XCTest
@testable import LagoonKit
import PostgresNIO

final class SQLBuilderTests: XCTestCase {
    func test_select_binds_values_not_interpolates() {
        let q = SQLBuilder.select(
            "id, subject",
            from: "message_headers",
            where: "account_id = $1 AND received_at > $2",
            orderBy: "received_at DESC",
            limit: 50,
            parameters: [PostgresData(string: UUID().uuidString), PostgresData(date: Date())]
        )
        XCTAssertTrue(q.sql.contains("$1"))
        XCTAssertTrue(q.sql.contains("$2"))
        XCTAssertFalse(q.sql.contains("'"))
        XCTAssertEqual(q.parameters.count, 2)
    }
}