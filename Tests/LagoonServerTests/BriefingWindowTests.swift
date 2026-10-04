import XCTest
import Foundation
import Logging
import Hummingbird
import HummingbirdTesting
import NIOCore
import GRDB
@testable import LagoonKit
@testable import LagoonServer

/// Pins the briefing's window: **the last 30 days**, capped at 500 rows with
/// the overflow reported.
///
/// The window is a time bound rather than a row count because that is what
/// "recent" means. A fixed count answers a different question: it drops mail
/// on a busy week and pads the feed with stale mail on a quiet one. The cap
/// exists only so a mailbox receiving thousands of messages a month cannot
/// produce a one-megabyte response and a matching LLM bill in a single pass —
/// and when it bites, the response has to say so instead of looking complete.
final class BriefingWindowTests: XCTestCase {
    private let logger = Logger(label: "briefing-window-tests")

    private func makeAccount() -> Account {
        Account(
            id: UUID(),
            provider: .qq,
            oauthUser: "win-\(UUID().uuidString)",
            email: "win-\(UUID().uuidString)@qq.com",
            credentials: nil
        )
    }

    private func seed(_ account: Account, db: LagoonDB) async throws {
        try await AccountStore.upsert(
            account,
            credentials: try CredentialVault.seal(
                .imap(username: account.email, authCode: "auth-code")
            ),
            db: db
        )
    }

