import Foundation

public struct ServerConfig: Sendable {
    public let host: String
    public let port: Int
    public let googleClientID: String
    public let googleClientSecret: String
    public let googleRedirectURI: String

    /// M0 has no API authentication, so only loopback binds are safe.
    public var isLoopback: Bool {
        let h = host.trimmingCharacters(in: .whitespaces).lowercased()
        return h == "127.0.0.1" || h == "::1" || h == "localhost"
    }

    /// A wildcard bind accepts every local interface, so it names no single
    /// host a client could legitimately use as its authority.
    public var isWildcardBind: Bool {
        let h = host.trimmingCharacters(in: .whitespaces).lowercased()
        return h == "0.0.0.0" || h == "::" || h == "*" || h.isEmpty
    }

    /// The operator-facing startup refusal, or nil when the configured bind
    /// can be served. A non-loopback bind without an API token would expose
    /// an unauthenticated `/api/*` to the network, so the process must not
    /// start at all — silently binding and answering 403/401 to every caller
    /// is not an option.
    public func startupRefusal(apiToken: String?) -> String? {
        let token = apiToken.flatMap { $0.isEmpty ? nil : $0 }
        guard !isLoopback, token == nil else { return nil }
        return """
            refusing to start: LAGOON_SERVER_HOST=\(host) is not a loopback address.
            Lagoon has NO API authentication without LAGOON_API_TOKEN; binding a non-loopback
            interface would expose the API to the network. Either bind loopback
            (127.0.0.1, ::1, localhost) or set LAGOON_API_TOKEN and configure the same
            token on the client.
            """
    }

    /// Host names the request `Host` header may carry.
    ///
    /// Always the loopback names, plus the configured bind address once the API
    /// is authenticated. The bind address is the operator's explicit
    /// configuration, so a LAN client reaching the machine on it is a
    /// legitimate caller (README advertises exactly that with
    /// `LAGOON_API_TOKEN`). Every other name stays rejected: the Host check is
    /// the DNS-rebinding defence and it is not weakened here — only the
    /// loopback-*name* restriction is widened to the address actually bound.
    ///
    /// ponytail: a wildcard bind (0.0.0.0/::) names no address, so it cannot
    /// widen the allow-list. Ceiling: a wildcard bind + token still answers
    /// 403 to every LAN client, because "which host is this" is unknowable
    /// from the bind config. Upgrade path: bind the concrete LAN address
    /// (LAGOON_SERVER_HOST=192.168.x.x), or teach this list to accept the
    /// interface addresses of the host when a token is set.
    public func allowedHostNames(apiToken: String?) -> Set<String> {
        var names = LoopbackHost.allowedNames
        guard apiToken.flatMap({ $0.isEmpty ? nil : $0 }) != nil, !isWildcardBind else {
            return names
        }
        let bound = LoopbackHost.normalize(host)
        if !bound.isEmpty { names.insert(bound) }
        return names
    }

    public static func load() -> ServerConfig {
        let env = ProcessInfo.processInfo.environment
        return ServerConfig(
            host: env["LAGOON_SERVER_HOST"] ?? "127.0.0.1",
            port: Int(env["LAGOON_SERVER_PORT"] ?? "8080") ?? 8080,
            googleClientID: env["GMAIL_OAUTH_CLIENT_ID"] ?? "",
            googleClientSecret: env["GMAIL_OAUTH_CLIENT_SECRET"] ?? "",
            googleRedirectURI: env["GMAIL_OAUTH_REDIRECT_URI"]
                ?? "http://127.0.0.1:8080/oauth/gmail/callback"
        )
    }
}
