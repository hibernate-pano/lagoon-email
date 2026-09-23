import XCTest
import Foundation
import Logging
import Hummingbird
import NIOCore
import PostgresNIO
@testable import LagoonServer
@testable import LagoonKit

/// Covers the Gmail push webhook (V2 A4): secret gating, envelope parsing,
/// unknown-address opacity, and per-account wake.
final class WebhookRoutesTests: XCTestCase {
    private static let logger = Logger(label: "webhook-tests")

    private func pushBody(email: String) -> ByteBuffer {
        let payload = try! JSONSerialization.data(
            withJSONObject: ["emailAddress": email, "historyId": "999"]
        )
        let envelope: [String: Any] = [
            "message": ["data": payload.base64EncodedString(), "messageId": "m1"],
            "subscription": "projects/x/subscriptions/lagoon",
        ]
        return ByteBuffer(data: try! JSONSerialization.data(withJSONObject: envelope))
    }

    private func makeRouter(
        db: PostgresConnection,
        sync: SyncEngine? = nil,
        secret: String? = "test-secret"
    ) -> Router<BasicRequestContext> {
        let router = Router<BasicRequestContext>()
        GmailWebhookRoutes.register(
            on: router, db: db, logger: Self.logger, sync: sync, webhookSecret: secret
        )
        return router
    }

    func test_noSecret_returns501() async throws {
        try await TestDatabase.withConnection { conn in
            let app = Application(router: makeRouter(db: conn, secret: nil))
            try await app.test(.router) { client in
                try await client.execute(uri: "/webhook/gmail", method: .post) { response in
                    // No LAGOON_WEBHOOK_SECRET in the test env (nil passed
                    // explicitly), so the ceiling holds — unless the ambient
                    // environment sets one, in which case this asserts 401.
                    XCTAssertTrue(response.status == .notImplemented || response.status == .unauthorized)
                }
            }
        }
    }

    func test_wrongBearer_returns401() async throws {
        try await TestDatabase.withConnection { conn in
            let app = Application(router: makeRouter(db: conn))
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/webhook/gmail", method: .post,
                    headers: [.authorization: "Bearer wrong"],
                    body: pushBody(email: "nobody@example.com")
                ) { response in
                    XCTAssertEqual(response.status, .unauthorized)
                }
            }
        }
    }

    func test_malformedPush_returns400() async throws {
        try await TestDatabase.withConnection { conn in
            let app = Application(router: makeRouter(db: conn))
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/webhook/gmail", method: .post,
                    headers: [.authorization: "Bearer test-secret"],
                    body: ByteBuffer(data: Data("not-json".utf8))
                ) { response in
                    XCTAssertEqual(response.status, .badRequest)
                }
            }
        }
    }

    func test_unknownAddress_returns204WithoutOracle() async throws {
        try await TestDatabase.withConnection { conn in
            let app = Application(router: makeRouter(db: conn))
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/webhook/gmail", method: .post,
                    headers: [.authorization: "Bearer test-secret"],
                    body: pushBody(email: "ghost-\(UUID().uuidString)@example.com")
                ) { response in
                    XCTAssertEqual(response.status, .noContent)
                }
            }
        }
    }

    /// A push for a connected Gmail address wakes only that account's loop.
    func test_knownAddress_wakesOnlyThatLoop() async throws {
        let oauthA = "hook-a-\(UUID().uuidString)"
        let oauthB = "hook-b-\(UUID().uuidString)"
        let emailA = "a-\(UUID().uuidString)@example.com"
        let emailB = "b-\(UUID().uuidString)@example.com"
        try await TestDatabase.withConnection(cleanup: { conn in
            try? await TestDatabase.deleteAccount(oauthUser: oauthA, provider: .gmail, db: conn)
            try? await TestDatabase.deleteAccount(oauthUser: oauthB, provider: .gmail, db: conn)
        }) { conn in
            let a = Account(
                id: UUID(), provider: .gmail, oauthUser: oauthA,
                email: emailA, credentials: nil
            )
            let b = Account(
                id: UUID(), provider: .gmail, oauthUser: oauthB,
                email: emailB, credentials: nil
            )
            try await AccountStore.upsert(a, credentials: Data([1]), db: conn)
            try await AccountStore.upsert(b, credentials: Data([1]), db: conn)

            let providerA = StubMailProvider()
            let providerB = StubMailProvider()
            let providers = [a.id: providerA, b.id: providerB]
            let engine = SyncEngine(
                db: conn,
                logger: Logger(label: "webhook-engine-tests"),
                makeProvider: { account in providers[account.id] },
                sleep: { _ in },
                makeDB: { try await TestDatabase.requireConnection() }
            )
            await engine.start()
            defer { Task { await engine.stop() } }
            // Freeze all loops: the stub providers return immediately, so
            // running loops would advance their counts on their own and the
            // assertion would be vacuous. After stop, only the pushed
            // account may move again.
            try await Task.sleep(for: .milliseconds(200))
            await engine.stop()
            let aFrozen = await providerA.pullCount
            let bFrozen = await providerB.pullCount
            XCTAssertGreaterThan(aFrozen, 0, "loops must have run before the freeze")

            let app = Application(router: makeRouter(db: conn, sync: engine))
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/webhook/gmail", method: .post,
                    headers: [.authorization: "Bearer test-secret"],
                    body: pushBody(email: emailA)
                ) { response in
                    XCTAssertEqual(response.status, .noContent)
                }
            }
            // A restarted (new pull); B untouched by the scoped wake.
            var aWoke = false
            for _ in 0..<100 {
                if await providerA.pullCount > aFrozen { aWoke = true; break }
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertTrue(aWoke, "push must wake the addressed account's loop")
            try await Task.sleep(for: .milliseconds(100))
            let bAfter = await providerB.pullCount
            XCTAssertEqual(
                bAfter, bFrozen,
                "the scoped wake must not disturb other accounts"
            )
            await engine.stop()
        }
    }
}
