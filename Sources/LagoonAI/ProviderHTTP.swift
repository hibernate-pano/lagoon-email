import Foundation
import CoreFoundation

/// Outbound HTTP for LLM providers.
///
/// Mirrors the server's policy (spec §6.6): explicit proxy from
/// `LAGOON_HTTP_PROXY` or bypass the system proxy, https only, host allowlist,
/// and never follow a redirect (a redirect could hand the provider API key to
/// an unlisted host).
public enum ProviderHTTP {
    public static func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 120
        if let raw = ProcessInfo.processInfo.environment["LAGOON_HTTP_PROXY"],
           !raw.isEmpty,
           let parsed = URL(string: raw.trimmingCharacters(in: .whitespaces)),
           let host = parsed.host,
           let port = parsed.port {
            // The previous comment here claimed the `kCFStreamPropertyHTTPSProxy*`
            // pair was "what actually takes effect for https://", and that
            // dropping it would silently route LLM traffic past the user's proxy.
            // Measured on macOS 27 / Swift 6.4, that claim is false. Probing
            // CFNetwork with a proxy address that is NOT in the system
            // ExceptionsList (a loopback proxy cannot measure this — see below):
            //
            //   kCFNetworkProxiesHTTPSEnable/Proxy/Port   honoured
            //   kCFStreamPropertyHTTPSProxyHost/Port       honoured
            //   both families together (this dictionary)    honoured
            //   empty dictionary                           ignored (system config)
            //
            // So `kCFNetworkProxiesHTTPS*` is the documented, non-deprecated
            // spelling and behaves identically; the deprecated pair is redundant
            // belt-and-braces, kept only so an SDK regression in the documented
            // keys cannot silently bypass the proxy. It is allowlisted in
            // scripts/warn-gate.sh.
            //
            // Measurement note, because this is easy to get wrong: testing
            // against a proxy on 127.0.0.1 (the usual local Clash/Surge setup)
            // produces a FALSE NEGATIVE. `scutil --proxy` lists 127.0.0.1 in
            // ExceptionsList, so CFNetwork bypasses the configured proxy for
            // loopback destinations and the system config answers instead — a
            // kCFNetworkProxiesHTTPS* probe returns kCFErrorDomainCFNetwork/310
            // while an empty dictionary succeeds. That inverted result is what
            // makes the deprecated pair look uniquely necessary.
            cfg.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable as String: true,
                kCFNetworkProxiesHTTPProxy as String: host,
                kCFNetworkProxiesHTTPPort as String: port,
                kCFNetworkProxiesHTTPSEnable as String: true,
                kCFNetworkProxiesHTTPSProxy as String: host,
                kCFNetworkProxiesHTTPSPort as String: port,
                kCFStreamPropertyHTTPSProxyHost as String: host,
                kCFStreamPropertyHTTPSProxyPort as String: port
            ]
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
