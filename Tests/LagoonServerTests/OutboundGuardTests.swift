import XCTest
@testable import LagoonServer

final class OutboundGuardTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.reset()
        super.tearDown()
    }

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
            "https://169.254.169.254/metadata",
            // extra reserved / special-use ranges
            "https://0.0.0.0/token",
            "https://[::1]/token",
            "https://metadata.google.internal/computeMetadata/v1/"
        ] {
            XCTAssertThrowsError(try OutboundGuard.validate(URL(string: raw)!), raw)
        }
    }

    /// The `.outbound` session must never follow a redirect: a 3xx is surfaced
    /// as `OutboundRedirectError.redirectBlocked` and the redirect target is
    /// never requested. Uses a URLProtocol stub, not a live server.
    func test_outboundData_throwsRedirectBlocked_andDoesNotFollowRedirect() async throws {
        URLProtocolStub.install { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": "https://evil.example.com/steal"]
            )!
            return (response, Data())
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolStub.self]
        let session = URLSession(
            configuration: config,
            delegate: OutboundNoRedirectDelegate(),
            delegateQueue: nil
        )

        do {
            _ = try await session.outboundData(
                for: URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
            )
            XCTFail("expected OutboundRedirectError.redirectBlocked")
        } catch let error as NSError {
            XCTAssertEqual(error.domain, "Lagoon.OutboundRedirect")
            XCTAssertEqual(error.code, 1)
        }

        XCTAssertEqual(
            URLProtocolStub.capturedRequests.count,
            1,
            "a 3xx must not be followed to the redirect target"
        )
    }
}
