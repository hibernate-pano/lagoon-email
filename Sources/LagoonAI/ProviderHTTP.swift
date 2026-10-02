import Foundation
import CoreFoundation

/// Outbound HTTP for LLM providers.
///
/// Mirrors the server's policy (spec §6.6): explicit proxy from
/// `LAGOON_HTTP_PROXY` or bypass the system proxy, https only, host allowlist,
/// and never follow a redirect (a redirect could hand the provider API key to
/// an unlisted host).
public enum ProviderHTTP {
    /// The `connectionProxyDictionary` for an explicit http+https proxy.
    ///
    /// Extracted from `makeSession()` so it can be unit-tested: a duplicate key
    /// here is a launch-time crash (see the note at the call site), and the
    /// only way to catch that in a test is to build the dictionary the same way
    /// production does — a literal — and assert its contents.
    static func proxyDictionary(host: String, port: Int) -> [String: Any] {
        [
            kCFNetworkProxiesHTTPEnable as String: true,
            kCFNetworkProxiesHTTPProxy as String: host,
            kCFNetworkProxiesHTTPPort as String: port,
            kCFNetworkProxiesHTTPSEnable as String: true,
            kCFNetworkProxiesHTTPSProxy as String: host,
            kCFNetworkProxiesHTTPSPort as String: port,
        ]
    }

    public static func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 120
        if let raw = ProcessInfo.processInfo.environment["LAGOON_HTTP_PROXY"],
           !raw.isEmpty,
           let parsed = URL(string: raw.trimmingCharacters(in: .whitespaces)),
           let host = parsed.host,
           let port = parsed.port {
            // LLM traffic is https, so the keys that matter are the HTTPS ones.
            // Use the documented `kCFNetworkProxiesHTTPS*` spelling.
            //
            // Do NOT also add `kCFStreamPropertyHTTPSProxyHost/Port`. An earlier
            // revision did, on the theory that the deprecated pair was a second
            // independent mechanism worth keeping as a fallback. It is not: the
            // two constant families are the SAME strings —
            //   kCFNetworkProxiesHTTPSProxy      == "HTTPSProxy"
            //   kCFStreamPropertyHTTPSProxyHost  == "HTTPSProxy"   (identical)
            //   kCFNetworkProxiesHTTPSPort       == "HTTPSPort"
            //   kCFStreamPropertyHTTPSProxyPort  == "HTTPSPort"    (identical)
            // Listing both put duplicate keys in one dictionary literal, which
            // is a Swift runtime trap ("Dictionary literal contains duplicate
            // keys") — the app crashed on launch for anyone with
            // LAGOON_HTTP_PROXY set, before the server ever started. It slipped
            // through CI and the whole test suite because no test builds this
            // dictionary via a literal with a proxy configured; the probe that
            // "verified" the proxy used per-key assignment (which silently
            // overwrites instead of trapping), so it exercised a different
            // construction than production. `proxyDictionary` below is a pure
            // function precisely so a test can pin it.
            cfg.connectionProxyDictionary = Self.proxyDictionary(host: host, port: port)
        } else {
            cfg.connectionProxyDictionary = [:]
        }
        return URLSession(configuration: cfg, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    /// https + explicit host allowlist. Anything else fails closed.
    public static func validate(_ url: URL, allowedHosts: Set<String>) throws {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" else {
            throw LLMError.invalidBaseURL(url.absoluteString)
        }
        guard let host = url.host?.lowercased() else {
            throw LLMError.invalidBaseURL(url.absoluteString)
        }
        guard allowedHosts.contains(host) else {
            throw LLMError.blockedHost(host)
        }
    }

    public static func data(
        for request: URLRequest,
        session: URLSession,
        allowedHosts: Set<String>
    ) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw LLMError.invalidBaseURL("nil") }
        try validate(url, allowedHosts: allowedHosts)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.badResponse("non-HTTP response")
        }
        if (300..<400).contains(http.statusCode) { throw LLMError.redirectBlocked }
        return (data, http)
    }

    final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
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
}
