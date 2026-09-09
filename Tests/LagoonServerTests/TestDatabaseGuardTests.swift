import XCTest
@testable import LagoonKit

/// Self-tests for the data-loss guard itself. No database is needed.
final class TestDatabaseGuardTests: XCTestCase {
    func test_safeWhenLoopbackAndNameEndsInTest() {
        for raw in [
            "postgres://lagoon:lagoon@127.0.0.1:5433/lagoon_test",
            "postgres://u:p@localhost:5432/my_test",
            "postgres://u:p@[::1]:5432/x_test"
        ] {
            XCTAssertTrue(TestDatabase.isSafeTestDatabase(URL(string: raw)!), raw)
        }
    }

    func test_unsafeWhenDevDatabaseName() {
        // The exact dev DATABASE_URL from .env: guard must refuse it.
        XCTAssertFalse(
            TestDatabase.isSafeTestDatabase(URL(string: "postgres://lagoon:lagoon@127.0.0.1:5433/lagoon")!)
        )
    }

    func test_unsafeWhenNameDoesNotEndInTest() {
        XCTAssertFalse(
            TestDatabase.isSafeTestDatabase(URL(string: "postgres://u:p@127.0.0.1:5433/lagoon_test_backup")!)
        )
    }

    func test_unsafeWhenHostIsNotLoopbackEvenIfNameEndsInTest() {
        for raw in [
            "postgres://u:p@db.example.com:5432/lagoon_test",
            "postgres://u:p@10.0.0.5:5432/lagoon_test",
            "postgres://u:p@192.168.1.10:5432/lagoon_test"
        ] {
            XCTAssertFalse(TestDatabase.isSafeTestDatabase(URL(string: raw)!), raw)
        }
    }

    func test_defaultURLIsSafeTestDatabase() {
        XCTAssertTrue(TestDatabase.isSafeTestDatabase(URL(string: TestDatabase.defaultURLString)!))
    }
}
