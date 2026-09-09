import XCTest
@testable import LagoonServer

final class OutboundGuardTests: XCTestCase {
    func test_allows_known_google_api_hosts() throws {
        for raw in [
            "https://oauth2.googleapis.com/token",
            "https://openidconnect.googleapis.com/v1/userinfo",
            "https://gmail.googleapis.com/gmail/v1/users/me/messages",
            "https://accounts.google.com/o/oauth2/v2/auth"
        ] {
            XCTAssertNoThrow(try OutboundGuard.validate(URL(string: raw)!), raw)
        }
    }

    func test_blocks_non_https() {
        XCTAssertThrowsError(try OutboundGuard.validate(URL(string: "http://oauth2.googleapis.com/token")!))
    }

    func test_blocks_unknown_hosts() {
        XCTAssertThrowsError(try OutboundGuard.validate(URL(string: "https://evil.example.com/steal")!))
    }

    func test_blocks_loopback_private_and_reserved() {
        for raw in [
            "https://localhost/token",
            "https://127.0.0.1/token",
            "https://10.0.0.1/token",
            "https://172.16.0.1/token",
            "https://192.168.1.1/token",
            "https://169.254.169.254/metadata"
        ] {
            XCTAssertThrowsError(try OutboundGuard.validate(URL(string: raw)!), raw)
        }
    }
}