import Foundation
import PostgresNIO
import NIOSSL

public struct PostgresConfig {
    public let host: String
    public let port: Int
    public let username: String
    public let password: String
    public let database: String
    public let tls: Bool

    public func makeNIOPostgresConfig() -> PostgresConnection.Configuration {
        var tlsConfig: PostgresConnection.Configuration.TLS = .disable
        if tls {
            let sslContext = try! NIOSSLContext(configuration: .makeClientConfiguration())
            tlsConfig = .require(sslContext)
        }
        return .init(
            host: host,
            port: port,
            username: username,
            password: password,
            database: database,
            tls: tlsConfig
        )
    }

    public static func load() -> PostgresConfig {
        guard let url = ProcessInfo.processInfo.environment["DATABASE_URL"],
              let parsed = URL(string: url),
              let host = parsed.host,
              let port = parsed.port,
              let user = parsed.user,
              let pass = parsed.password
        else { fatalError("DATABASE_URL malformed; see .env.example") }
        let pathParts = parsed.path.split(separator: "/").map(String.init)
        let db = pathParts.last ?? ""
        let tls = parsed.query?.contains("sslmode=require") ?? false
        return PostgresConfig(
            host: host, port: port,
            username: user, password: pass,
            database: db, tls: tls
        )
    }
}