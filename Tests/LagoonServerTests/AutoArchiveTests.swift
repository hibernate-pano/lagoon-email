import XCTest
import Foundation
import Logging
import Hummingbird
import NIOCore
import PostgresNIO
import LagoonKit
@testable import LagoonServer

/// Covers the whitelist autopilot (spec 2026-09-19 §3):
/// - `AutoArchiveStore.isValidSenderAddress` boundary checks,
/// - the rules REST API (create/list/delete, idempotency, validation),
/// - the sync loop archiving matched arrivals remotely + locally + audit,
///   and staying remote-first when the provider fails.
final class AutoArchiveTests: XCTestCase {
    private let testLogger = Logger(label: "auto-archive-tests")

    // MARK: - Sender validation (pure)

    func test_senderValidation_acceptsOrdinaryAddresses_andRejectsInjections() {
        let valid = ["alice@example.com", "ALICE@News.Example.COM", "a.b+c@d.io"]
        let invalid = [
            "",
            "no-at-sign",
            "two@@at.com",
            "@missing-local.com",
            "missing-domain@",
            "space in@address.com",
            "header\ninjection@x.com",
            "display <name@x.com>",
            String(repeating: "a", count: 250) + "@x.com", // > 254
        ]
        for address in valid {
            XCTAssertTrue(AutoArchiveStore.isValidSenderAddress(address), "expected valid: \(address)")
        }
        for address in invalid {
            XCTAssertFalse(AutoArchiveStore.isValidSenderAddress(address), "expected invalid: \(address)")
        }
    }

    // MARK: - Rules REST API

    func test_rulesCRUD_createListDelete_isIdempotent() async throws {
        let account = Self.makeAccount()

        try await TestDatabase.withConnection(cleanup: Self.cleanup(accountId: account.id)) { conn in
            try await AccountStore.upsert(account, credentials: Data([1, 2, 3]), db: conn)
            let app = Application(router: Self.router(db: conn))

            try await app.test(.router) { client in
                // Create (mixed case on purpose: the boundary lowercases).
                var response = try await client.execute(
                    uri: "/api/auto-archive?accountId=\(account.id.uuidString)",
                    method: .post,
                    body: ByteBuffer(string: #"{"senderAddress":"News@Example.com"}"#
                    )
                ) { $0 }
                XCTAssertEqual(response.status, .created)
                let created = try Self.iso8601Decoder().decode(
                    AutoArchiveRule.self, from: Data(buffer: response.body)
                )
                XCTAssertEqual(created.senderAddress, "news@example.com")

                // Duplicate create is a no-op returning the same row.
                response = try await client.execute(
                    uri: "/api/auto-archive?accountId=\(account.id.uuidString)",
                    method: .post,
                    body: ByteBuffer(string: #"{"senderAddress":"news@example.com"}"#
                    )
                ) { $0 }
                XCTAssertEqual(response.status, .created)
                let duplicate = try Self.iso8601Decoder().decode(
                    AutoArchiveRule.self, from: Data(buffer: response.body)
                )
                XCTAssertEqual(duplicate.id, created.id)

                // List shows exactly one rule.
                response = try await client.execute(
                    uri: "/api/auto-archive?accountId=\(account.id.uuidString)",
                    method: .get
                ) { $0 }
                XCTAssertEqual(response.status, .ok)
                let list = try Self.iso8601Decoder().decode(
                    AutoArchiveRuleListResponse.self, from: Data(buffer: response.body)
                )
                XCTAssertEqual(list.rules.map(\.id), [created.id])

                // Delete → 204, list drains.
                response = try await client.execute(
                    uri: "/api/auto-archive/\(created.id)?accountId=\(account.id.uuidString)",
                    method: .delete
                ) { $0 }
                XCTAssertEqual(response.status, .noContent)
                response = try await client.execute(
                    uri: "/api/auto-archive?accountId=\(account.id.uuidString)",
                    method: .get
                ) { $0 }
                let drained = try Self.iso8601Decoder().decode(
                    AutoArchiveRuleListResponse.self, from: Data(buffer: response.body)
                )
                XCTAssertTrue(drained.rules.isEmpty)
            }
        }
    }

