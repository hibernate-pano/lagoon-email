import XCTest
@testable import LagoonServer

final class PKCETests: XCTestCase {
    func test_verifier_is_43_to_128_chars() {
        let p = PKCE.generate()
        XCTAssertGreaterThanOrEqual(p.verifier.count, 43)
        XCTAssertLessThanOrEqual(p.verifier.count, 128)
        XCTAssertFalse(p.challenge.isEmpty)
        XCTAssertEqual(p.method, "S256")
    }

    func test_challenge_is_base64url_no_padding() {
        let p = PKCE.generate()
        XCTAssertFalse(p.challenge.contains("="))
        XCTAssertFalse(p.challenge.contains("+"))
        XCTAssertFalse(p.challenge.contains("/"))
    }

    func test_two_generations_differ() {
        let a = PKCE.generate()
        let b = PKCE.generate()
        XCTAssertNotEqual(a.verifier, b.verifier)
    }
}