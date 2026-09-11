import XCTest
import Foundation
import Logging
import PostgresNIO
@testable import LagoonServer
@testable import LagoonKit

/// Drives `SyncEngine` with a scripted provider against the guarded test DB:
/// the whole round — pull → persist → cursor → health → backoff — with no
/// network and no wall-clock sleeping.
final class SyncEngineTests: XCTestCase {
    // MARK: - Fixtures

    private func makeAccount(oauthUser: String) -> Account {
        Account(
            id: UUID(),
            provider: .qq,
            oauthUser: oauthUser,
            email: "\(oauthUser)@qq.com",
            credentials: nil
        )
    }

    private func seed(_ account: Account, db: PostgresConnection) async throws {
        try await AccountStore.upsert(
            account,
            credentials: try CredentialVault.seal(
                .imap(username: "\(account.oauthUser)@qq.com", authCode: "auth-code")
            ),
            db: db
        )
        // The engine only ever syncs the single active account.
        try await AccountStore.setActive(accountId: account.id, db: db)
    }

    private func cleanup(_ oauthUser: String) -> @Sendable (PostgresConnection) async -> Void {
        { conn in
            try? await TestDatabase.deleteAccount(oauthUser: oauthUser, provider: .qq, db: conn)
        }
    }

    private func makeEngine(
        db: PostgresConnection,
        provider: (any MailProvider)?,
        sleeper: SleepRecorder = SleepRecorder(),
        counter: CallCounter? = nil
    ) -> SyncEngine {
        SyncEngine(
            db: db,
            logger: Logger(label: "sync-engine-tests"),
            providers: { (_: Account) -> (any MailProvider)? in
                counter?.bump()
                return provider
            },
            sleep: { duration in sleeper.record(duration) }
        )
    }

    private func health(_ accountId: UUID, db: PostgresConnection) async throws -> SyncHealth? {
        try await AccountStore.find(byId: accountId, db: db)?.syncHealth
    }

    private func syncState(_ accountId: UUID, db: PostgresConnection) async throws -> MailSyncState? {
        try await AccountStore.find(byId: accountId, db: db)?.syncState
    }

    /// The backoff is `base ± 20% jitter` (spec §3.4).
    private func assertBackoff(
        _ duration: Duration,
        around seconds: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let components = duration.components
        let actual = Double(components.seconds) + Double(components.attoseconds) / 1e18
        XCTAssertGreaterThanOrEqual(actual, seconds * 0.8, file: file, line: line)
        XCTAssertLessThanOrEqual(actual, seconds * 1.2, file: file, line: line)
    }

    // MARK: - Tests

