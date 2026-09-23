import Foundation
import Logging
import Hummingbird
import NIOCore
import PostgresNIO
import LagoonKit

/// Gmail push fan-in (V2 A4).
///
/// Without push, Gmail latency is the 30s poller. With a Pub/Sub topic
/// forwarding to this endpoint, a new message wakes only its account's loop
/// within seconds; polling stays as the fallback when push is unconfigured.
///
/// Trust model (deliberately narrow): Google's OIDC verification is not
/// implemented — instead a shared secret (`LAGOON_WEBHOOK_SECRET`) in the
/// `Authorization: Bearer` header gates the endpoint. No secret configured →
/// 501, same as before. A forged trigger only forces an early sync round, so
/// the blast radius of a leaked secret is one wasted poll, not data access
/// (there is no read path here at all).
public enum GmailWebhookRoutes {
    private struct PushEnvelope: Decodable {
        struct Message: Decodable {
            /// base64(JSON `{"emailAddress": ..., "historyId": ...}`).
            let data: String?
            let messageId: String?
        }
        let message: Message?
        let subscription: String?
    }

    private struct PushPayload: Decodable {
        let emailAddress: String?
        let historyId: String?
    }

    public static func register(
        on router: Router<BasicRequestContext>,
        db: PostgresConnection,
        logger: Logger,
        sync: SyncEngine? = nil,
        webhookSecret: String? = nil
    ) {
        let secret = webhookSecret
            ?? ProcessInfo.processInfo.environment["LAGOON_WEBHOOK_SECRET"]
                .flatMap { $0.isEmpty ? nil : $0 }
        router.post("webhook/gmail") { request, _ -> Response in
            guard let secret else {
                return Response(
                    status: .notImplemented,
                    body: .init(byteBuffer: ByteBuffer(string:
                        "Pub/Sub push is not configured: set LAGOON_WEBHOOK_SECRET and point the push subscription here."
                    ))
                )
            }
            guard request.headers[.authorization] == "Bearer \(secret)" else {
                return RouteJSON.error(.unauthorized, "webhook-unauthorized")
            }
            let body: Data
            do {
                body = try await RouteParams.collectBody(request)
            } catch {
                return RouteJSON.error(.badRequest, "missing-body")
            }
            guard let envelope = try? JSONDecoder().decode(PushEnvelope.self, from: body),
                  let data = envelope.message?.data.flatMap({ Data(base64Encoded: $0) }),
                  let payload = try? JSONDecoder().decode(PushPayload.self, from: data),
                  let email = payload.emailAddress, !email.isEmpty
            else {
                return RouteJSON.error(.badRequest, "malformed-push")
            }
            // 204 either way: the endpoint must not oracle which addresses
            // are connected.
            if let account = try? await AccountStore.find(byEmail: email, provider: .gmail, db: db) {
                await sync?.refreshAccount(account.id)
            } else {
                logger.debug("webhook.gmail.unknownAddress", metadata: [
                    "email": .string(email),
                ])
            }
            return Response(status: .noContent)
        }
    }
}
