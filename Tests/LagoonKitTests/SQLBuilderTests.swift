import XCTest
@testable import LagoonKit
import PostgresNIO

final class SQLBuilderTests: XCTestCase {
    func test_select_passes_placeholders_and_parameters_through_without_binding() {
        let q = SQLBuilder.select(
            "id, subject",
            from: "message_headers",
            where: "account_id = $1 AND received_at > $2",
            orderBy: "received_at DESC",
            limit: 50,
            parameters: [PostgresData(string: UUID().uuidString), PostgresData(date: Date())]
        )
        // SQLBuilder does no binding: caller-supplied placeholders and
        // parameters pass through untouched.
        XCTAssertTrue(q.sql.contains("account_id = $1 AND received_at > $2"))
        XCTAssertTrue(q.sql.contains("ORDER BY received_at DESC"))
        XCTAssertTrue(q.sql.contains("LIMIT 50"))
        XCTAssertFalse(q.sql.contains("'"), "no value is interpolated as a string literal")
        XCTAssertEqual(q.parameters.count, 2)
    }

    func test_select_interpolates_columns_and_table_verbatim_trust_boundary() {
        // Trust boundary: `columns` and `table` are concatenated into the SQL
        // string verbatim, not escaped or validated. Callers must never pass
        // untrusted input there. Only the `$n` placeholders are injection-safe.
        let injected = "message_headers; DROP TABLE users; --"
        let q = SQLBuilder.select(
            "*",
            from: injected,
            where: "1 = 1",
            parameters: []
        )
        XCTAssertTrue(q.sql.contains(injected), "table is interpolated verbatim, not escaped")
        XCTAssertTrue(q.sql.hasPrefix("SELECT * FROM"), "keyword prefix is built as-is")
        XCTAssertTrue(q.sql.hasSuffix("WHERE 1 = 1"), "trailing clause is concatenated as-is")
        XCTAssertTrue(q.parameters.isEmpty, "verbatim interpolation is not parameter binding")
    }
}
