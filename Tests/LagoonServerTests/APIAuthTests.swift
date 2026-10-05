import XCTest
import Foundation
import Hummingbird
import NIOCore
@testable import LagoonServer

/// Covers `APIAuthMiddleware` (V2 A5): open when unconfigured, 401 without or
/// with a wrong token, pass-through with the right one, non-API paths ungated.
final class APIAuthTests: XCTestCase {
    private func makeRouter(token: String?) -> Router<BasicRequestContext> {
        let router = Router<BasicRequestContext>()
        router.add(middleware: APIAuthMiddleware(token: token))
        router.get("api/ping") { _, _ in Response(status: .ok) }
        router.get("healthz") { _, _ in Response(status: .ok) }
        return router
    }

    func test_unconfigured_isOpen() async throws {
        let app = Application(router: makeRouter(token: nil))
        try await app.test(.router) { client in
            try await client.execute(uri: "/api/ping", method: .get) { response in
                XCTAssertEqual(response.status, .ok)
            }
        }
    }

    func test_configured_rejectsMissingAndWrongToken() async throws {
        let app = Application(router: makeRouter(token: "s3cret"))
        try await app.test(.router) { client in
            try await client.execute(uri: "/api/ping", method: .get) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }
            try await client.execute(
                uri: "/api/ping", method: .get,
                headers: [.authorization: "Bearer wrong"]
            ) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }
            // Prefix confusion must not gate: /apifoo is not /api/*.
            try await client.execute(uri: "/healthz", method: .get) { response in
                XCTAssertEqual(response.status, .ok)
            }
        }
    }

    func test_configured_acceptsCorrectToken() async throws {
        let app = Application(router: makeRouter(token: "s3cret"))
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/ping", method: .get,
                headers: [.authorization: "Bearer s3cret"]
            ) { response in
                XCTAssertEqual(response.status, .ok)
            }
        }
    }

    /// Regression: gating used to be `path.hasPrefix("/api/")`, which the
    /// router happily contradicts — `//api/ping` matches the `api/ping`
    /// handler but does not start with `/api/`, so it reached a gated route
    /// with no token at all (observed 200 vs 401 for the single-slash form).
    /// Every path spelling the router can still match must be gated. Revert
    /// the middleware to the prefix check and this fails.
    func test_configured_gatesPathSpellingsTheRouterStillMatches() async throws {
        let app = Application(router: makeRouter(token: "s3cret"))
        try await app.test(.router) { client in
            for path in ["//api/ping", "/api//ping", "/api/ping/../ping"] {
                try await client.execute(uri: path, method: .get) { response in
                    XCTAssertNotEqual(
                        response.status, .ok,
                        "\(path) reached the handler without a token"
                    )
                }
            }
            // And with the token, the canonical path still works.
            try await client.execute(
                uri: "/api/ping", method: .get,
                headers: [.authorization: "Bearer s3cret"]
            ) { response in
                XCTAssertEqual(response.status, .ok)
            }
        }
    }

    /// The ungated list is exact-match, so a misspelled diagnostics path is
    /// gated rather than skipped — the safe direction.
    func test_configured_gatesMisspelledUngatedPaths() async throws {
        let app = Application(router: makeRouter(token: "s3cret"))
        try await app.test(.router) { client in
            try await client.execute(uri: "/healthz", method: .get) { response in
                XCTAssertEqual(response.status, .ok, "/healthz stays ungated")
            }
            try await client.execute(uri: "//healthz", method: .get) { response in
                XCTAssertNotEqual(response.status, .ok)
            }
        }
    }
}
