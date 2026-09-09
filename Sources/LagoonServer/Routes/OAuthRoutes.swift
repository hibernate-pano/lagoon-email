import Foundation
import Logging
import Hummingbird
import PostgresNIO
import LagoonKit

public enum OAuthRoutes {
    public static func register(
        on router: Router<BasicRequestContext>,
        db: PostgresConnection,
        oauth: GoogleOAuthClient,
        poller: GmailPoller,
        logger: Logger
    ) {
        router.get("oauth/gmail/start") { _, _ -> Response in
            let pair = PKCE.generate()
            let state = UUID().uuidString
            // Stash verifier+state in-memory keyed by state; single-process M0.
            await OAuthStateStore.shared.put(state: state, verifier: pair.verifier)
            let url = oauth.authorizeURL(state: state, codeChallenge: pair.challenge)
            return Response.redirect(to: url.absoluteString, type: .found)
        }

        router.get("oauth/gmail/callback") { req, _ -> Response in
            let params = req.uri.queryParameters
            // Google can send us back with ?error=... instead of a code.
            if let oauthError = params["error"].map(String.init) {
                if let state = params["state"].map(String.init) {
                    _ = await OAuthStateStore.shared.take(state: state)
                }
                if oauthError == "access_denied" {
                    return Response(
                        status: .ok,
                        body: .init(byteBuffer: ByteBuffer(
                            string: "Lagoon was not granted Gmail access. You can close this window."
                        ))
                    )
                }
                return Response(
                    status: .badRequest,
                    body: .init(byteBuffer: ByteBuffer(
                        string: "Google rejected the connection request."
                    ))
                )
            }
            guard
                let code = params["code"].map(String.init),
                let state = params["state"].map(String.init),
                let verifier = await OAuthStateStore.shared.take(state: state)
            else {
                return Response(
                    status: .badRequest,
                    body: .init(byteBuffer: ByteBuffer(string: "missing code or state"))
                )
            }
            do {
                let tokens = try await oauth.exchange(code: code, codeVerifier: verifier)
                guard let refreshToken = tokens.refreshToken else {
                    throw OAuthClientError.missingRefreshToken
                }
                let info = try await oauth.fetchUserInfo(accessToken: tokens.accessToken)
                let account = Account(
                    id: UUID(),
                    provider: .gmail,
                    oauthUser: info.sub,
                    email: info.email,
                    tokenExpiresAt: Date().addingTimeInterval(TimeInterval(tokens.expiresIn)),
                    historyId: nil
                )
                try await AccountStore.upsert(
                    account,
                    accessToken: try AccessTokenCipher.seal(tokens.accessToken),
                    refreshToken: try AccessTokenCipher.seal(refreshToken),
                    db: db
                )
                await poller.tick()
                return Response(
                    status: .ok,
                    body: .init(byteBuffer: ByteBuffer(
                        string: "Lagoon connected to \(info.email). You may close this window."
                    ))
                )
            } catch {
                // Never reflect internals to the browser; details go to the log.
                logger.error("oauth callback failed", metadata: ["err": .string("\(error)")])
                return Response(
                    status: .internalServerError,
                    body: .init(byteBuffer: ByteBuffer(
                        string: "Could not complete the Gmail connection. Check the server logs and try again."
                    ))
                )
            }
        }
    }
}

/// Process-local state map for OAuth state/verifier pairs. M0 single-process;
/// M1+ moves this into a Postgres-backed pending_oauth table so it survives
/// restarts and works across multiple server processes.
///
/// Entries expire after `ttl` (default 10 minutes) so an abandoned consent
/// screen cannot leak verifier state forever.
public actor OAuthStateStore {
    public static let shared = OAuthStateStore()
    private struct Entry {
        let verifier: String
        let createdAt: Date
    }
    private var map: [String: Entry] = [:]
    private let ttl: TimeInterval

    public init(ttl: TimeInterval = 600) {
        self.ttl = ttl
    }

    public func put(state: String, verifier: String) {
        purgeExpired()
        map[state] = Entry(verifier: verifier, createdAt: Date())
    }

    public func take(state: String) -> String? {
        purgeExpired()
        let entry = map[state]
        map[state] = nil
        return entry?.verifier
    }

    private func purgeExpired() {
        let cutoff = Date().addingTimeInterval(-ttl)
        map = map.filter { $0.value.createdAt > cutoff }
    }
}
