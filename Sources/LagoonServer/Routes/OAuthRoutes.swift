import Foundation
import Hummingbird
import PostgresNIO
import LagoonKit

public enum OAuthRoutes {
    public static func register(
        on router: Router<BasicRequestContext>,
        db: PostgresConnection,
        oauth: GoogleOAuthClient,
        poller: GmailPoller
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
            guard
                let code = req.uri.queryParameters["code"].map(String.init),
                let state = req.uri.queryParameters["state"].map(String.init),
                let verifier = await OAuthStateStore.shared.take(state: state)
            else {
                return Response(
                    status: .badRequest,
                    body: .init(byteBuffer: ByteBuffer(string: "missing code or state"))
                )
            }
            do {
                let tokens = try await oauth.exchange(code: code, codeVerifier: verifier)
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
                    accessToken: Data(tokens.accessToken.utf8),
                    refreshToken: Data(tokens.refreshToken.utf8),
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
                return Response(
                    status: .internalServerError,
                    body: .init(byteBuffer: ByteBuffer(string: "oauth failed: \(error)"))
                )
            }
        }
    }
}

/// Process-local state map for OAuth state/verifier pairs. M0 single-process;
/// M1+ moves this into a Postgres-backed pending_oauth table so it survives
/// restarts and works across multiple server processes.
public actor OAuthStateStore {
    public static let shared = OAuthStateStore()
    private var map: [String: String] = [:]
    public init() {}
    public func put(state: String, verifier: String) { map[state] = verifier }
    public func take(state: String) -> String? {
        let v = map[state]
        map[state] = nil
        return v
    }
}