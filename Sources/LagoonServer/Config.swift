import Foundation

public struct ServerConfig: Sendable {
    public let port: Int
    public let googleClientID: String
    public let googleClientSecret: String
    public let googleRedirectURI: String

    public static func load() -> ServerConfig {
        let env = ProcessInfo.processInfo.environment
        return ServerConfig(
            port: Int(env["LAGOON_SERVER_PORT"] ?? "8080") ?? 8080,
            googleClientID: env["GMAIL_OAUTH_CLIENT_ID"] ?? "",
            googleClientSecret: env["GMAIL_OAUTH_CLIENT_SECRET"] ?? "",
            googleRedirectURI: env["GMAIL_OAUTH_REDIRECT_URI"]
                ?? "http://127.0.0.1:8080/oauth/gmail/callback"
        )
    }
}