    func test_rulesCreate_rejectsInvalidSenderAndAccount() async throws {
        let account = Self.makeAccount()

        try await TestDatabase.withConnection(cleanup: Self.cleanup(accountId: account.id)) { conn in
            try await AccountStore.upsert(account, credentials: Data([1, 2, 3]), db: conn)
            let app = Application(router: Self.router(db: conn))

            try await app.test(.router) { client in
                var response = try await client.execute(
                    uri: "/api/auto-archive?accountId=\(account.id.uuidString)",
                    method: .post,
                    body: ByteBuffer(string: #"{"senderAddress":"not an address"}"#)
                ) { $0 }
                XCTAssertEqual(response.status, .badRequest)

                response = try await client.execute(
                    uri: "/api/auto-archive?accountId=not-a-uuid",
                    method: .post,
                    body: ByteBuffer(string: #"{"senderAddress":"a@b.com"}"#)
                ) { $0 }
                XCTAssertEqual(response.status, .badRequest)
            }
        }
    }

    // MARK: - Sync loop integration

    /// A matched arrival is archived remotely, flipped locally and audited
    /// with `autoRule`; an unmatched arrival in the same pull is untouched.
    func test_syncLoop_autoArchivesMatchedArrivals() async throws {
        let oauthUser = "auto-\(UUID().uuidString)"
        let account = Self.engineAccount(oauthUser: oauthUser)

        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            try await TestDatabase.withConnection(cleanup: Self.engineCleanup(oauthUser: oauthUser)) { conn in
                try await Self.seedEngineAccount(account, db: conn)
                try await AutoArchiveStore.create(
                    accountId: account.id,
                    senderAddress: "noise@example.com",
                    db: conn
                )

                let provider = StubMailProvider.once(MailChangeSet(
                    upserts: [
                        .stub(remoteId: "901", fromAddress: "Noise@Example.com", isRead: false),
                        .stub(remoteId: "902", fromAddress: "alice@example.com", isRead: false),
                    ],
                    resetRequired: false,
                    cursor: MailSyncState(uidValidity: 42, lastUid: 902)
                ))
                let engine = Self.makeEngine(db: conn, provider: provider)
                await engine.tickOnce()

                let archiveCalls = await provider.archiveCalls
                XCTAssertEqual(archiveCalls, ["901"], "only the ruled sender is archived, case-insensitively")

                // `recent` filters archived rows by design — the auto-archived
                // message disappearing from the feed is the point. Assert on
                // the raw rows instead.
                let noise = try await MessageStore.find(remoteId: "901", accountId: account.id, db: conn)
                let human = try await MessageStore.find(remoteId: "902", accountId: account.id, db: conn)
                XCTAssertEqual(noise?.isArchived, true)
                XCTAssertEqual(human?.isArchived, false)

                let actions = try await AIActionStore.recent(accountId: account.id, db: conn)
                let autoActions = actions.filter { $0.kind == .archive }
                XCTAssertEqual(autoActions.count, 1)
                XCTAssertEqual(autoActions.first?.payload["autoRule"], "true")
                XCTAssertEqual(autoActions.first?.payload["remoteId"], "901")
            }
        }
    }

    /// Remote-first: a provider failure must leave the local row untouched,
    /// skip the audit and fail the round (cursor not advanced).
    func test_syncLoop_providerFailure_leavesStateUntouchedAndFailsRound() async throws {
        let oauthUser = "auto-\(UUID().uuidString)"
        let account = Self.engineAccount(oauthUser: oauthUser)

        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            try await TestDatabase.withConnection(cleanup: Self.engineCleanup(oauthUser: oauthUser)) { conn in
                try await Self.seedEngineAccount(account, db: conn)
                try await AutoArchiveStore.create(
                    accountId: account.id,
                    senderAddress: "noise@example.com",
                    db: conn
                )

                let provider = StubMailProvider.once(MailChangeSet(
                    upserts: [.stub(remoteId: "901", fromAddress: "noise@example.com", isRead: false)],
                    resetRequired: false,
                    cursor: MailSyncState(uidValidity: 42, lastUid: 901)
                ))
                await provider.setArchiveFailure(MailError.protocolError("MOVE not supported"))
                let engine = Self.makeEngine(db: conn, provider: provider)
                await engine.tickOnce()

                let stored = try await MessageStore.recent(forAccount: account.id, limit: 50, db: conn)
                XCTAssertEqual(stored.first?.isArchived, false, "the row must not flip when the remote move failed")

                let actions = try await AIActionStore.recent(accountId: account.id, db: conn)
                XCTAssertTrue(actions.filter { $0.kind == .archive }.isEmpty, "no audit for an archive that did not happen")

                let health = try await AccountStore.find(byId: account.id, db: conn)?.syncHealth
                XCTAssertEqual(health?.status, .error)
            }
        }
    }

