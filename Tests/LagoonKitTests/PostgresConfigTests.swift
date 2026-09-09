import XCTest
@testable import LagoonKit

final class PostgresConfigTests: XCTestCase {
    func test_load_reads_database_url() {
        setenv("DATABASE_URL", "postgres://u:p@127.0.0.1:5432/d", 1)
        let cfg = PostgresConfig.load()
        XCTAssertEqual(cfg.host, "127.0.0.1")
        XCTAssertEqual(cfg.port, 5432)
        XCTAssertEqual(cfg.database, "d")
        XCTAssertEqual(cfg.username, "u")
    }
}