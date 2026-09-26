import Foundation
import Logging
import PostgresNIO
import LagoonKit

/// One account's sync loop.
///
/// The loop owns a long-lived provider (one IMAP IDLE connection or Gmail
/// poller) but never treats the account snapshot as mutable state. Each round
/// re-reads the row so credentials, capabilities and the cursor are always the
/// latest values committed by the connect or action flows.
public actor AccountSyncLoop {
    /// How long one `pullChanges` may block waiting for a change, so the loop
    /// is never quieter than one round per 5 minutes even when idle.
    public static let waitBudget: Duration = .seconds(300)

    private let accountId: UUID
    private let fallbackEmail: String
    private let db: PostgresConnection
    private let logger: Logger
    private let makeProvider: @Sendable (Account) -> (any MailProvider)?
    /// Injected so tests can exercise the backoff state machine without
    /// wall-clock sleeps.
    private let sleep: @Sendable (Duration) async -> Void

    private var consecutiveFailures = 0
    /// The provider is long-lived: an IMAP provider holds an IDLE connection,
    /// so rebuilding one per round would lose it.
    private var provider: (any MailProvider)?
    /// Negotiated once per provider; refreshed whenever the provider is rebuilt.
    private var capabilitiesChecked = false
    private var lastNegotiated: MailCapabilities?

    public init(
        account: Account,
        db: PostgresConnection,
        logger: Logger,
        makeProvider: @escaping @Sendable (Account) -> (any MailProvider)?,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.accountId = account.id
        self.fallbackEmail = account.email
        self.db = db
        self.logger = logger
        self.makeProvider = makeProvider
        self.sleep = sleep
    }

    /// Runs rounds until the loop parks (the account needs the user) or the
    /// Task is cancelled. `SyncEngine` is the only component that starts it.
    public func run() async {
        while !Task.isCancelled {
            // `round` returns true when it parked the loop; the supervisor
            // starts it again after a reconnect or account switch.
            if await round() { return }
        }
    }

    /// One round. Never throws — failures become state (`needsReconnect` /
    /// `error` / `degraded`) plus a backoff pause. Returns true when the loop
    /// parked and must not run again until explicitly woken.
    ///
    /// - Parameter waitBudget: how long the pull may block waiting for a change.
    @discardableResult
    public func round(waitBudget: Duration = AccountSyncLoop.waitBudget) async -> Bool {
        // Re-read the account row every round. The loop owns identity (id and
        // fallback address) but not mutable state: the cursor persisted by the
        // previous round is what the next round resumes from, and reconnect can
        // replace credentials or capabilities while the loop is alive.
        let current: Account
        do {
            guard let row = try await AccountStore.find(byId: accountId, db: db) else {
                return true
            }
            current = row
        } catch {
            await markFailure(error, email: fallbackEmail)
            return false
        }

        do {
            guard let provider = resolveProvider(for: current) else {
                try await AccountStore.updateHealth(
                    accountId: accountId,
                    health: SyncHealth(status: .error, lastSyncAt: nil, lastError: "no-provider"),
                    db: db
                )
                await sleep(.seconds(60))
                return false
            }
            // The negotiated capabilities must reach `apply` explicitly. The
            // row above predates negotiation, so first-round auto-archive would
            // otherwise see `.unknown` and skip.
            let capabilities = await ensureCapabilities(for: provider, account: current)
            let changes = try await provider.pullChanges(
                after: current.syncState,
                waitUpTo: waitBudget
            )
            // A switch cancels this task while the provider may already have a
            // completed result. Do not let stale mail land after ownership moved.
            try Task.checkCancellation()
            try await apply(changes, to: current, capabilities: capabilities)
            if consecutiveFailures > 0 {
                logger.info("sync.recovered", metadata: [
                    "account": .string(current.email),
                    "afterFailures": .string("\(consecutiveFailures)"),
                ])
            }
            consecutiveFailures = 0
            return false
        } catch is CancellationError {
            return false
        } catch let error as MailError where error == .authFailed {
            await markNeedsReconnect(label: error.logLabel, email: current.email)
            return true
        } catch MailError.notConfigured {
            // No usable credentials. Retrying cannot fix that, so park with the
            // same reconnect action used for a rejected token.
            await markNeedsReconnect(
                label: MailError.notConfigured("").logLabel,
                email: current.email
            )
            return true
        } catch {
            await markFailure(error, email: current.email)
            return false
        }
    }

    // MARK: - Capabilities

    /// Negotiated capabilities are account data. Refresh once per provider,
    /// then keep the negotiated value until that provider is discarded.
    private func ensureCapabilities(
        for provider: any MailProvider,
        account: Account
    ) async -> MailCapabilities {
        guard !capabilitiesChecked else {
            return lastNegotiated ?? account.capabilities
        }
        capabilitiesChecked = true
        let capabilities = await provider.capabilities()
        lastNegotiated = capabilities
        try? await AccountStore.updateCapabilities(
            accountId: account.id,
            capabilities: capabilities,
            db: db
        )
        return capabilities
    }

    /// Long-lived instance, or nil when this build has no implementation for
    /// the account's provider (the round records `no-provider`).
    private func resolveProvider(for account: Account) -> (any MailProvider)? {
        if let provider { return provider }
        guard let made = makeProvider(account) else { return nil }
        provider = made
        capabilitiesChecked = false
        return made
    }

    // MARK: - Persistence

    /// Persist one change set. Order matters: wipe first when the remote
    /// identity space changed, land the rows, and only then advance the cursor
    /// — a partial write leaves the cursor untouched and the next pull is
    /// idempotent.
    private func apply(
        _ changes: MailChangeSet,
        to account: Account,
        capabilities: MailCapabilities
    ) async throws {
        if changes.resetRequired {
            try await MessageStore.deleteAll(accountId: account.id, db: db)
            logger.warning("sync.reset", metadata: ["account": .string(account.email)])
        }
        for header in changes.upserts {
            try await MessageStore.upsert(
                Self.message(from: header, accountId: account.id),
                listUnsubscribe: header.listUnsubscribe,
                unsubscribeLinks: header.unsubscribeLinks,
                db: db
            )
        }
        if let inboxRemoteIds = changes.inboxRemoteIds {
            try await MessageStore.reconcileInbox(
                accountId: account.id,
                keeping: inboxRemoteIds,
                db: db
            )
        }
        try await autoArchiveMatched(
            upserts: changes.upserts,
            account: account,
            capabilities: capabilities
        )
        try await recordSentReplies(changes.repliedMessageIds, accountId: account.id)
        try await AccountStore.updateSyncState(
            accountId: account.id,
            syncState: changes.cursor,
            db: db
        )
        try await AccountStore.updateHealth(
            accountId: account.id,
            health: SyncHealth(status: .ok, lastSyncAt: Date(), lastError: nil),
            db: db
        )
        if !changes.upserts.isEmpty {
            logger.info("sync.applied", metadata: [
                "account": .string(account.email),
                "count": .string("\(changes.upserts.count)"),
            ])
        }
    }

    /// Whitelist autopilot. Mail from a configured sender is archived remotely
    /// after local persistence but before the cursor advances, preserving the
    /// existing idempotent remote-first ordering.
    private func autoArchiveMatched(
        upserts: [RemoteHeader],
        account: Account,
        capabilities: MailCapabilities
    ) async throws {
        guard capabilities.archiveFolder else { return }
        guard !upserts.isEmpty else { return }
        let rules = try await AutoArchiveStore.senderAddresses(accountId: account.id, db: db)
        guard !rules.isEmpty else { return }
        guard let provider else { return }

        for header in upserts where rules.contains(header.fromAddress.lowercased()) {
            do {
                try await provider.archive(remoteId: header.remoteId)
            } catch MailError.messageGone {
                continue
            }
            try await MessageStore.setArchived(
                true,
                remoteId: header.remoteId,
                accountId: account.id,
                db: db
            )
            _ = try await AIActionStore.record(
                accountId: account.id,
                kind: .archive,
                payload: [
                    "remoteId": header.remoteId,
                    "autoRule": "true",
                    "sender": header.fromAddress.lowercased(),
                ],
                db: db
            )
            logger.info("autoarchive.applied", metadata: [
                "account": .string(account.email),
                "from": .string(header.fromAddress),
                "remoteId": .string(header.remoteId),
            ])
        }
    }

    /// Cross-client reply signals (V2 A2). Sent-folder Message-IDs are
    /// recorded as `send` actions with a `sentFolder` marker so they flow
    /// through the existing replied pipeline (`repliedRemoteIds` matches on
    /// the key, `timeSavedEvents` excludes the marker). Already-known IDs are
    /// skipped, which also makes Sent UIDVALIDITY resets idempotent.
    private func recordSentReplies(_ ids: Set<String>, accountId: UUID) async throws {
        guard !ids.isEmpty else { return }
        let known = try await AIActionStore.repliedRemoteIds(accountId: accountId, db: db)
        for id in ids.subtracting(known) {
            _ = try await AIActionStore.record(
                accountId: accountId,
                kind: .send,
                payload: ["remoteId": id, "sentFolder": "true"],
                db: db
            )
        }
    }

    static func message(from header: RemoteHeader, accountId: UUID) -> MessageHeader {
        MessageHeader(
            id: UUID(),
            accountId: accountId,
            remoteId: header.remoteId,
            threadId: header.threadId,
            fromAddress: header.fromAddress,
            fromName: header.fromName,
            subject: header.subject,
            snippet: header.snippet,
            receivedAt: header.receivedAt,
            isRead: header.isRead,
            isArchived: false,
            messageIdHeader: header.messageIdHeader,
            inReplyTo: header.inReplyTo,
            references: header.references
        )
    }

    // MARK: - Failure handling

    /// Credentials are wrong, revoked, or absent: record `needsReconnect`, drop
    /// the cached provider, and park until the user reconnects.
    private func markNeedsReconnect(label: String, email: String) async {
        provider = nil
        capabilitiesChecked = false
        lastNegotiated = nil
        consecutiveFailures = 0
        logger.warning("sync.needsReconnect", metadata: [
            "account": .string(email),
            "label": .string(label),
        ])
        try? await AccountStore.updateHealth(
            accountId: accountId,
            health: SyncHealth(status: .needsReconnect, lastSyncAt: nil, lastError: label),
            db: db
        )
    }

    /// Transient/structural failure: exponential backoff 1→2→…→300 s with
    /// ±20% jitter, escalating to `degraded` after three consecutive rounds.
    private func markFailure(_ error: Error, email: String) async {
        consecutiveFailures += 1
        let label = (error as? MailError)?.logLabel ?? "\(type(of: error))"
        provider = nil
        capabilitiesChecked = false
        lastNegotiated = nil
        try? await AccountStore.updateHealth(
            accountId: accountId,
            health: SyncHealth(
                status: consecutiveFailures >= 3 ? .degraded : .error,
                lastSyncAt: nil,
                lastError: label
            ),
            db: db
        )
        let base = min(300.0, pow(2.0, Double(consecutiveFailures - 1)))
        let jitter = base * 0.2 * Double.random(in: -1...1)
        let pause = max(1, base + jitter)
        logger.warning("sync.failed", metadata: [
            "account": .string(email),
            "label": .string(label),
            "consecutive": .string("\(consecutiveFailures)"),
            "retryInSeconds": .string(String(format: "%.1f", pause)),
            "detail": .string("\(error)"),
        ])
        await sleep(.seconds(pause))
    }
}

