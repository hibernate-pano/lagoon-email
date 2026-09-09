import XCTest
@testable import LagoonServer

final class FromHeaderTests: XCTestCase {
    func test_named_address() {
        let (addr, name) = GmailPoller.parseFromHeader("Alice Zhang <alice@example.com>")
        XCTAssertEqual(addr, "alice@example.com")
        XCTAssertEqual(name, "Alice Zhang")
    }

    func test_quoted_name() {
        let (addr, name) = GmailPoller.parseFromHeader("\"Zhang, Alice\" <alice@example.com>")
        XCTAssertEqual(addr, "alice@example.com")
        XCTAssertEqual(name, "Zhang, Alice")
    }

    func test_bare_address() {
        let (addr, name) = GmailPoller.parseFromHeader("bob@example.com")
        XCTAssertEqual(addr, "bob@example.com")
        XCTAssertNil(name)
    }
}