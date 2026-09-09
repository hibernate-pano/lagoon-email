import Hummingbird
import NIOCore

public enum GmailWebhookRoutes {
    public static func register(on router: Router<BasicRequestContext>) {
        // ponytail: 501 ceiling — Pub/Sub push needs Google JWT verification
        // and replay protection before it can be enabled; until then it is off.
        router.post("webhook/gmail") { _, _ -> Response in
            Response(
                status: .notImplemented,
                body: .init(byteBuffer: ByteBuffer(
                    string: "Pub/Sub push is not implemented: this endpoint requires Google JWT verification and replay protection before it can be enabled."
                ))
            )
        }
    }
}
