import XCTest
import PostgresNIO
import NIOCore
@testable import LagoonServer
@testable import LagoonKit

final class AccountStoreTests: XCTestCase {
    func test_upsert_then_find_roundtrip() async throws {
        let cfg = PostgresConfig.load()
        let elg = LagoonPostgres.makeEventLoopGroup()
        defer { elg.shutdownGracefully { _ in } }
        let conn = try await LagoonPostgres.connect(cfg, on: elg.any())
        defer { Task { try? await conn.close() } }
        try await AccountStore.deleteAll(db: conn)

        let a = Account(
            id: UUID(),
            provider: .gmail,
            oauthUser: "u-\(UUID().uuidString)",
            email: "u@example.com",
            tokenExpiresAt: Date(),
            historyId: nil
        )
        try await AccountStore.upsert(
            a,
            accessToken: Data([1,2,3]),
            refreshToken: Data([4,5,6]),
            db: conn
        )
        let back = try await AccountStore.find(
            byOAuthUser: a.oauthUser,
            provider: .gmail,
            db: conn
        )
        XCTAssertEqual(back?.id, a.id)
        // Leave no residue: the server's Gmail poller would otherwise pick this
        // fake account up every 30 s and hammer the API with a garbage token.
        try await AccountStore.deleteAll(db: conn)
    }
}