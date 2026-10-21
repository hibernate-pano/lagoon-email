import Foundation
import Logging
import GRDB
import Hummingbird
import ServiceLifecycle
import LagoonKit
import LagoonAI
import Crypto

/// Everything the server needs to run, passed in explicitly. The embedded app
/// fills this from the Keychain and its settings store; the CLI builds it
/// from the process environment (the historical contract).
public struct LagoonRuntimeConfiguration: Sendable {
    public var dbPath: String
    public var host: String
    public var port: Int
    /// Per-install API token. Non-nil enables `Authorization: Bearer` on every
    /// /api/* route and allows non-loopback binds; nil keeps the loopback-only
    /// posture.
    public var apiToken: String?
    /// Base64 of the 32-byte AES-GCM key that seals credentials at rest.
    public var tokenKeyBase64: String
    /// Base64 of the 32-byte AES-GCM key that seals the mail **body** at
    /// rest.
    ///
    /// A separate key from the credential key on purpose: the two protect
    /// different data with different lifetimes, and rotating one must not
    /// quietly orphan the other. It also means the body key can be rotated
    /// (bodies are a cache — they re-fetch) without touching the
    /// credentials.
    public var bodyKey: String
    /// Applied to the process environment before any collaborator reads env
    /// (LLM_PROVIDER_* keys, LAGOON_BUDGET_USD_PER_MONTH,
    /// LAGOON_PROVIDER_CONFIG). The embedded app routes its Keychain values
    /// through here; the CLI leaves it empty.
    public var environment: [String: String]

    /// Whether the keys carried by this configuration are **placeholders**.
    ///
    /// The embedded app may bind the port before its Keychain read has
    /// come back. When it does, it passes a placeholder key so the server
    /// can start; the app then installs the real key into
    /// `AccessTokenCipher.keyProvider` / `BodyCipher.keyProvider` as soon
    /// as the read returns.
    ///
    /// The flag is not cosmetic. A placeholder is a *valid-looking* 32-byte
    /// key as far as the ciphers are concerned, so without this the only
    /// symptom of "the Keychain has not answered yet" would be a stream of
    /// decryption failures that look exactly like a corrupted database. The
    /// routes use it to answer "the key is still resolving" instead.
    public var usesPlaceholderKeys: Bool = false

    public init(
        dbPath: String,
        host: String = "127.0.0.1",
        port: Int = 8080,
        apiToken: String? = nil,
        tokenKeyBase64: String,
        bodyKey: String,
        environment: [String: String] = [:],
        usesPlaceholderKeys: Bool = false
    ) {
        self.dbPath = dbPath
        self.host = host
        self.port = port
        self.apiToken = apiToken
        self.tokenKeyBase64 = tokenKeyBase64
        self.bodyKey = bodyKey
        self.environment = environment
        self.usesPlaceholderKeys = usesPlaceholderKeys
    }
}

/// A live embedded server. `stop()` gracefully shuts the HTTP service and the
/// sync loops down; the SQLite pool outlives it (GRDB manages its own
/// lifetime).
public final class RunningLagoonServer: @unchecked Sendable {
    private let serviceGroup: ServiceGroup
    private let runTask: Task<Void, Never>
    private let syncEngine: SyncEngine
    public let port: Int

    init(serviceGroup: ServiceGroup, runTask: Task<Void, Never>, syncEngine: SyncEngine, port: Int) {
        self.serviceGroup = serviceGroup
        self.runTask = runTask
        self.syncEngine = syncEngine
        self.port = port
    }

    public func stop() async {
        await syncEngine.stop()
        await serviceGroup.triggerGracefulShutdown()
        _ = await runTask.value
    }
}

