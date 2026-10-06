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
    /// Applied to the process environment before any collaborator reads env
    /// (LLM_PROVIDER_* keys, LAGOON_BUDGET_USD_PER_MONTH,
    /// LAGOON_PROVIDER_CONFIG). The embedded app routes its Keychain values
    /// through here; the CLI leaves it empty.
    public var environment: [String: String]

    public init(
        dbPath: String,
        host: String = "127.0.0.1",
        port: Int = 8080,
        apiToken: String? = nil,
        tokenKeyBase64: String,
        environment: [String: String] = [:]
    ) {
        self.dbPath = dbPath
        self.host = host
        self.port = port
        self.apiToken = apiToken
        self.tokenKeyBase64 = tokenKeyBase64
        self.environment = environment
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
        let keyData = Data(base64Encoded: configuration.tokenKeyBase64)
        guard let keyData, keyData.count == 32 else {
            throw LagoonRuntimeError.badTokenKey
        }
        AccessTokenCipher.keyProvider = { SymmetricKey(data: keyData) }

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
        let ai: AIGateway? = AIGateway.fromEnvironment(budget: usageBudget, logger: logger)
        if ai == nil {
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
        TimeSavedRoutes.register(on: router, db: db, logger: logger)
        AdviceRoutes.register(on: router, db: db, logger: logger)
        // Sidebar tallies. Read-only; registered next to the other read routes
        // so the whole navigation layer is one glance at this file.
        FolderCountsRoutes.register(on: router, db: db, logger: logger)
        // 发件人排行. Read-only, same as the counts above it.
        SenderRoutes.register(on: router, db: db, logger: logger)
        StackRoutes.register(on: router, db: db, logger: logger)
        // R1 已发送. Registered next to the stacks because both need a provider
        // builder and both are folder-shaped listings rather than inbox reads.
        SentRoutes.register(on: router, db: db, logger: logger)
        BudgetRoutes.register(
            on: router,
            budget: usageBudget,
            costTrackingAvailable: ai?.hasConfiguredRates ?? false,
            gateway: ai
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
