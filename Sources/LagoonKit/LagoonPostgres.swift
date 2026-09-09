import Foundation
import PostgresNIO
import NIOCore
import Logging

/// Shared helpers for opening a Postgres connection.
/// Used by tests and the server; M1 will replace single-connection usage
/// with a PostgresClient pool.
public enum LagoonPostgres {
    public static func connect(_ cfg: PostgresConfig, on eventLoop: any EventLoop) async throws -> PostgresConnection {
        try await PostgresConnection.connect(
            on: eventLoop,
            configuration: cfg.makeNIOPostgresConfig(),
            id: Int.random(in: 1...Int.max / 2),
            logger: Logger(label: "lagoon.postgres")
        ).get()
    }

    public static func makeEventLoopGroup() -> any EventLoopGroup {
        MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }
}