/// The server as a library: opens the embedded SQLite store, wires the sync
/// engine and routes, and serves HTTP on the configured bind. The same entry
/// point backs the app process and the CLI.
public enum LagoonRuntime {
    @discardableResult
    public static func start(
        _ configuration: LagoonRuntimeConfiguration,
        logger: Logger
    ) async throws -> RunningLagoonServer {
        // Environment passthrough first: the AI gateway, the provider
        // registry and the budget read the process environment.
        for (key, value) in configuration.environment where !value.isEmpty {
            setenv(key, value, 1)
        }

        // Fail closed on a missing/malformed key rather than discovering it
        // on the first OAuth or IMAP connect. The key never needs to exist as
        // an env var in the embedded runtime.
        //
        // The embedded app may start the server before its Keychain read
        // has come back (see `EmbeddedServer.bootstrap`), in which case it
        // passes a placeholder. The provider is a *mutable* static, so the
        // app installs the real key the moment it arrives; the placeholder
        // only covers the window before that.
        let keyData = Data(base64Encoded: configuration.tokenKeyBase64)
        guard let keyData, keyData.count == 32 else {
            throw LagoonRuntimeError.badTokenKey
        }
        AccessTokenCipher.keyProvider = { SymmetricKey(data: keyData) }

        // The body key is set **before** the store is opened: the migration
        // that seals a legacy store runs inside `LagoonDatabase.open`, and it
        // needs the key to do its job. A store opened without one would have
        // its cached bodies dropped (they are a cache — the server can fetch
        // them again), which is the fail-closed answer but a wasteful one.
        let bodyKeyData = Data(base64Encoded: configuration.bodyKey)
        guard let bodyKeyData, bodyKeyData.count == 32 else {
            throw LagoonRuntimeError.badTokenKey
        }
        BodyCipher.keyProvider = { SymmetricKey(data: bodyKeyData) }

        let cfg = ServerConfig(host: configuration.host, port: configuration.port)
        let apiToken = configuration.apiToken.flatMap { $0.isEmpty ? nil : $0 }
        if let refusal = cfg.startupRefusal(apiToken: apiToken) {
            throw LagoonRuntimeError.refused(refusal)
        }

        let pool = try LagoonDatabase.open(path: configuration.dbPath)
        let db = LagoonDB(pool)

        let syncEngine = SyncEngine(
            db: db,
            logger: logger,
            makeProvider: { account, loopDB in
                MailProviderFactory.make(
                    account: account,
                    db: loopDB,
                    logger: logger
                )
            }
        )
        let capUSD = Double(ProcessInfo.processInfo.environment["LAGOON_BUDGET_USD_PER_MONTH"] ?? "") ?? 0
        let usageBudget = try await UsageBudget(db: db, capUSDPerMonth: capUSD, logger: logger)
        // The learning loop's read side: what this account has actually acted
        // on. It is handed to the gateway as a read-only collaborator — the
        // AI module never learns where the numbers come from.
        let advicePreferences = AdvicePreferenceReader(db: db, logger: logger)
        // The gateway lives in a **holder**, not in a `let`.
        //
        // It used to be a plain `let ai: AIGateway?`, and the routes
        // captured it at registration time — which meant a new key could
        // not be picked up without restarting the app. The user pasted a
        // key, pressed 保存, and the app said "restart to take effect".
        //
        // A key is a credential; changing one does not require rebuilding
        // the process. The holder is what makes that true: the routes
        // hold the holder, the holder holds the current gateway, and the
        // gateway can be swapped behind the same reference.
        let ai = AIGatewayHolder(gateway: AIGateway.fromEnvironment(
            budget: usageBudget,
            preferences: advicePreferences,
            logger: logger
        ))
        if ai.current == nil {
            logger.info("AI gateway disabled: set LLM_PROVIDER_PRIMARY_BASE_URL and LLM_PROVIDER_PRIMARY_API_KEY")
        }

        let providerFactory = MailProviderFactory.factory(db: db, logger: logger)
        let makeProvider = providerFactory.builder

        let router = Router()
        router.add(middleware: LoopbackHostMiddleware(
            allowedNames: cfg.allowedHostNames(apiToken: apiToken)
        ))
        router.add(middleware: APIAuthMiddleware(token: apiToken))
        HealthRoutes.register(on: router)
        AccountsRoutes.register(
            on: router, db: db, logger: logger, sync: syncEngine,
            makeProvider: makeProvider, releaseProvider: providerFactory.release
        )
        SyncRoutes.register(on: router, db: db, logger: logger, sync: syncEngine)
        MessageRoutes.register(
            on: router,
            db: db,
            logger: logger,
            summarizer: ai,
            makeProvider: makeProvider
        )
        // The inline (`cid:`) images of one message, in one response. The
        // client used to fetch them one at a time — and the server re-fetched
        // and re-parsed the whole message for each one.
        InlineImageRoutes.register(
            on: router,
            db: db,
            logger: logger,
            makeProvider: makeProvider
        )
        BriefingRoutes.register(
            on: router,
            db: db,
            logger: logger,
            classifier: ai,
            classificationMode: .background
        )
        ActionsRoutes.register(
            on: router, db: db, logger: logger,
            makeProvider: makeProvider
        )
        DraftRoutes.register(
            on: router, db: db, draftGenerator: ai,
            logger: logger, makeProvider: makeProvider
        )
        SearchRoutes.register(on: router, db: db, logger: logger)
        // 存储层通知. The store's one-shot notices for the user — today that
        // is "your drafts were deleted because the store could not be
        // encrypted". Registered next to the other read routes because it
        // reads one table and nothing else.
        StoreNoticeRoutes.register(on: router, db: db, logger: logger)
        TimeSavedRoutes.register(on: router, db: db, logger: logger)
        AdviceRoutes.register(on: router, db: db, logger: logger)
        // 提醒. The notes the user set for themselves, so the AI's "remind"
        // suggestion is backed by something that actually fires. Read and
        // write only the `reminders` table — no mail is touched.
        ReminderRoutes.register(on: router, db: db, logger: logger)
        // Sidebar tallies. Read-only; registered next to the other read routes
        // so the whole navigation layer is one glance at this file.
        FolderCountsRoutes.register(on: router, db: db, logger: logger)
        // 发件人排行. Read-only, same as the counts above it.
        SenderRoutes.register(on: router, db: db, logger: logger)
        StackRoutes.register(on: router, db: db, logger: logger)
        // 数据导出. Registering it here rather than in MessageRoutes keeps the
        // export's index a sibling of the other read-only listings: it reads
        // `message_headers` and nothing else, and the mbox writer on the
        // client walks it message by message through the existing raw.eml
        // route.
        BackupRoutes.register(on: router, db: db, logger: logger)
        // R1 已发送. Registered next to the stacks because both need a provider
        // builder and both are folder-shaped listings rather than inbox reads.
        SentRoutes.register(on: router, db: db, logger: logger)
        BudgetRoutes.register(
            on: router,
            budget: usageBudget,
            costTrackingAvailable: ai.current?.hasConfiguredRates ?? false,
            gateway: ai,
            logger: logger
        )
        // The AI reload. The gateway lives behind a holder, so a new key
        // can be picked up without restarting the app — the old copy
        // demanded a relaunch for a credential change, which was an
        // architecture accident and not a requirement.
        //
        // `baseEnvironment` is the process environment as it stood *after*
        // the launcher's values were applied above. It matters: the
        // providers.json path lives there, and a reload that dropped it
        // would resolve no provider at all and report the AI as
        // unconfigured — a false negative that looks like "your key is
        // wrong".
        AIRoutes.register(
            on: router,
            holder: ai,
            budget: usageBudget,
            preferences: advicePreferences,
            logger: logger,
            baseEnvironment: ProcessInfo.processInfo.environment
        )

        let app = Application(
            router: router,
            configuration: .init(address: .hostname(cfg.host, port: cfg.port)),
            logger: logger
        )

        // Repair a zero-selected state before the loops start. Every stored
        // account gets its own loop over the shared pool; `is_active` only
        // marks the mailbox the client shows first.
        try await AccountStore.reconcileActive(db: db)

        let serviceGroup = ServiceGroup(
            configuration: .init(services: [app], logger: logger)
        )
        let runTask: Task<Void, Never> = Task {
            try? await serviceGroup.run()
        }
        Task { await syncEngine.start() }
        logger.info("starting", metadata: [
            "host": .string(cfg.host),
            "port": .string("\(cfg.port)"),
            "db": .string(configuration.dbPath),
        ])
        return RunningLagoonServer(
            serviceGroup: serviceGroup, runTask: runTask, syncEngine: syncEngine,
            port: cfg.port
        )
    }
}

public enum LagoonRuntimeError: Error, CustomStringConvertible {
    case badTokenKey
    case refused(String)

    public var description: String {
        switch self {
        case .badTokenKey:
            return "token key is missing or malformed: it must be base64 of exactly 32 random bytes"
        case .refused(let reason):
            return reason
        }
    }
}
