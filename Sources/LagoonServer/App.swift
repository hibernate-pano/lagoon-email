import Foundation
import Logging
import PostgresNIO
import Hummingbird
import LagoonKit
import LagoonAI

@main
struct LagoonServerMain {
    static func main() async throws {
        let logger = Logger(label: "lagoon.server")
        let cfg = ServerConfig.load()
        let pgCfg: PostgresConfig
        do {
            pgCfg = try PostgresConfig.load()
        } catch {
            die("refusing to start: \(error)")
        }

        // M0 ships with no API authentication. Binding anything other than
        // loopback would expose /api/messages, /api/accounts and the OAuth
        // callback to the network, so refuse to start.
        guard cfg.isLoopback else {
            die("""
                refusing to start: LAGOON_SERVER_HOST=\(cfg.host) is not a loopback address.
                Lagoon M0 has NO API authentication; binding a non-loopback interface would
                expose the API to the network. M1 adds per-install bearer tokens. Use one of
                127.0.0.1, ::1 or localhost (or unset LAGOON_SERVER_HOST).
                """)
        }

        // Tokens are AES-GCM encrypted with LAGOON_TOKEN_KEY. Fail closed at
        // startup rather than discovering the key is missing on first OAuth.
        do {
            try AccessTokenCipher.validateKey()
        } catch {
            die("""
                refusing to start: LAGOON_TOKEN_KEY is missing or malformed (\(error)).
                It must be base64 of exactly 32 random bytes. Generate one with:
                  export LAGOON_TOKEN_KEY="$(openssl rand -base64 32)"
                """)
        }

        let elg = LagoonPostgres.makeEventLoopGroup()
        let db = try await LagoonPostgres.connect(pgCfg, on: elg.any())

        if CommandLine.arguments.contains("--self-test") {
            do {
                try await LagoonSelfTest.run(db: db, logger: logger)
                try await db.close()
                return
            } catch {
                die("self-test failed: \(error)")
            }
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--restore") {
            let valueIndex = CommandLine.arguments.index(after: flag)
            guard valueIndex < CommandLine.arguments.endIndex else {
                die("--restore requires an IMAP UID")
            }
            do {
                try await LagoonSelfTest.restore(
                    remoteId: CommandLine.arguments[valueIndex],
                    db: db,
                    logger: logger
                )
                try await db.close()
                return
            } catch {
                die("restore failed: \(error)")
            }
        }
        if CommandLine.arguments.contains("--list-mailboxes") {
            do {
                try await LagoonSelfTest.listMailboxes(db: db, logger: logger)
                try await db.close()
                return
            } catch {
                die("mailbox listing failed: \(error)")
            }
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--find-subject") {
            let valueIndex = CommandLine.arguments.index(after: flag)
            guard valueIndex < CommandLine.arguments.endIndex else {
                die("--find-subject requires a subject")
            }
            do {
                try await LagoonSelfTest.find(
                    subject: CommandLine.arguments[valueIndex],
                    db: db,
                    logger: logger
                )
                try await db.close()
                return
            } catch {
                die("message lookup failed: \(error)")
            }
        }

        let google = GoogleOAuthClient(
            clientID: cfg.googleClientID,
            clientSecret: cfg.googleClientSecret,
            redirectURI: cfg.googleRedirectURI
        )
        // One shared token service so the sync engine and the message routes
        // share the single-flight refresh registry.
        let gmailClient = GmailClient()
        let tokens = GmailTokenService(db: db, oauth: google, logger: logger)
        // The sync engine is the only writer of message rows for the active
        // account: it asks the account's `MailProvider` for changes and applies
        // them (spec §3.2/§3.4). Providers are built lazily and cached, so an
        // IMAP connection survives between ticks.
        let syncEngine = SyncEngine(db: db, logger: logger) { account in
            MailProviderFactory.make(
                account: account,
                client: gmailClient,
                tokens: tokens,
                db: db,
                logger: logger
            )
        }
        // Repair a zero-or-many active-account state before the loop starts.
        try await AccountStore.reconcileActive(db: db)

        // Spec §6.5: the AI Gateway is the only module that talks to LLM
        // providers. `nil` when no provider is configured (missing key/base
        // URL) — the server then stays heuristic-only and /summary returns 503.
        // The budget actor enforces the monthly cost cap from
        // LAGOON_BUDGET_USD_PER_MONTH (<= 0 disables); see Sources/LagoonServer/AI/UsageBudget.swift.
        let capUSD = Double(ProcessInfo.processInfo.environment["LAGOON_BUDGET_USD_PER_MONTH"] ?? "") ?? 0
        let usageBudget = try await UsageBudget(db: db, capUSDPerMonth: capUSD, logger: logger)
        let ai: AIGateway? = {
            guard let gateway = AIGateway.fromEnvironment(
                budget: usageBudget,
                logger: logger
            ) else { return nil }
            return gateway
        }()
        if ai == nil {
            logger.info("AI gateway disabled: set LLM_PROVIDER_PRIMARY_BASE_URL and LLM_PROVIDER_PRIMARY_API_KEY")
        }

        // The routes build providers through the same factory the engine uses;
        // each route binds it once so every handler shares the collaborators.
        let makeProvider = MailProviderFactory.factory(
            client: gmailClient, tokens: tokens, db: db, logger: logger
        )

        let router = Router()
        // A loopback bind alone is not a security boundary: DNS rebinding can
        // point any browser on this machine at 127.0.0.1 and read synced mail.
        // Reject requests whose Host is not loopback (Networking/HostGuard.swift).
        router.add(middleware: LoopbackHostMiddleware())
        HealthRoutes.register(on: router)
        OAuthRoutes.register(
            on: router, db: db, oauth: google, sync: syncEngine, logger: logger
        )
        AccountsRoutes.register(
            on: router, db: db, logger: logger, sync: syncEngine, makeProvider: makeProvider
        )
        SyncRoutes.register(on: router, db: db, sync: syncEngine)
        MessageRoutes.register(
            on: router,
            db: db,
            client: gmailClient,
            tokens: tokens,
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
            on: router, db: db, client: gmailClient, tokens: tokens, logger: logger,
            makeProvider: makeProvider
        )
        DraftRoutes.register(
            on: router, db: db, client: gmailClient, tokens: tokens, draftGenerator: ai,
            logger: logger, makeProvider: makeProvider
        )
        SearchRoutes.register(on: router, db: db)
        BudgetRoutes.register(
            on: router,
            budget: usageBudget,
            costTrackingAvailable: ai?.hasConfiguredRates ?? false
        )
        GmailWebhookRoutes.register(on: router)

        let app = Application(
            router: router,
            configuration: .init(address: .hostname(cfg.host, port: cfg.port)),
            logger: logger
        )

        // M0 periodic sync; M1 replaces with Pub/Sub push fanout. The loop
        // blocks inside `pullChanges` (IDLE for IMAP, 30s polls for Gmail), so
        // one tick per 5 minutes is the idle floor, not a busy loop.
        Task { await syncEngine.start() }

        logger.info("starting", metadata: ["host": .string(cfg.host), "port": .string("\(cfg.port)")])
        try await app.runService()
    }

    /// Print a startup refusal to stderr and exit(1). `fatalError` would dump a
    /// crash report and wait for interactive input, which is noise for what is
    /// a deliberate configuration failure.
    private static func die(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}
