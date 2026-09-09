import Foundation
import Logging
import PostgresNIO
import Hummingbird
import LagoonKit

@main
struct LagoonServerMain {
    static func main() async throws {
        let logger = Logger(label: "lagoon.server")
        let cfg = ServerConfig.load()
        let pgCfg = PostgresConfig.load()

        let elg = LagoonPostgres.makeEventLoopGroup()
        let db = try await LagoonPostgres.connect(pgCfg, on: elg.any())

        let google = GoogleOAuthClient(
            clientID: cfg.googleClientID,
            clientSecret: cfg.googleClientSecret,
            redirectURI: cfg.googleRedirectURI
        )
        let poller = GmailPoller(db: db, client: GmailClient(), logger: logger)

        let router = Router()
        HealthRoutes.register(on: router)
        OAuthRoutes.register(on: router, db: db, oauth: google, poller: poller)
        SyncRoutes.register(on: router, db: db)
        GmailWebhookRoutes.register(on: router)

        let app = Application(
            router: router,
            configuration: .init(address: .hostname("127.0.0.1", port: cfg.port)),
            logger: logger
        )

        // M0 periodic sync; M1 replaces with Pub/Sub push fanout.
        Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await poller.tick()
            }
        }

        logger.info("starting", metadata: ["port": .string("\(cfg.port)")])
        try await app.runService()
    }
}