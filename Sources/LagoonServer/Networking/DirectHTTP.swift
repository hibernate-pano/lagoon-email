import Foundation
import CoreFoundation

/// URLSession for all server-side outbound calls.
///
/// Proxy policy (config-free by design):
/// - `LAGOON_HTTP_PROXY` set (e.g. "http://127.0.0.1:7897"): all outbound
///   traffic goes through that proxy explicitly. This is the normal setup on
///   a dev machine whose network cannot reach Google directly.
/// - Unset: the session bypasses the macOS system proxy entirely and connects
///   directly. This is the datacenter / TUN-mode setup.
///
/// We never touch the OS system-proxy settings; we either bypass them or
/// pin our own explicit proxy from env.
public extension URLSession {
    static let outbound: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        if let raw = ProcessInfo.processInfo.environment["LAGOON_HTTP_PROXY"],
           !raw.isEmpty,
           let parsed = URL(string: raw.trimmingCharacters(in: .whitespaces)),
           let host = parsed.host,
           let port = parsed.port {
            cfg.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable as String: true,
                kCFNetworkProxiesHTTPProxy as String: host,
                kCFNetworkProxiesHTTPPort as String: port,
                kCFStreamPropertyHTTPSProxyHost as String: host,
                kCFStreamPropertyHTTPSProxyPort as String: port
            ]
        } else {
            cfg.connectionProxyDictionary = [:]
        }
        // Delegate returns nil for every redirect, so the session never
        // forwards the Authorization header to a new host.
        return URLSession(
            configuration: cfg,
            delegate: OutboundNoRedirectDelegate(),
            delegateQueue: nil
        )
    }()

    /// `data(for:)` for outbound calls that also fails closed on a 3xx.
    func outboundData(for request: URLRequest) async throws -> (Data, URLResponse) {
        let (data, response) = try await data(for: request)
        if let http = response as? HTTPURLResponse, (300..<400).contains(http.statusCode) {
            throw OutboundRedirectError.redirectBlocked
        }
        return (data, response)
    }
}

public enum OutboundGuardError: Error {
    case blocked(description: String)
}

/// Prevents the outbound session from following any HTTP redirect.
/// Google/Gmail APIs never redirect; a redirect could hand our Bearer token
/// to a host outside `OutboundGuard.allowedHosts`, so we refuse to follow it.
final class OutboundNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// Surfaced when the `.outbound` session sees a 3xx instead of the expected
/// API response (see `OutboundNoRedirectDelegate`).
public enum OutboundRedirectError: Error {
    public static let redirectBlocked = NSError(
        domain: "Lagoon.OutboundRedirect",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "outbound HTTP redirect blocked"]
    )
}

/// Server-side outbound host allowlist (spec §6.6 rule 2).
/// Only https + known API hosts; never loopback / private / reserved addresses.
public enum OutboundGuard {
    public static let allowedHosts: Set<String> = [
        "accounts.google.com",
        "oauth2.googleapis.com",
        "openidconnect.googleapis.com",
        "gmail.googleapis.com"
    ]

    public static func validate(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" else {
            throw OutboundGuardError.blocked(description: "non-https outbound URL: \(url)")
        }
        guard let host = url.host?.lowercased() else {
            throw OutboundGuardError.blocked(description: "outbound URL without host: \(url)")
        }
        guard allowedHosts.contains(host) else {
            throw OutboundGuardError.blocked(description: "outbound host not in allowlist: \(host)")
        }
    }
}