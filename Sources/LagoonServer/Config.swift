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
