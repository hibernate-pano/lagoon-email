import XCTest
@testable import LagoonKit

final class PostgresConfigTests: XCTestCase {
    private var previousDatabaseURL: String?

    override func setUp() {
        super.setUp()
        previousDatabaseURL = ProcessInfo.processInfo.environment["DATABASE_URL"]
    }

    override func tearDown() {
        // Restore the developer's environment: leaving DATABASE_URL set could
        // point later DB tests at the local Homebrew Postgres on 5432.
        if let previousDatabaseURL {
            setenv("DATABASE_URL", previousDatabaseURL, 1)
        } else {
            unsetenv("DATABASE_URL")
        }
        super.tearDown()
    }

    func test_load_reads_database_url() throws {
        setenv("DATABASE_URL", "postgres://u:p@127.0.0.1:5432/d", 1)
        let cfg = try PostgresConfig.load()
        XCTAssertEqual(cfg.host, "127.0.0.1")
        XCTAssertEqual(cfg.port, 5432)
        XCTAssertEqual(cfg.database, "d")
        XCTAssertEqual(cfg.username, "u")
    }

    func test_load_tolerates_missing_database_path() throws {
        // A URL without a database name still parses; `load()` documents an
        // empty database rather than throwing.
        setenv("DATABASE_URL", "postgres://u:p@127.0.0.1:5432", 1)
        let cfg = try PostgresConfig.load()
        XCTAssertEqual(cfg.host, "127.0.0.1")
        XCTAssertEqual(cfg.database, "")
    }

    func test_malformed_url_throws_instead_of_trapping() {
        // Startup misconfiguration must surface as a clean error the server can
        // print and exit on, not a fatalError crash dump.
        for bad in [
            "not a valid url",
            "postgres://127.0.0.1:5432/d",           // no user/password
            "postgres://u:p@127.0.0.1/d"            // no port
        ] {
            setenv("DATABASE_URL", bad, 1)
            XCTAssertThrowsError(try PostgresConfig.load(), bad) { error in
                XCTAssertTrue(error is PostgresConfigError, "\(bad) -> \(error)")
            }
        }
        unsetenv("DATABASE_URL")
        XCTAssertThrowsError(try PostgresConfig.load())
    }
}