    private func header(
        _ remoteId: String,
        accountId: UUID,
        daysAgo: Double
    ) -> MessageHeader {
        MessageHeader(
            id: UUID(),
            accountId: accountId,
            remoteId: remoteId,
            threadId: "t-\(remoteId)",
            fromAddress: "sender@example.com",
            fromName: "Sender",
            subject: "Subject \(remoteId)",
            snippet: nil,
            receivedAt: Date().addingTimeInterval(-daysAgo * 24 * 60 * 60),
            isRead: false,
            isArchived: false
        )
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func router(_ db: LagoonDB) -> Router<BasicRequestContext> {
        let router = Router()
        BriefingRoutes.register(on: router, db: db, logger: self.logger)
        return router
    }


    // MARK: - The 30-day window

    /// Mail older than 30 days is out of the briefing entirely — it is not a
    /// row the user has to scroll past, and it is not sent to the classifier.
    func test_mailOlderThan30Days_isExcluded() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await MessageStore.upsert(
                    header("recent", accountId: account.id, daysAgo: 3), db: conn
                )
                try await MessageStore.upsert(
                    header("edge", accountId: account.id, daysAgo: 29), db: conn
                )
                try await MessageStore.upsert(
                    header("stale", accountId: account.id, daysAgo: 31), db: conn
                )
                try await MessageStore.upsert(
                    header("ancient", accountId: account.id, daysAgo: 400), db: conn
                )

                let app = Application(router: router(conn))
                try await app.test(.router) { client in
                    try await client.execute(
                        uri: "/api/briefing?accountId=\(account.id.uuidString)",
                        method: .get
                    ) { response in
                        XCTAssertEqual(response.status, .ok)
                        let body = try Self.decoder().decode(BriefingResponse.self, from: Data(buffer: response.body))
                        XCTAssertEqual(
                            Set(body.items.map(\.message.remoteId)),
                            ["recent", "edge"],
                            "only mail inside the 30-day window belongs in the Briefing"
                        )
                        XCTAssertNil(
                            body.omittedCount,
                            "a window that fits must not report an omission"
                        )
                    }
                }
            }
        }
    }

    /// A quiet month is a short feed — not a feed padded out to 100 rows with
    /// mail from months ago. This is the case the old row-count window got
    /// wrong in the other direction.
    func test_quietWindow_returnsShortFeed_notPaddedToAFixedCount() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                // 3 in-window, plus 40 outside it that a 100-row window would
                // have happily included.
                for i in 0..<3 {
                    try await MessageStore.upsert(
                        header("in-\(i)", accountId: account.id, daysAgo: Double(i) + 1), db: conn
                    )
                }
                for i in 0..<40 {
                    try await MessageStore.upsert(
                        header("out-\(i)", accountId: account.id, daysAgo: Double(45 + i)), db: conn
                    )
                }

                let app = Application(router: router(conn))
                try await app.test(.router) { client in
                    try await client.execute(
                        uri: "/api/briefing?accountId=\(account.id.uuidString)",
                        method: .get
                    ) { response in
                        let body = try Self.decoder().decode(BriefingResponse.self, from: Data(buffer: response.body))
                        XCTAssertEqual(body.items.count, 3, "the feed is the window, not a row quota")
                    }
                }
            }
        }
    }

    // MARK: - The cap and its honest report

    /// When the window holds more than the cap allows, the response says how
    /// many rows it left out. Without this the feed looks complete while part
    /// of the window is silently missing — the failure mode the whole change
    /// exists to remove.
    func test_windowOverflow_reportsTheOmittedCount() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                // 8 in-window rows, requested with a cap of 5.
                for i in 0..<8 {
                    try await MessageStore.upsert(
                        header("m-\(i)", accountId: account.id, daysAgo: Double(i) + 1), db: conn
                    )
                }

                let app = Application(router: router(conn))
                try await app.test(.router) { client in
                    try await client.execute(
                        uri: "/api/briefing?accountId=\(account.id.uuidString)&limit=5",
                        method: .get
                    ) { response in
                        let body = try Self.decoder().decode(BriefingResponse.self, from: Data(buffer: response.body))
                        XCTAssertEqual(body.items.count, 5, "the cap is honoured")
                        XCTAssertEqual(
                            body.omittedCount, 3,
                            "the response must say 3 rows of the window are missing, not look complete"
                        )
                    }
                }
            }
        }
    }

    /// The omitted count covers the *window*, not the whole mailbox: mail
    /// outside the 30 days is not "omitted", it is out of scope.
    func test_omittedCount_excludesMailOutsideTheWindow() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                for i in 0..<6 {
                    try await MessageStore.upsert(
                        header("in-\(i)", accountId: account.id, daysAgo: Double(i) + 1), db: conn
                    )
                }
                for i in 0..<10 {
                    try await MessageStore.upsert(
                        header("old-\(i)", accountId: account.id, daysAgo: Double(60 + i)), db: conn
                    )
                }

                let app = Application(router: router(conn))
                try await app.test(.router) { client in
                    try await client.execute(
                        uri: "/api/briefing?accountId=\(account.id.uuidString)&limit=4",
                        method: .get
                    ) { response in
                        let body = try Self.decoder().decode(BriefingResponse.self, from: Data(buffer: response.body))
                        XCTAssertEqual(body.items.count, 4)
                        XCTAssertEqual(
                            body.omittedCount, 2,
                            "only the 2 in-window rows beyond the cap count; the 10 old ones are out of scope"
                        )
                    }
                }
            }
        }
    }

    /// The cap is a safety valve, not a policy knob: a client asking for more
    /// than `maxItems` still gets at most `maxItems`.
    func test_limit_isClampedToTheHardCap() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await MessageStore.upsert(
                    header("only", accountId: account.id, daysAgo: 1), db: conn
                )
                let app = Application(router: router(conn))
                try await app.test(.router) { client in
                    try await client.execute(
                        uri: "/api/briefing?accountId=\(account.id.uuidString)&limit=100000",
                        method: .get
                    ) { response in
                        XCTAssertEqual(response.status, .ok, "an over-large limit is clamped, not rejected")
                    }
                }
            }
        }
    }

    // MARK: - The window constant itself

    /// Pinned so a future edit cannot quietly widen the window (a cost and
    /// privacy decision) or narrow it (a coverage regression) without the
    /// author seeing this number.
    func test_windowAndCap_areTheAgreedValues() {
        XCTAssertEqual(BriefingRoutes.windowDays, 30)
        XCTAssertEqual(BriefingRoutes.maxItems, 500)
    }
}
