import XCTest
import Hummingbird
import HummingbirdTesting
@testable import LagoonServer

/// Covers `LoopbackHostMiddleware` (Sources/LagoonServer/Networking/HostGuard.swift):
/// the loopback-only host check that closes the DNS-rebinding path into an
/// unauthenticated local API.
final class HostGuardTests: XCTestCase {

    // MARK: - Normalization

    func test_normalize_stripsPortAndIPv6Brackets() {
        XCTAssertEqual(LoopbackHost.normalize("127.0.0.1"), "127.0.0.1")
        XCTAssertEqual(LoopbackHost.normalize("127.0.0.1:8080"), "127.0.0.1")
        XCTAssertEqual(LoopbackHost.normalize("LOCALHOST:8080"), "localhost")
        XCTAssertEqual(LoopbackHost.normalize("[::1]:8080"), "::1")
        XCTAssertEqual(LoopbackHost.normalize("[::1]"), "::1")
        XCTAssertEqual(LoopbackHost.normalize("::1"), "::1")
        XCTAssertEqual(LoopbackHost.normalize("  evil.com:443  "), "evil.com")
    }

    func test_isLoopback_truthTable() {
        for host in ["127.0.0.1", "127.0.0.1:8080", "localhost", "localhost:8080", "::1", "[::1]:8080"] {
            XCTAssertTrue(LoopbackHost.isLoopback(host), "expected loopback: \(host)")
        }
        for host in ["evil.com", "evil.com:8080", "127.0.0.1.evil.com", "0.0.0.0", "192.168.1.10", "", "::1.evil.com"] {
            XCTAssertFalse(LoopbackHost.isLoopback(host), "expected non-loopback: \(host)")
        }
    }

    // MARK: - Middleware

    private func makeApp(
        host: @escaping @Sendable (Request) -> String? = { $0.head.authority }
    ) -> Application<RouterResponder<BasicRequestContext>> {
        let router = Router()
        router.add(middleware: LoopbackHostMiddleware<BasicRequestContext>(host: host))
        router.get("healthz") { _, _ in Response(status: .ok) }
        return Application(router: router)
    }

    /// The in-process test framework sends authority "localhost", so the
    /// allow path is exercised end-to-end through the real router.
    func test_loopbackAuthority_isServed() async throws {
        let app = makeApp()
        try await app.test(.router) { client in
            try await client.execute(uri: "/healthz", method: .get) { response in
                XCTAssertEqual(response.status, .ok)
            }
        }
    }

    /// A browser tricked into resolving an attacker domain to 127.0.0.1 sends
    /// that domain as the authority. It must never reach a route.
    func test_nonLoopbackAuthority_isForbidden() async throws {
        for hostile in ["evil.com", "evil.com:8080", "127.0.0.1.evil.com", "192.168.1.10"] {
            let app = makeApp(host: { _ in hostile })
            try await app.test(.router) { client in
                try await client.execute(uri: "/healthz", method: .get) { response in
                    XCTAssertEqual(response.status, .forbidden, "host \(hostile) must be rejected")
                    XCTAssertEqual(
                        response.headers[.contentType],
                        "application/json; charset=utf-8"
                    )
                    XCTAssertEqual(
                        String(buffer: response.body),
                        #"{"error":"forbidden-host"}"#,
                        "the error envelope must name the reason"
                    )
                }
            }
        }
    }

    /// Fail closed: a request that carries no host at all is not a legitimate
    /// local client.
    func test_missingHost_isForbidden() async throws {
        let app = makeApp(host: { _ in nil })
        try await app.test(.router) { client in
            try await client.execute(uri: "/healthz", method: .get) { response in
                XCTAssertEqual(response.status, .forbidden)
            }
        }
    }

    /// A non-loopback route is untouched when the host is acceptable, and the
    /// middleware passes the request through unchanged.
    func test_loopbackWithPort_isServed() async throws {
        let app = makeApp(host: { _ in "127.0.0.1:8080" })
        try await app.test(.router) { client in
            try await client.execute(uri: "/healthz", method: .get) { response in
                XCTAssertEqual(response.status, .ok)
            }
        }
    }
}
