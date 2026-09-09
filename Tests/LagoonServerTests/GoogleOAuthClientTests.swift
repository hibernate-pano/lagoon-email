import XCTest
import Foundation
@testable import LagoonServer

/// OAuth token endpoint tests using a `URLProtocol` stub session. No network.
final class GoogleOAuthClientTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.reset()
        super.tearDown()
    }

    private func makeClient(_ handler: @escaping URLProtocolStub.Handler) -> GoogleOAuthClient {
        URLProtocolStub.install(handler)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolStub.self]
        let session = URLSession(configuration: config)
        return GoogleOAuthClient(
            clientID: "test-client",
            clientSecret: "test-secret",
            redirectURI: "http://127.0.0.1:9999/callback",
            session: session
        )
    }

    private func tokenJSON(includeRefreshToken: Bool) -> Data {
        var obj: [String: Any] = [
            "access_token": "new-access",
            "expires_in": 3600,
            "scope": "scope-a scope-b",
            "token_type": "Bearer"
        ]
        if includeRefreshToken { obj["refresh_token"] = "new-refresh" }
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    private func ok(_ request: URLRequest, _ body: Data) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, body)
    }

    func test_refresh_postsExpectedFormAndDecodesOmittedRefreshToken() async throws {
        let responseBody = tokenJSON(includeRefreshToken: false)
        let client = makeClient { [responseBody] request in
            self.ok(request, responseBody)
        }

        let result = try await client.refresh(refreshToken: "rt-123")
        XCTAssertEqual(result.accessToken, "new-access")
        XCTAssertEqual(result.expiresIn, 3600)
        // Google omits refresh_token on refresh grants: must decode, not throw.
        XCTAssertNil(result.refreshToken)

        let captured = try XCTUnwrap(URLProtocolStub.capturedRequests.first)
        let req = captured.request
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.scheme, "https")
        XCTAssertEqual(req.url?.host, "oauth2.googleapis.com")
        XCTAssertEqual(req.url?.path, "/token")
        XCTAssertEqual(
            req.value(forHTTPHeaderField: "Content-Type"),
            "application/x-www-form-urlencoded"
        )

        let body = String(data: try XCTUnwrap(captured.body), encoding: .utf8) ?? ""
        for expected in [
            "grant_type=refresh_token",
            "client_id=test-client",
            "client_secret=test-secret",
            "refresh_token=rt-123"
        ] {
            XCTAssertTrue(body.contains(expected), "missing \(expected) in body: \(body)")
        }
    }

    func test_exchange_throwsMissingRefreshToken_whenResponseOmitsIt() async throws {
        let responseBody = tokenJSON(includeRefreshToken: false)
        let client = makeClient { [responseBody] request in
            self.ok(request, responseBody)
        }

        do {
            _ = try await client.exchange(code: "auth-code", codeVerifier: "verifier")
            XCTFail("expected OAuthClientError.missingRefreshToken")
        } catch OAuthClientError.missingRefreshToken {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
