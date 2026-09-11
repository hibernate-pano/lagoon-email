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

        let google = GoogleOAuthClient(
            clientID: cfg.googleClientID,
            clientSecret: cfg.googleClientSecret,
            redirectURI: cfg.googleRedirectURI
        )
        // One shared token service so the poller and the message routes share
        // the single-flight refresh registry.
        let gmailClient = GmailClient()
        let tokens = GmailTokenService(db: db, oauth: google, logger: logger)
        let poller = GmailPoller(db: db, client: gmailClient, tokens: tokens, logger: logger)

        // Spec §6.5: the AI Gateway is the only module that talks to LLM
        // providers. `nil` when no provider is configured (missing key/base
        // URL) — the server then stays heuristic-only and /summary returns 503.
        // The budget actor enforces the monthly cost cap from
        // LAGOON_BUDGET_USD_PER_MONTH (<= 0 disables); see Sources/LagoonServer/AI/UsageBudget.swift.
        let capUSD = Double(ProcessInfo.processInfo.environment["LAGOON_BUDGET_USD_PER_MONTH"] ?? "") ?? 0
        let usageBudget = try await UsageBudget(db: db, capUSDPerMonth: capUSD, logger: logger)
        let ai: AIGateway? = {
            guard let gateway = AIGateway.fromEnvironment(logger: logger) else { return nil }
            return gateway
        }()
        if ai == nil {
            logger.info("AI gateway disabled: set LLM_PROVIDER_PRIMARY_BASE_URL and LLM_PROVIDER_PRIMARY_API_KEY")
        }

        let router = Router()
        // A loopback bind alone is not a security boundary: DNS rebinding can
        // point any browser on this machine at 127.0.0.1 and read synced mail.
        // Reject requests whose Host is not loopback (Networking/HostGuard.swift).
        router.add(middleware: LoopbackHostMiddleware())
        HealthRoutes.register(on: router)
        OAuthRoutes.register(on: router, db: db, oauth: google, poller: poller, logger: logger)
        AccountsRoutes.register(on: router, db: db)
        SyncRoutes.register(on: router, db: db)
        MessageRoutes.register(
            on: router,
            db: db,
            client: gmailClient,
            tokens: tokens,
            logger: logger,
            summarizer: ai
        )
        BriefingRoutes.register(on: router, db: db, logger: logger, classifier: ai)
        ActionsRoutes.register(
            on: router, db: db, client: gmailClient, tokens: tokens, logger: logger
        )
        DraftRoutes.register(
            on: router, db: db, client: gmailClient, tokens: tokens, summarizer: ai, logger: logger
        )
        SearchRoutes.register(on: router, db: db)
        BudgetRoutes.register(on: router, budget: usageBudget)
        GmailWebhookRoutes.register(on: router)

        let app = Application(
            router: router,
            configuration: .init(address: .hostname(cfg.host, port: cfg.port)),
            logger: logger
        )

        // M0 periodic sync; M1 replaces with Pub/Sub push fanout.
        Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await poller.tick()
            }
        }

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