    /// (a) upserts land in the store, the cursor advances, health turns ok.
    func test_success_appliesUpserts_advancesCursor_andReportsOk() async throws {
        let oauthUser = "sync-\(UUID().uuidString)"

        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            try await TestDatabase.withConnection(cleanup: cleanup(oauthUser)) { conn in
                let account = makeAccount(oauthUser: oauthUser)
                try await seed(account, db: conn)

                let cursor = MailSyncState(uidValidity: 42, lastUid: 900)
                let provider = StubMailProvider.once(MailChangeSet(
                    upserts: [
                        .stub(
                            remoteId: "901",
                            subject: "One",
                            isRead: false,
                            listUnsubscribe: true
                        ),
                        .stub(remoteId: "902", subject: "Two"),
                    ],
                    resetRequired: false,
                    cursor: cursor
                ))
                let sleeper = SleepRecorder()
                let engine = makeEngine(db: conn, provider: provider, sleeper: sleeper)

                await engine.tickOnce()

                let stored = try await MessageStore.recent(
                    forAccount: account.id,
                    limit: 50,
                    db: conn
                )
                XCTAssertEqual(stored.count, 2)
                XCTAssertEqual(Set(stored.map(\.remoteId)), ["901", "902"])
                let unread = stored.first { $0.remoteId == "901" }
                XCTAssertEqual(unread?.subject, "One")
                XCTAssertEqual(unread?.isRead, false)
                XCTAssertEqual(
                    unread?.messageIdHeader, "<901@example.com>",
                    "threading headers must survive the round trip"
                )
                let unsubscribeIds = try await MessageStore.listUnsubscribeIds(
                    forAccount: account.id,
                    db: conn
                )
                XCTAssertEqual(unsubscribeIds, ["901"])

                let updated = try await AccountStore.find(byId: account.id, db: conn)
                XCTAssertEqual(
                    updated?.syncState, cursor,
                    "the cursor must be persisted only after the write"
                )
                XCTAssertEqual(updated?.syncHealth.status, .ok)
                XCTAssertNotNil(updated?.syncHealth.lastSyncAt)
                XCTAssertNil(updated?.syncHealth.lastError)
                XCTAssertEqual(sleeper.durations, [], "a successful round must not pause")

                let pullCount = await provider.pullCount
                let passedCursor = await provider.lastCursor
                XCTAssertEqual(pullCount, 1)
                XCTAssertEqual(
                    passedCursor, MailSyncState(),
                    "the stored cursor is handed to the provider"
                )
            }
        }
    }

    /// (b) `resetRequired` (UIDVALIDITY change) wipes stale rows first, then the
    /// cursor is reset to the new identity space.
    func test_resetRequired_wipesStaleRowsBeforeApplying() async throws {
        let oauthUser = "sync-\(UUID().uuidString)"

        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            try await TestDatabase.withConnection(cleanup: cleanup(oauthUser)) { conn in
                let account = makeAccount(oauthUser: oauthUser)
                try await seed(account, db: conn)

                // A row from before the UID space was renumbered: its UIDs now
                // point at unrelated messages.
                try await MessageStore.upsert(
                    MessageHeader(
                        id: UUID(),
                        accountId: account.id,
                        remoteId: "stale-1",
                        threadId: "stale-thread",
                        fromAddress: "old@example.com",
                        fromName: nil,
                        subject: "Old",
                        snippet: nil,
                        receivedAt: Date(),
                        isRead: true,
                        isArchived: false
                    ),
                    listUnsubscribe: false,
                    db: conn
                )

                let cursor = MailSyncState(uidValidity: 77, lastUid: 5)
                let provider = StubMailProvider.once(MailChangeSet(
                    upserts: [.stub(remoteId: "5")],
                    resetRequired: true,
                    cursor: cursor
                ))
                let engine = makeEngine(db: conn, provider: provider)

                await engine.tickOnce()

                let stored = try await MessageStore.recent(
                    forAccount: account.id,
                    limit: 50,
                    db: conn
                )
                XCTAssertEqual(
                    Set(stored.map(\.remoteId)), ["5"],
                    "the pre-reset rows must be gone"
                )
                let state = try await syncState(account.id, db: conn)
                XCTAssertEqual(state, cursor)
            }
        }
    }

    /// (c) `authFailed` → `needsReconnect` plus a long pause: credentials must
    /// not be retried in a tight loop (QQ rate-limits failed logins).
    func test_authFailure_marksNeedsReconnect_andPauses() async throws {
        let oauthUser = "sync-\(UUID().uuidString)"

        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            try await TestDatabase.withConnection(cleanup: cleanup(oauthUser)) { conn in
                let account = makeAccount(oauthUser: oauthUser)
                try await seed(account, db: conn)

                let provider = StubMailProvider.failing(.authFailed)
                let sleeper = SleepRecorder()
                let engine = makeEngine(db: conn, provider: provider, sleeper: sleeper)

                await engine.tickOnce()

                let updated = try await health(account.id, db: conn)
                XCTAssertEqual(updated?.status, .needsReconnect)
                XCTAssertEqual(
                    updated?.lastError, "auth-failed",
                    "only the stable label is stored, never credential material"
                )
                XCTAssertEqual(
                    sleeper.durations, [.seconds(60)],
                    "an auth failure must pause, not hot-loop"
                )
                let pullCount = await provider.pullCount
                XCTAssertEqual(pullCount, 1)
            }
        }
    }

    /// (d) transient failures back off exponentially and escalate to `degraded`
    /// on the third consecutive round.
    func test_transientFailure_backsOff_andDegradesAfterThreeRounds() async throws {
        let oauthUser = "sync-\(UUID().uuidString)"

        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            try await TestDatabase.withConnection(cleanup: cleanup(oauthUser)) { conn in
                let account = makeAccount(oauthUser: oauthUser)
                try await seed(account, db: conn)

                let provider = StubMailProvider.failing(.unreachable("stub"))
                let sleeper = SleepRecorder()
                let engine = makeEngine(db: conn, provider: provider, sleeper: sleeper)

                await engine.tickOnce()
                let first = try await health(account.id, db: conn)
                XCTAssertEqual(first?.status, .error)
                XCTAssertEqual(first?.lastError, "unreachable")

                await engine.tickOnce()
                let second = try await health(account.id, db: conn)
                XCTAssertEqual(second?.status, .error)

                await engine.tickOnce()
                let third = try await health(account.id, db: conn)
                XCTAssertEqual(
                    third?.status, .degraded,
                    "three consecutive failures escalate to degraded"
                )

                XCTAssertEqual(sleeper.durations.count, 3)
                guard sleeper.durations.count == 3 else { return }
                assertBackoff(sleeper.durations[0], around: 1)
                assertBackoff(sleeper.durations[1], around: 2)
                assertBackoff(sleeper.durations[2], around: 4)
            }
        }
    }

    /// (e) a successful round clears the failure counter, so the next failure
    /// starts backing off from 1s again rather than from where it left off.
    func test_success_resetsTheBackoffCounter() async throws {
        let oauthUser = "sync-\(UUID().uuidString)"

        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            try await TestDatabase.withConnection(cleanup: cleanup(oauthUser)) { conn in
                let account = makeAccount(oauthUser: oauthUser)
                try await seed(account, db: conn)

                let provider = StubMailProvider(pulls: [
                    .failure(.unreachable("stub")),
                    .success(MailChangeSet(
                        upserts: [.stub(remoteId: "1")],
                        resetRequired: false,
                        cursor: MailSyncState(uidValidity: 1, lastUid: 1)
                    )),
                    .failure(.unreachable("stub")),
                ])
                let sleeper = SleepRecorder()
                let engine = makeEngine(db: conn, provider: provider, sleeper: sleeper)

                await engine.tickOnce()
                let failed = try await health(account.id, db: conn)
                XCTAssertEqual(failed?.status, .error)

                await engine.tickOnce()
                let recovered = try await health(account.id, db: conn)
                XCTAssertEqual(recovered?.status, .ok)

                await engine.tickOnce()
                let failedAgain = try await health(account.id, db: conn)
                XCTAssertEqual(failedAgain?.status, .error)
                // Two failures, two pauses: the successful round in between
                // must not be counted as a failure.
                XCTAssertEqual(sleeper.durations.count, 2)
                guard sleeper.durations.count == 2 else { return }
                assertBackoff(sleeper.durations[0], around: 1)
                assertBackoff(sleeper.durations[1], around: 1)
            }
        }
    }

    /// (f) the factory runs once per account: a provider carries connection
    /// state (IDLE socket / Gmail poll baseline) that must survive ticks.
    func test_providerFactory_runsOncePerAccount() async throws {
        let oauthUser = "sync-\(UUID().uuidString)"

        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            try await TestDatabase.withConnection(cleanup: cleanup(oauthUser)) { conn in
                let account = makeAccount(oauthUser: oauthUser)
                try await seed(account, db: conn)

                let counter = CallCounter()
                let engine = makeEngine(
                    db: conn,
                    provider: StubMailProvider(),
                    counter: counter
                )

                await engine.tickOnce()
                await engine.tickOnce()

                XCTAssertEqual(counter.value, 1)
            }
        }
    }

    /// (g) an account whose provider is unavailable is visibly unhealthy
    /// instead of silently unsynced (the `.qq` state before Task 8).
    func test_missingProvider_recordsNoProviderHealth() async throws {
        let oauthUser = "sync-\(UUID().uuidString)"

        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            try await TestDatabase.withConnection(cleanup: cleanup(oauthUser)) { conn in
                let account = makeAccount(oauthUser: oauthUser)
                try await seed(account, db: conn)

                let sleeper = SleepRecorder()
                let engine = makeEngine(db: conn, provider: nil, sleeper: sleeper)

                await engine.tickOnce()

                let updated = try await health(account.id, db: conn)
                XCTAssertEqual(updated?.status, .error)
                XCTAssertEqual(updated?.lastError, "no-provider")
                XCTAssertEqual(sleeper.durations, [.seconds(60)])
            }
        }
    }
}

/// Records the pauses the engine took, so the backoff state machine can be
/// asserted without waiting for it.
final class SleepRecorder: @unchecked Sendable {
    private(set) var durations: [Duration] = []

    func record(_ duration: Duration) {
        durations.append(duration)
    }
}

/// Counts provider-factory invocations; only touched from the engine actor.
final class CallCounter: @unchecked Sendable {
    private(set) var value = 0

    func bump() {
        value += 1
    }
}
