import XCTest
import Foundation
import Logging
import PostgresNIO
@testable import LagoonServer
@testable import LagoonKit

/// Drives the sync machinery with scripted providers against the guarded test
/// DB: the whole round — pull → persist → cursor → health → backoff — with no
/// network and no wall-clock sleeping.
///
/// Round-level tests drive one `AccountSyncLoop` directly. The supervisor
/// (`SyncEngine`) gets its own tests, because "one mailbox's trouble must not
/// stop another's mail" is a property of the supervision, not of a round.
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
    }

    private func cleanup(_ oauthUser: String) -> @Sendable (PostgresConnection) async -> Void {
        { conn in
            try? await TestDatabase.deleteAccount(oauthUser: oauthUser, provider: .qq, db: conn)
        }
    }

    private func makeLoop(
        db: PostgresConnection,
        account: Account,
        provider: (any MailProvider)?,
        sleeper: SleepRecorder = SleepRecorder(),
        counter: CallCounter? = nil
    ) -> AccountSyncLoop {
        AccountSyncLoop(
            account: account,
            db: db,
            logger: Logger(label: "sync-loop-tests"),
            makeProvider: { (_: Account) -> (any MailProvider)? in
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

    // MARK: - One round

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
                let loop = makeLoop(db: conn, account: account, provider: provider, sleeper: sleeper)

                let parked = await loop.round()

                XCTAssertFalse(parked, "a healthy round keeps looping")
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

    /// (a2) A round must resume from the cursor the *previous* round persisted,
    /// not from whatever the row held when the loop was built.
    ///
    /// The loop is a long-lived object holding a snapshot of its account; using
    /// that snapshot for `pullChanges(after:)` makes the cursor stand still and
    /// every round re-deliver the same mail (observed against a real mailbox:
    /// the same 168 messages re-applied every 20 s).
    func test_secondRound_resumesFromThePersistedCursor() async throws {
        let oauthUser = "sync-\(UUID().uuidString)"

        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            try await TestDatabase.withConnection(cleanup: cleanup(oauthUser)) { conn in
                // What the row holds when the loop starts.
                let account = Account(
                    id: UUID(),
                    provider: .qq,
                    oauthUser: oauthUser,
                    email: "\(oauthUser)@qq.com",
                    credentials: nil,
                    syncState: MailSyncState(uidValidity: 42, lastUid: 900)
                )
                try await seed(account, db: conn)

                let advanced = MailSyncState(uidValidity: 42, lastUid: 901)
                let provider = StubMailProvider(pulls: [
                    .success(MailChangeSet(
                        upserts: [.stub(remoteId: "901")],
                        resetRequired: false,
                        cursor: advanced
                    )),
                    .success(MailChangeSet(
                        upserts: [],
                        resetRequired: false,
                        cursor: advanced
                    )),
                ])
                let loop = makeLoop(db: conn, account: account, provider: provider)

                await loop.round()
                await loop.round()

                let passed = await provider.lastCursor
                XCTAssertEqual(
                    passed, advanced,
                    "round 2 must resume from the cursor round 1 committed, not the loop's initial snapshot"
                )
            }
        }
    }

    /// (a3) Sent-folder reply signals (V2 A2) are recorded as `send` actions
    /// with a `sentFolder` marker, flow into `repliedRemoteIds`, and are not
    /// duplicated when the same IDs arrive again (Sent UIDVALIDITY reset).
    func test_sentReplies_recordedOnceAsReplySignals() async throws {
        let oauthUser = "sync-\(UUID().uuidString)"

        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            try await TestDatabase.withConnection(cleanup: cleanup(oauthUser)) { conn in
                let account = makeAccount(oauthUser: oauthUser)
                try await seed(account, db: conn)

                let cursor = MailSyncState(uidValidity: 42, lastUid: 900)
                let provider = StubMailProvider(pulls: [
                    .success(MailChangeSet(
                        upserts: [.stub(remoteId: "901")],
                        resetRequired: false,
                        cursor: cursor,
                        repliedMessageIds: ["<orig@example.com>"]
                    )),
                    .success(MailChangeSet(
                        upserts: [],
                        resetRequired: false,
                        cursor: cursor,
                        repliedMessageIds: ["<orig@example.com>"]
                    )),
                ])
                let loop = makeLoop(db: conn, account: account, provider: provider)

                await loop.round()
                await loop.round()

                let replied = try await AIActionStore.repliedRemoteIds(
                    accountId: account.id, db: conn
                )
                XCTAssertTrue(replied.contains("<orig@example.com>"))
                let sends = try await AIActionStore.recent(accountId: account.id, db: conn)
                    .filter { $0.kind == .send }
                XCTAssertEqual(sends.count, 1, "repeat Sent IDs must not duplicate the signal")
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
                let loop = makeLoop(db: conn, account: account, provider: provider)

                await loop.round()

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

    /// (b2) A complete inbox snapshot removes rows another client moved or
    /// deleted remotely. Without this, the UI keeps opening a stale message and
    /// the body route correctly answers 410 `message-gone`.
    func test_inboxSnapshot_removesMessagesNoLongerInInbox() async throws {
        let oauthUser = "sync-\(UUID().uuidString)"

        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            try await TestDatabase.withConnection(cleanup: cleanup(oauthUser)) { conn in
                let account = makeAccount(oauthUser: oauthUser)
                try await seed(account, db: conn)
                try await MessageStore.upsert(
                    MessageHeader(
                        id: UUID(),
                        accountId: account.id,
                        remoteId: "<stale@example.com>",
                        threadId: "stale",
                        fromAddress: "old@example.com",
                        fromName: nil,
                        subject: "Moved in another client",
                        snippet: nil,
                        receivedAt: Date(),
                        isRead: false,
                        isArchived: false
                    ),
                    db: conn
                )

                let cursor = MailSyncState(uidValidity: 42, lastUid: 901)
                let provider = StubMailProvider.once(MailChangeSet(
                    upserts: [.stub(remoteId: "<fresh@example.com>")],
                    resetRequired: false,
                    cursor: cursor,
                    inboxRemoteIds: ["<fresh@example.com>"]
                ))
                let loop = makeLoop(db: conn, account: account, provider: provider)

                await loop.round()

                let stored = try await MessageStore.recent(
                    forAccount: account.id,
                    limit: 50,
                    db: conn
                )
                XCTAssertEqual(stored.map(\.remoteId), ["<fresh@example.com>"])
            }
        }
    }

    /// (c) `authFailed` → `needsReconnect` and the loop parks: a rejected
    /// credential must not be retried at all (QQ rate-limits failed logins).
    func test_authFailure_marksNeedsReconnect_andParks() async throws {
        let oauthUser = "sync-\(UUID().uuidString)"

        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            try await TestDatabase.withConnection(cleanup: cleanup(oauthUser)) { conn in
                let account = makeAccount(oauthUser: oauthUser)
                try await seed(account, db: conn)

                let provider = StubMailProvider.failing(.authFailed)
                let sleeper = SleepRecorder()
                let loop = makeLoop(db: conn, account: account, provider: provider, sleeper: sleeper)

                let parked = await loop.round()

                XCTAssertTrue(parked, "an auth failure must stop the loop, not throttle it")
                let updated = try await health(account.id, db: conn)
                XCTAssertEqual(updated?.status, .needsReconnect)
                XCTAssertEqual(
                    updated?.lastError, "auth-failed",
                    "only the stable label is stored, never credential material"
                )
                XCTAssertEqual(
                    sleeper.durations, [],
                    "a parked loop must not schedule a retry"
                )
                let pullCount = await provider.pullCount
                XCTAssertEqual(pullCount, 1)
            }
        }
    }

    /// (c2) missing credentials are not a transient failure: retrying cannot
    /// fix them, so the loop parks with the same call to action as a rejected
    /// token (the client already renders a Reconnect button for it).
    func test_notConfigured_parksAsNeedsReconnect() async throws {
        let oauthUser = "sync-\(UUID().uuidString)"

        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            try await TestDatabase.withConnection(cleanup: cleanup(oauthUser)) { conn in
                let account = makeAccount(oauthUser: oauthUser)
                try await seed(account, db: conn)

                let provider = StubMailProvider.failing(.notConfigured("gmail credentials missing"))
                let sleeper = SleepRecorder()
                let loop = makeLoop(db: conn, account: account, provider: provider, sleeper: sleeper)

                let parked = await loop.round()

                XCTAssertTrue(parked)
                let updated = try await health(account.id, db: conn)
                XCTAssertEqual(updated?.status, .needsReconnect)
                XCTAssertEqual(sleeper.durations, [])
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
                let loop = makeLoop(db: conn, account: account, provider: provider, sleeper: sleeper)

                await loop.round()
                let first = try await health(account.id, db: conn)
                XCTAssertEqual(first?.status, .error)
                XCTAssertEqual(first?.lastError, "unreachable")

                await loop.round()
                let second = try await health(account.id, db: conn)
                XCTAssertEqual(second?.status, .error)

                await loop.round()
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
                let loop = makeLoop(db: conn, account: account, provider: provider, sleeper: sleeper)

                await loop.round()
                let failed = try await health(account.id, db: conn)
                XCTAssertEqual(failed?.status, .error)

                await loop.round()
                let recovered = try await health(account.id, db: conn)
                XCTAssertEqual(recovered?.status, .ok)

                await loop.round()
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

    /// (f) the factory runs once per loop: a provider carries connection state
    /// (an IDLE socket) that must survive rounds.
    func test_providerFactory_runsOnce() async throws {
        let oauthUser = "sync-\(UUID().uuidString)"

        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            try await TestDatabase.withConnection(cleanup: cleanup(oauthUser)) { conn in
                let account = makeAccount(oauthUser: oauthUser)
                try await seed(account, db: conn)

                let counter = CallCounter()
                let loop = makeLoop(
                    db: conn,
                    account: account,
                    provider: StubMailProvider(),
                    counter: counter
                )

                await loop.round()
                await loop.round()

                XCTAssertEqual(counter.value, 1)
            }
        }
    }

    /// (g) an account whose provider is unavailable is visibly unhealthy
    /// instead of silently unsynced.
    func test_missingProvider_recordsNoProviderHealth() async throws {
        let oauthUser = "sync-\(UUID().uuidString)"

        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            try await TestDatabase.withConnection(cleanup: cleanup(oauthUser)) { conn in
                let account = makeAccount(oauthUser: oauthUser)
                try await seed(account, db: conn)

                let sleeper = SleepRecorder()
                let loop = makeLoop(db: conn, account: account, provider: nil, sleeper: sleeper)

                await loop.round()

                let updated = try await health(account.id, db: conn)
                XCTAssertEqual(updated?.status, .error)
                XCTAssertEqual(updated?.lastError, "no-provider")
                XCTAssertEqual(sleeper.durations, [.seconds(60)])
            }
        }
    }

    // MARK: - Supervision

    /// (h) All stored accounts sync concurrently. The `is_active` marker is
    /// only the client's selected filter: switching it restarts loops but
    /// never parks any mailbox, and one mailbox's trouble never stops
    /// another's mail.
    func test_switch_stopsOldAccount_andStartsSelectedAccount() async throws {
        let oauthA = "sync-a-\(UUID().uuidString)"
        let oauthB = "sync-b-\(UUID().uuidString)"

        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            try await TestDatabase.withConnection(cleanup: { conn in
                try? await TestDatabase.deleteAccount(oauthUser: oauthA, provider: .qq, db: conn)
                try? await TestDatabase.deleteAccount(oauthUser: oauthB, provider: .qq, db: conn)
            }) { conn in
                let broken = makeAccount(oauthUser: oauthA)
                let healthy = makeAccount(oauthUser: oauthB)
                try await seed(broken, db: conn)
                try await seed(healthy, db: conn)

                let providerA = StubMailProvider(pulls: [
                    .success(MailChangeSet(
                        upserts: [.stub(remoteId: "a-1")],
                        resetRequired: false,
                        cursor: MailSyncState(uidValidity: 8, lastUid: 1)
                    )),
                    .success(MailChangeSet(
                        upserts: [],
                        resetRequired: false,
                        cursor: MailSyncState(uidValidity: 8, lastUid: 1)
                    )),
                ])
                let providerB = StubMailProvider(pulls: [
                    .success(MailChangeSet(
                        upserts: [.stub(remoteId: "b-1")],
                        resetRequired: false,
                        cursor: MailSyncState(uidValidity: 9, lastUid: 1)
                    )),
                    .success(MailChangeSet(
                        upserts: [],
                        resetRequired: false,
                        cursor: MailSyncState(uidValidity: 9, lastUid: 1)
                    )),
                ])
                // Per-account providers: the multi-active engine syncs every
                // stored row (including transient rows from parallel tests),
                // so sharing one scripted provider across loops lets a stray
                // loop consume the script. Keyed lookup keeps A/B deterministic.
                let providers = [broken.id: providerA, healthy.id: providerB]
                let engine = SyncEngine(
                    db: conn,
                    logger: Logger(label: "sync-switch-tests"),
                    makeProvider: { account in
                        providers[account.id] ?? StubMailProvider()
                    },
                    sleep: { _ in },
                    makeDB: { try await TestDatabase.requireConnection() }
                )

                try await AccountStore.setActive(accountId: healthy.id, db: conn)
                await engine.start()
                defer { Task { await engine.stop() } }

                // Both accounts own a loop: A and B sync concurrently.
                var bothSynced = false
                for _ in 0..<100 {
                    let aHealth = try await health(broken.id, db: conn)
                    let bHealth = try await health(healthy.id, db: conn)
                    if aHealth?.lastSyncAt != nil, bHealth?.lastSyncAt != nil {
                        bothSynced = true
                        break
                    }
                    try await Task.sleep(for: .milliseconds(50))
                }
                XCTAssertTrue(bothSynced, "both accounts must sync concurrently")
                let bMessages = try await MessageStore.recent(
                    forAccount: healthy.id, limit: 50, db: conn
                )
                XCTAssertEqual(bMessages.map(\.remoteId), ["b-1"])
                let aMessagesBeforeSwitch = try await MessageStore.recent(
                    forAccount: broken.id, limit: 50, db: conn
                )
                XCTAssertEqual(aMessagesBeforeSwitch.map(\.remoteId), ["a-1"])
                // Switching the selection marker restarts loops but parks
                // nothing: both mailboxes keep syncing.
                try await AccountStore.setActive(accountId: broken.id, db: conn)
                await engine.refresh()
                var bothStillSynced = false
                for _ in 0..<100 {
                    let aPulls = await providerA.pullCount
                    let bPulls = await providerB.pullCount
                    if aPulls >= 2, bPulls >= 2 {
                        bothStillSynced = true
                        break
                    }
                    try await Task.sleep(for: .milliseconds(50))
                }
                XCTAssertTrue(
                    bothStillSynced,
                    "switching the selection must not park any account's loop"
                )
                await engine.stop()
            }
        }
    }
}

/// Records the pauses the loop took, so the backoff state machine can be
/// asserted without waiting for it.
final class SleepRecorder: @unchecked Sendable {
    private(set) var durations: [Duration] = []

    func record(_ duration: Duration) {
        durations.append(duration)
    }
}

/// Counts provider-factory invocations; only touched from the loop actor.
final class CallCounter: @unchecked Sendable {
    private(set) var value = 0

    func bump() {
        value += 1
    }
}
