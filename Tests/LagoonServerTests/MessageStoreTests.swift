import XCTest
import PostgresNIO
import NIOCore
@testable import LagoonServer
@testable import LagoonKit

final class MessageStoreTests: XCTestCase {
    func test_upsert_and_recent() async throws {
        let cfg = PostgresConfig.load()
        let elg = LagoonPostgres.makeEventLoopGroup()
        defer { elg.shutdownGracefully { _ in } }
        let conn = try await LagoonPostgres.connect(cfg, on: elg.any())
        defer { Task { try? await conn.close() } }
        try await MessageStore.deleteAll(db: conn)
        try await AccountStore.deleteAll(db: conn)

        let account = Account(
            id: UUID(),
            provider: .gmail,
            oauthUser: "m-\(UUID().uuidString)",
            email: "m@example.com",
            tokenExpiresAt: Date(),
            historyId: nil
        )
        try await AccountStore.upsert(account, accessToken: Data([1]), refreshToken: Data([1]), db: conn)
        let msg = MessageHeader(
            id: UUID(),
            accountId: account.id,
            gmailId: "g-\(UUID().uuidString)",
            threadId: "t1",
            fromAddress: "alice@example.com",
            fromName: "Alice",
            subject: "Hi",
            snippet: "Hello",
            receivedAt: Date(),
            isRead: false,
            isArchived: false
        )
        try await MessageStore.upsert(msg, db: conn)
        let recent = try await MessageStore.recent(forAccount: account.id, limit: 10, db: conn)
        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(recent.first?.gmailId, msg.gmailId)
        // Leave no residue: the server's Gmail poller would otherwise pick this
        // fake account up every 30 s and hammer the API with a garbage token.
        try await MessageStore.deleteAll(db: conn)
        try await AccountStore.deleteAll(db: conn)
    }
}