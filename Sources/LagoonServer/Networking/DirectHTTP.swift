import Foundation

/// URLSession that bypasses the macOS system proxy.
/// A local dev machine running a system proxy (e.g. Clash on 127.0.0.1:7897)
/// broke URLSession TLS to Google endpoints (-1200 over lo0) while direct
/// traffic verified working. M0 keeps all server-side calls on a direct path;
/// M1 revisits when the server runs in a datacenter.
public extension URLSession {
    static let direct: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.connectionProxyDictionary = [:]
        cfg.timeoutIntervalForRequest = 30
        return URLSession(configuration: cfg)
    }()
}

public enum OutboundGuardError: Error {
    case blocked(description: String)
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