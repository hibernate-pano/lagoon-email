import XCTest
@testable import LagoonServer

/// Covers the bind posture decisions in Sources/LagoonServer/Config.swift:
/// which binds the server refuses to start on, and which host names the
/// Host-header guard accepts once an API token exists.
///
/// The README and .env.example advertise "bind your LAN address + set
/// LAGOON_API_TOKEN". Before this was pinned, the host guard only knew the
/// loopback names, so that advertised bind answered 403 forbidden-host to
/// every LAN client — the capability was dead code.
final class ServerConfigTests: XCTestCase {
    private func config(host: String) -> ServerConfig {
        ServerConfig(
            host: host,
            port: 8080,
            googleClientID: "",
            googleClientSecret: "",
            googleRedirectURI: "http://127.0.0.1:8080/oauth/gmail/callback"
        )
    }

    // MARK: - Startup refusal

    /// Without a token there is no authentication in front of /api/*, so a
    /// non-loopback bind must stop the process rather than start a server that
    /// answers every request.
    func test_startupRefusal_nonLoopbackWithoutToken_refusesToStart() {
        for host in ["192.168.1.50", "0.0.0.0", "::", "lagoon.local"] {
            let refusal = config(host: host).startupRefusal(apiToken: nil)
            XCTAssertNotNil(refusal, "\(host) without a token must not start")
            XCTAssertTrue(
                refusal?.contains("LAGOON_API_TOKEN") == true,
                "the refusal must tell the operator what to set"
            )
            XCTAssertNotNil(
                config(host: host).startupRefusal(apiToken: ""),
                "an empty token is no token"
            )
        }
    }

    /// A loopback bind needs no token; a non-loopback bind with one is exactly
    /// the documented posture and must start.
    func test_startupRefusal_loopbackOrTokenizedBind_starts() {
        XCTAssertNil(config(host: "127.0.0.1").startupRefusal(apiToken: nil))
        XCTAssertNil(config(host: "::1").startupRefusal(apiToken: nil))
        XCTAssertNil(config(host: "localhost").startupRefusal(apiToken: nil))
        XCTAssertNil(config(host: "192.168.1.50").startupRefusal(apiToken: "secret"))
    }

    // MARK: - Host allow-list

    /// The advertised capability: a tokenized non-loopback bind also accepts
    /// the address it actually bound (any port, any spelling).
    func test_allowedHostNames_tokenizedNonLoopbackBind_includesTheBindAddress() {
        let names = config(host: "192.168.1.50").allowedHostNames(apiToken: "secret")
        XCTAssertTrue(names.contains("192.168.1.50"), "the bind address must be served")
        XCTAssertTrue(LoopbackHost.isLoopback("127.0.0.1", allowedNames: names))
        XCTAssertTrue(LoopbackHost.isLoopback("localhost", allowedNames: names))
        XCTAssertTrue(
            LoopbackHost.isLoopback("192.168.1.50:8080", allowedNames: names),
            "a client with an explicit port must match too"
        )
        XCTAssertFalse(
            LoopbackHost.isLoopback("evil.com", allowedNames: names),
            "DNS rebinding protection must survive the widening"
        )
        XCTAssertFalse(
            LoopbackHost.isLoopback("192.168.1.51", allowedNames: names),
            "a different host on the LAN is not the configured bind"
        )
    }

    /// A name bind (the LAN hostname) normalizes like any other host.
    func test_allowedHostNames_tokenizedNameBind_includesTheBindName() {
        let names = config(host: "Lagoon.local").allowedHostNames(apiToken: "secret")
        XCTAssertTrue(LoopbackHost.isLoopback("lagoon.local:8080", allowedNames: names))
    }

    /// Without a token there is no authenticated caller to widen the guard
    /// for, so the list stays loopback-only.
    func test_allowedHostNames_withoutToken_staysLoopbackOnly() {
        let names = config(host: "192.168.1.50").allowedHostNames(apiToken: nil)
        XCTAssertEqual(names, LoopbackHost.allowedNames)
        XCTAssertFalse(LoopbackHost.isLoopback("192.168.1.50", allowedNames: names))
    }

    /// A loopback bind adds nothing (it is already in the list).
    func test_allowedHostNames_loopbackBind_isUnchanged() {
        let names = config(host: "127.0.0.1").allowedHostNames(apiToken: "secret")
        XCTAssertEqual(names, LoopbackHost.allowedNames)
    }

    /// ponytail: a wildcard bind names no address, so nothing can be added to
    /// the allow-list. Ceiling: 0.0.0.0 + token still answers 403 to every LAN
    /// client. Upgrade path: resolve the host's interface addresses at startup
    /// (or accept the OAuth redirect URI's host, which is operator config) and
    /// add them here. Locked so the gap is visible rather than silent.
    func test_allowedHostNames_wildcardBind_staysLoopbackOnly() {
        for host in ["0.0.0.0", "::", "*"] {
            let cfg = config(host: host)
            XCTAssertTrue(cfg.isWildcardBind, "\(host) is a wildcard bind")
            let names = cfg.allowedHostNames(apiToken: "secret")
            XCTAssertEqual(
                names, LoopbackHost.allowedNames,
                "\(host) must not be guessed into the allow-list"
            )
        }
    }
}
