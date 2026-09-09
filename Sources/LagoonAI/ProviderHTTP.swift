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
