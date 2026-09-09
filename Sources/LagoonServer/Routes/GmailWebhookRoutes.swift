import Hummingbird
import NIOCore

public enum GmailWebhookRoutes {
    public static func register(on router: Router<BasicRequestContext>) {
        // Per spec §6.4: M1+ wires this to a Pub/Sub topic whose push endpoint is
        // this URL on a public HTTPS host. M0 returns 200 so local smoke tests pass.
        router.post("webhook/gmail") { _, _ -> Response in
            Response(
                status: .ok,
                body: .init(byteBuffer: ByteBuffer(string: "ok"))
            )
        }
    }
}