    /// A message that vanished between the pull and the archive (already
    /// handled elsewhere) is skipped without failing the round.
    func test_syncLoop_messageGone_isSkippedAndRoundSucceeds() async throws {
        let oauthUser = "auto-\(UUID().uuidString)"
        let account = Self.engineAccount(oauthUser: oauthUser)

        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            try await TestDatabase.withConnection(cleanup: Self.engineCleanup(oauthUser: oauthUser)) { conn in
                try await Self.seedEngineAccount(account, db: conn)
                try await AutoArchiveStore.create(
                    accountId: account.id,
                    senderAddress: "noise@example.com",
                    db: conn
                )

                let provider = StubMailProvider.once(MailChangeSet(
                    upserts: [.stub(remoteId: "901", fromAddress: "noise@example.com", isRead: false)],
                    resetRequired: false,
                    cursor: MailSyncState(uidValidity: 42, lastUid: 901)
                ))
                await provider.setArchiveFailure(MailError.messageGone)
                let engine = Self.makeEngine(db: conn, provider: provider)
                await engine.tickOnce()

                let health = try await AccountStore.find(byId: account.id, db: conn)?.syncHealth
                XCTAssertEqual(health?.status, .ok)
                let actions = try await AIActionStore.recent(accountId: account.id, db: conn)
                XCTAssertTrue(actions.isEmpty, "no audit for an archive nobody performed")
            }
        }
    }

    // MARK: - Shared fixtures

    private static func makeAccount() -> Account {
        Account(
            id: UUID(),
            provider: .gmail,
            oauthUser: "auto-\(UUID().uuidString)",
            email: "auto-\(UUID().uuidString)@example.com",
            credentials: nil,
            isActive: true
        )
    }

    private static func cleanup(accountId: UUID) -> @Sendable (PostgresConnection) async -> Void {
        { conn in
            try? await TestDatabase.deleteMessages(accountId: accountId, db: conn)
            try? await TestDatabase.deleteAccount(id: accountId, db: conn)
        }
    }

    private static func engineAccount(oauthUser: String) -> Account {
        Account(
            id: UUID(),
            provider: .qq,
            oauthUser: oauthUser,
            email: "\(oauthUser)@qq.com",
            credentials: nil
        )
    }

    private static func engineCleanup(oauthUser: String) -> @Sendable (PostgresConnection) async -> Void {
        { conn in
            try? await TestDatabase.deleteAccount(oauthUser: oauthUser, provider: .qq, db: conn)
        }
    }

    private static func seedEngineAccount(_ account: Account, db: PostgresConnection) async throws {
        try await AccountStore.upsert(
            account,
            credentials: try CredentialVault.seal(
                .imap(username: "\(account.oauthUser)@qq.com", authCode: "auth-code")
            ),
            db: db
        )
        try await AccountStore.setActive(accountId: account.id, db: db)
    }

    private static func makeEngine(db: PostgresConnection, provider: StubMailProvider) -> SyncEngine {
        SyncEngine(
            db: db,
            logger: Logger(label: "auto-archive-tests"),
            providers: { (_: Account) -> (any MailProvider)? in provider },
            sleep: { _ in }
        )
    }

    private static func router(db: PostgresConnection) -> Router<BasicRequestContext> {
        let router = Router()
        AutoArchiveRoutes.register(
            on: router,
            db: db,
            logger: Logger(label: "auto-archive-tests")
        )
        return router
    }

    private static func iso8601Decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