/// Supervises one sync loop per connected account, all running concurrently.
///
/// `is_active` is only the client's selected-filter marker (which mailbox the
/// UI shows). Every stored account owns a loop with its own provider
/// connection, cursor and backoff, so one mailbox's auth trouble never stops
/// another's mail. Selecting a different account does not stop any loop.
public actor SyncEngine {
    private let db: PostgresConnection
    private let logger: Logger
    private let makeProvider: @Sendable (Account, PostgresConnection) -> (any MailProvider)?
    private let sleep: @Sendable (Duration) async -> Void
    /// Per-loop connection factory. A Postgres connection serves one query
    /// at a time, so loops must not share `db` — each loop gets its own
    /// connection here (production) or shares `db` when nil (single-loop
    /// unit tests, where no concurrency exists).
    ///
    /// The same connection is handed to the provider builder together with the
    /// account: a provider that falls back to the DB for credentials
    /// (IMAPProvider's `CredentialVault.read`) must query on the loop's own
    /// connection, never the shared one, or the per-loop invariant silently
    /// reintroduces the shared-connection desync.
    ///
    /// Full PostgresClient pool when accounts × traffic grows; per-loop
    /// connections are the correct shape until then (N accounts = N conns).
    private let makeDB: (@Sendable () async throws -> PostgresConnection)?

    private var loops: [UUID: AccountSyncLoop] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var ownedDBs: [UUID: PostgresConnection] = [:]
    /// Serializes restarts of one account. Actor isolation does NOT do this:
    /// every `await` is a reentrancy point, so two concurrent callers used to
    /// interleave their cancel/teardown/start and the second one closed the
    /// connection the first had just handed to a live loop. Each new restart
    /// waits for the previous one to finish first.
    private struct RestartTail: Sendable {
        let generation: UInt64
        let work: Task<Void, Never>
    }
    private var restartTails: [UUID: RestartTail] = [:]
    private var generation: UInt64 = 0

    public init(
        db: PostgresConnection,
        logger: Logger,
        makeProvider: @escaping @Sendable (Account, PostgresConnection) -> (any MailProvider)?,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        makeDB: (@Sendable () async throws -> PostgresConnection)? = nil
    ) {
        self.db = db
        self.logger = logger
        self.makeProvider = makeProvider
        self.sleep = sleep
        self.makeDB = makeDB
    }

    public func start() async {
        await refresh()
    }

    public func stop() async {
        await teardown()
    }

    /// Cancel all loops and close every connection this engine created.
    /// The shared `db` is never closed here — its owner closes it.
    private func teardown() async {
        let running = Array(tasks.values)
        for task in running { task.cancel() }
        for task in running { await task.value }
        tasks = [:]
        loops = [:]
        for conn in ownedDBs.values { try? await conn.close() }
        ownedDBs = [:]
        // Drop queued restarts: a restart that has not started yet must not
        // install a loop after this teardown finished.
        restartTails = [:]
    }

    /// Cancel one account's task and close the connection that task owns.
    /// Idempotent: safe on an id with nothing installed.
    private func stopLoop(for id: UUID) async {
        tasks[id]?.cancel()
        if let task = tasks[id] { await task.value }
        tasks[id] = nil
        loops[id] = nil
        if let conn = ownedDBs.removeValue(forKey: id) { try? await conn.close() }
    }

    /// Reconcile the running loops with the stored accounts: start a loop for
    /// every account, drop loops whose account was deleted. Running loops are
    /// restarted so a loop that parked after an auth failure recovers once the
    /// user reconnects. Prefer `refreshAccount(_:)` when only one account
    /// changed (activate/push) — this full restart is for connect/delete and
    /// manual sync.
    public func refresh() async {
        let accounts: [Account]
        do {
            accounts = try await AccountStore.all(db: db)
        } catch {
            logger.error("sync.activeAccountFailed", metadata: ["err": .string("\(error)")])
            await sleep(.seconds(5))
            return
        }
        await teardown()
        for account in accounts {
            await startLoop(for: account)
        }
    }

    /// Wake every account immediately. Currently a refresh (full restart, see
    /// above); split into per-account wakes only if this ever gets hot.
    public func requestImmediateSync() async {
        await refresh()
    }

    /// Restart one account's loop (scoped wake). Used by the Gmail push
    /// webhook and the activate route: neither should disturb the other
    /// accounts' connections. A parked loop restarts here too, so reconnect
    /// recovery works per account.
    public func refreshAccount(_ id: UUID) async {
        generation &+= 1
        let mine = generation
        let previous = restartTails[id]?.work
        let work = Task { [self] in
            // Chain behind any restart still in flight for this account.
            await previous?.value
            await restartAccountNow(id, generation: mine)
        }
        restartTails[id] = RestartTail(generation: mine, work: work)
        await work.value
        // Only the newest generation clears the slot; older callers must not
        // drop the tail a newer restart is using.
        if restartTails[id]?.generation == mine { restartTails[id] = nil }
    }

    /// The restart body, run serialized per account (see `refreshAccount`).
    private func restartAccountNow(_ id: UUID, generation: UInt64) async {
        // A `stop()` (or a `refresh()`) that ran while this restart was queued
        // already decided what the engine should be running; do not resurrect.
        guard restartTails[id]?.generation == generation else { return }
        // A deleted account keeps an IMAP session and a Postgres connection
        // alive until its loop self-parks on the next round: tear it down now.
        guard let account = try? await AccountStore.find(byId: id, db: db) else {
            await stopLoop(for: id)
            return
        }
        await stopLoop(for: id)
        await startLoop(for: account)
    }

    /// Test/diagnostic hook.
    func loop(forAccount id: UUID) -> AccountSyncLoop? {
        loops[id]
    }

    /// Build and start one loop, owning a fresh connection when `makeDB`
    /// is configured. A per-account factory failure skips only that account.
    ///
    /// Idempotent: any existing entry for this account is cancelled and its
    /// connection closed *before* the new one is installed. Two restarts that
    /// interleave (a push racing `refresh()`, or two pushes for one mailbox)
    /// therefore end with exactly one live loop and one owned connection
    /// instead of an untracked zombie loop plus a leaked connection.
    private func startLoop(for account: Account) async {
        await stopLoop(for: account.id)
        let loopDB: PostgresConnection
        if let makeDB {
            do {
                loopDB = try await makeDB()
            } catch {
                // One mailbox's DB trouble must not stop another's mail.
                logger.error("sync.loopDBFailed", metadata: [
                    "account": .string(account.email),
                    "err": .string("\(error)"),
                ])
                return
            }
            ownedDBs[account.id] = loopDB
        } else {
            loopDB = db
        }
        let nextLoop = AccountSyncLoop(
            account: account,
            db: loopDB,
            logger: logger,
            // The provider gets the loop's own connection, never the shared
            // one (see `makeProvider`).
            makeProvider: { self.makeProvider($0, loopDB) },
            sleep: sleep
        )
        loops[account.id] = nextLoop
        tasks[account.id] = Task {
            await nextLoop.run()
        }
    }
}
