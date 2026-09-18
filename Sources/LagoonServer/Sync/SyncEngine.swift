import Foundation
import Logging
import PostgresNIO
import LagoonKit

/// The single sync loop for the active account.
///
/// One `tickOnce()` is: pick the active account → `pullChanges` (blocks up to
/// `waitBudget` waiting for something to happen) → persist → write health.
/// `start()` drives it; failures follow spec §3.4 — auth failures stop the
/// retry loop and surface `needsReconnect`, everything else backs off
/// 1→2→…→300s with ±20% jitter.
public actor SyncEngine {
    /// How long one `pullChanges` may block waiting for a change. The loop is
    /// therefore never quieter than one tick per 5 minutes even when idle.
    public static let waitBudget: Duration = .seconds(300)

    private let db: PostgresConnection
    private let logger: Logger
    private let providers: @Sendable (Account) -> (any MailProvider)?
    /// Injected so tests can exercise the backoff state machine without
    /// wall-clock sleeps.
    private let sleep: @Sendable (Duration) async -> Void

    private var loop: Task<Void, Never>?
    private var consecutiveFailures = 0
    private var currentAccountId: UUID?
    /// Accounts whose negotiated capabilities have been persisted this process.
    private var capabilitiesChecked: Set<UUID> = []
    /// Provider instances are long-lived: an IMAP provider holds an IDLE
    /// connection and a Gmail provider remembers the last poll it diffed
    /// against, so rebuilding one per tick would lose both.
    private var providersByAccount: [UUID: any MailProvider] = [:]

    public init(
        db: PostgresConnection,
        logger: Logger,
        providers: @escaping @Sendable (Account) -> (any MailProvider)?,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.db = db
        self.logger = logger
        self.providers = providers
        self.sleep = sleep
    }

    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let engine = self else { return }
                await engine.tickOnce()
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// The active account changed (activate / connect / delete). A tick can be
    /// blocked inside a long IDLE or poll for the old account, so it is
    /// cancelled and the loop restarted against the new active row.
    public func accountChanged() {
        currentAccountId = nil
        capabilitiesChecked.removeAll()
        loop?.cancel()
        loop = nil
        start()
    }

    /// Wake the loop now without discarding the active provider connection.
    public func requestImmediateSync() {
        currentAccountId = nil
        loop?.cancel()
        loop = nil
        start()
    }

    /// One round: pull, persist, record health. Never throws — failures become
    /// state (`needsReconnect` / `error` / `degraded`) plus a backoff pause.
    ///
    /// - Parameter waitBudget: how long the pull may block waiting for a change.
    ///   Connect flows pass a tiny budget so a fresh account syncs immediately
    ///   instead of inheriting the loop's idle wait.
    public func tickOnce(waitBudget: Duration = SyncEngine.waitBudget) async {
        do {
            guard let account = try await AccountStore.active(db: db) else {
                await sleep(.seconds(5))
                return
            }
            currentAccountId = account.id
            guard let provider = provider(for: account) else {
                try await AccountStore.updateHealth(
                    accountId: account.id,
                    health: SyncHealth(status: .error, lastSyncAt: nil, lastError: "no-provider"),
                    db: db
                )
                await sleep(.seconds(60))
                return
            }
            await ensureCapabilities(for: account, provider: provider)
            let changes = try await provider.pullChanges(
                after: account.syncState,
                waitUpTo: waitBudget
            )
            try await apply(changes, to: account)
            // Recovery is as important to observe as failure: without this
            // line the log shows an error and then silence, and "did it come
            // back?" is answerable only by querying the health row.
            if consecutiveFailures > 0 {
                logger.info("sync.recovered", metadata: [
                    "account": .string(account.email),
                    "afterFailures": .string("\(consecutiveFailures)"),
                ])
            }
            consecutiveFailures = 0
        } catch is CancellationError {
            return
        } catch let error as MailError where error == .authFailed {
            await markAuthFailure()
        } catch {
            await markFailure(error)
        }
    }

    /// Negotiated capabilities are account data (spec §2.5): version-skewed
    /// rows carry all-false `.unknown`, and the client gates verbs (archive)
    /// on them. Refreshed once per account per process, before the first pull
    /// so the gate is honest as early as possible.
    private func ensureCapabilities(for account: Account, provider: any MailProvider) async {
        guard !capabilitiesChecked.contains(account.id), account.capabilities == .unknown else {
            return
        }
        capabilitiesChecked.insert(account.id)
        let capabilities = await provider.capabilities()
        try? await AccountStore.updateCapabilities(
            accountId: account.id,
            capabilities: capabilities,
            db: db
        )
    }

    private func provider(for account: Account) -> (any MailProvider)? {
        if let cached = providersByAccount[account.id] { return cached }
        guard let made = providers(account) else { return nil }
        providersByAccount[account.id] = made
        return made
    }

    /// Persist one change set. Order matters: wipe first when the remote
    /// identity space changed, land the rows, and only then advance the cursor
    /// — a partial write leaves the cursor untouched and the next pull is
    /// idempotent (spec §2.4).
    private func apply(_ changes: MailChangeSet, to account: Account) async throws {
        if changes.resetRequired {
            try await MessageStore.deleteAll(accountId: account.id, db: db)
            logger.warning("sync.reset", metadata: ["account": .string(account.email)])
        }
        for header in changes.upserts {
            try await MessageStore.upsert(
                Self.message(from: header, accountId: account.id),
                listUnsubscribe: header.listUnsubscribe,
                db: db
            )
        }
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

    /// Credentials are wrong or revoked: stop retrying, ask the user to
    /// reconnect, and drop the cached provider so a reconnect starts clean.
    /// The pause exists because QQ rate-limits repeated failed logins.
    private func markAuthFailure() async {
        if let id = currentAccountId {
            providersByAccount[id] = nil
            capabilitiesChecked.remove(id)
            try? await AccountStore.updateHealth(
                accountId: id,
                health: SyncHealth(
                    status: .needsReconnect,
                    lastSyncAt: nil,
                    lastError: MailError.authFailed.logLabel
                ),
                db: db
            )
        }
        await sleep(.seconds(60))
    }

    /// Transient/structural failure: exponential backoff 1→2→…→300s with ±20%
    /// jitter, and `last_sync_error` escalates from `error` to `degraded` after
    /// three consecutive rounds (spec §3.4).
    ///
    /// Two things beyond the spec matter here:
    ///
    /// 1. **It logs.** It used to write the health row and nothing else, so a
    ///    mailbox stuck in `error` for hours was invisible in the server log —
    ///    the only signal was `GET /api/accounts`, and the client renders that
    ///    as a banner with no root cause. This is the same lesson as
    ///    `.memory/imap-pull-path-must-log-a-round.md`: state that only exists
    ///    inside your own table cannot be observed.
    ///
    /// 2. **It drops the cached provider.** `withClient` already discards a
    ///    connection that threw, but the provider object itself is cached per
    ///    account and the failure can happen outside any command (a cancelled
    ///    IDLE, a capability probe). Dropping it mirrors `markAuthFailure`
    ///    and guarantees the next tick starts from a fresh connect + LOGIN
    ///    rather than trusting a half-dead session.
    private func markFailure(_ error: Error) async {
        consecutiveFailures += 1
        let label = (error as? MailError)?.logLabel ?? "\(type(of: error))"
        if let id = currentAccountId {
            providersByAccount[id] = nil
            capabilitiesChecked.remove(id)
            try? await AccountStore.updateHealth(
                accountId: id,
                health: SyncHealth(
                    status: consecutiveFailures >= 3 ? .degraded : .error,
                    lastSyncAt: nil,
                    lastError: label
                ),
                db: db
            )
        }
        let base = min(300.0, pow(2.0, Double(consecutiveFailures - 1)))
        let jitter = base * 0.2 * Double.random(in: -1...1)
        let pause = max(1, base + jitter)
        logger.warning("sync.failed", metadata: [
            "accountId": .string(currentAccountId?.uuidString ?? "none"),
            "label": .string(label),
            "consecutive": .string("\(consecutiveFailures)"),
            "retryInSeconds": .string(String(format: "%.1f", pause)),
            "detail": .string("\(error)"),
        ])
        await sleep(.seconds(pause))
    }
}
