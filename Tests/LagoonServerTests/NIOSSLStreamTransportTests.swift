import XCTest
import NIOCore
import NIOPosix
import NIOSSL
@testable import LagoonServer

/// Regression: `NIOSSLStreamTransport.connect` used to wrap the freshly
/// connected channel with `NIOAsyncChannel(wrappingChannelSynchronously:)`
/// from the cooperative pool. That initializer must run on the channel's
/// event loop, so the FIRST real connection (nothing in the scripted-transport
/// tests ever touches this path) crashed the whole server with a precondition
/// failure before a single IMAP byte was exchanged.
///
/// The test speaks to a plain TCP listener on the loopback IMAP port: the wrap
/// happens before any TLS byte matters, so a non-TLS peer is enough. Before
/// the fix this test process dies with SIGTRAP; after it, connect/first-read
/// surface as ordinary transport errors.
/// Closes the connection as soon as it is accepted, so the client's inbound
/// stream ends in EOF instead of hanging (the transport deliberately has no
/// read timeout of its own — that lives in `IMAPConnection`).
private final class CloseOnAcceptHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    func channelActive(context: ChannelHandlerContext) {
        context.close(promise: nil)
        context.fireChannelActive()
    }
}

final class NIOSSLStreamTransportTests: XCTestCase {
    func test_connectingToALiveListener_doesNotCrashAndSurfacesAnError() async throws {
        let group = MultiThreadedEventLoopGroup.singleton
        let listener = try await ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(CloseOnAcceptHandler())
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        // macOS 26 refuses unprivileged binds of privileged ports, so the
        // transport's port whitelist is injectable and the test listens on an
        // ephemeral port instead of the real 993.
        let port = Int(listener.localAddress!.port!)

        let transport = NIOSSLStreamTransport(allowedPorts: [port])
        defer { Task { await transport.close() } }

        var transportError: Error?
        do {
            // A plain TCP peer will not complete the TLS handshake: connect may
            // succeed (wrap is synchronous) and the first read must fail.
            // "localhost" because NIOSSL refuses IP literals as SNI names.
            try await transport.connect(host: "localhost", port: port)
            _ = try await transport.readLine()
        } catch {
            transportError = error
        }
        XCTAssertNotNil(transportError, "expected the non-TLS peer to surface as a transport error")

        try await listener.close().get()
    }
}
