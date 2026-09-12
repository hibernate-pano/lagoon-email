import XCTest
import NIOCore
import NIOPosix
import NIOSSL
@testable import LagoonServer

/// Regression for the second production crash (exit 133):
/// `NIOThrowingAsyncSequenceProducer.swift:1240: Fatal error: This should
/// never happen since we only allow a single Iterator to be created`.
///
/// Two reads on one live transport used to overlap on the inbound iterator:
/// IDLE holds a read open for minutes, the read timeout cancels it, and a
/// concurrent command read (e.g. `GET /api/accounts` → `capabilities()` while
/// the sync tick is in IDLE) enters `next()` while the abandoned one is still
/// suspended. Before the read-pump fix this test process dies with SIGTRAP.
///
/// The tests speak to a scripted TLS server on the loopback ephemeral port.
/// The certificate is a self-signed localhost cert generated for this test
/// suite only; the client still does full certificate verification, just
/// against this CA instead of the system roots.
final class NIOSSLStreamTransportConcurrencyTests: XCTestCase {
    func test_concurrentReadLines_allComplete() async throws {
        let server = try await ScriptedTLSServer(script: [
            (.milliseconds(0), "L1\r\n"),
            (.milliseconds(150), "L2\r\n"),
            (.milliseconds(300), "L3\r\n"),
            (.milliseconds(450), "L4\r\n"),
            (.milliseconds(600), "L5\r\n"),
            (.milliseconds(750), "L6\r\n"),
        ])
        defer { Task { await server.shutdown() } }

        let transport = server.makeClientTransport()
        defer { Task { await transport.close() } }
        try await transport.connect(host: "localhost", port: server.port)

        let first = try await transport.readLine()
        XCTAssertEqual(first, "L1")

        // Five reads at once: exactly the overlap that used to trip NIO's
        // single-iterator precondition.
        let lines = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<5 { group.addTask { try await transport.readLine() } }
            var collected: [String] = []
            for try await line in group { collected.append(line) }
            return collected
        }
        XCTAssertEqual(Set(lines), ["L2", "L3", "L4", "L5", "L6"])
    }

    func test_readAbandonedByTimeout_doesNotBreakFollowingRead() async throws {
        let server = try await ScriptedTLSServer(script: [
            (.milliseconds(0), "HELLO\r\n"),
            (.milliseconds(600), "LATE\r\n"),
        ])
        defer { Task { await server.shutdown() } }

        let transport = server.makeClientTransport()
        defer { Task { await transport.close() } }
        try await transport.connect(host: "localhost", port: server.port)

        let hello = try await transport.readLine()
        XCTAssertEqual(hello, "HELLO")

        // Mirror IMAPConnection.withReadTimeout: race the read against a
        // timer, let the timer win, then keep using the transport.
        do {
            try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { try await transport.readLine() }
                group.addTask {
                    try await Task.sleep(for: .milliseconds(100))
                    throw StreamTransportError.timedOut
                }
                _ = try await group.next()
                group.cancelAll()
            }
            XCTFail("expected the read to be abandoned by the timeout")
        } catch StreamTransportError.timedOut {
            // expected
        }

        // The abandoned read must not have torn the producer down: the next
        // read still gets the bytes the server sent after the timeout.
        let late = try await transport.readLine()
        XCTAssertEqual(late, "LATE")
    }
}

// MARK: - Scripted TLS server

/// A TLS server that writes a fixed script of CRLF lines (with delays) to
/// every accepted connection. The client side gets `trustRoots` pointed at
/// the embedded CA, so certificate verification still runs end to end.
private final class ScriptedTLSServer: @unchecked Sendable {
    private static let certPEM = """
    -----BEGIN CERTIFICATE-----
    MIIDHzCCAgegAwIBAgIUElLZSha+AG4v9CqcT9QdgfS33AMwDQYJKoZIhvcNAQEL
    BQAwFDESMBAGA1UEAwwJbG9jYWxob3N0MB4XDTI2MDkxMjEyNTQyOVoXDTM2MDkw
    OTEyNTQyOVowFDESMBAGA1UEAwwJbG9jYWxob3N0MIIBIjANBgkqhkiG9w0BAQEF
    AAOCAQ8AMIIBCgKCAQEAx3Z/AblL3GU22rduwXhncGk9vjPOkZ7NS4nxEfHVcBxt
    yuWLRBmRu4IjkMpebu68yApU23ggVzHVNAY3WgxuwNCpDnP8kaMMvaxsDfzDLTCV
    fTB9X9RfaKf5swSdOVimNpUSQIwmVuS2yRuFbwowi1pQ+COz5ZBGi5cdEmQejmZy
    gxbeZWouupQkO8rYfHaYDcC1cTpKyY1fRaV7gDoaB4sHChcHEa7Zubmn66Htw5UM
    t7WZvlMf8zX8FV0Y23abDwvi8uzNFwD6++lBIRGL/meDnz5u5th4zwkfauvOfQo/
    kKPPTXn9R/A5yhqIA33jNGMEbWbGKZQjvjRieNFTEwIDAQABo2kwZzAdBgNVHQ4E
    FgQUMywT5RG6JMnpmfPXkoC6QtKJxZUwHwYDVR0jBBgwFoAUMywT5RG6JMnpmfPX
    koC6QtKJxZUwDwYDVR0TAQH/BAUwAwEB/zAUBgNVHREEDTALgglsb2NhbGhvc3Qw
    DQYJKoZIhvcNAQELBQADggEBAGvoA2vV5oOS9v02PZ21VHt9uA8j3FK7GL+UeLNi
    p7S4wvxb4rqIi0unrdCQCqgaDMnVr3ZnYTtxjs7Ppu4oZwebbjdYqYV2AjRdXWvU
    aBgaVrOjWQzEW1P4jvBceEqHw+nqWPq2xIu7a3mXwyzcSGEXv7bpAVu83kpnsAZx
    eUsSJhGvVNL4sD5F9Em0N9XXr7d9OK+ml+xDkO5YQ051mzpp7D4vvnU1TsPH1xoL
    GwGI2CxtjU2GEiVI8l7HxpppOj/vPZjPuCWS96/vIcAwI3ZCyUHuektmLtVNJAsZ
    /zWQHAZ1PKJSgT/oRsH6mLK96z98l2eFdXiCaW/z0sUz2Uo=
    -----END CERTIFICATE-----
    """

    private static let keyPEM = """
    -----BEGIN PRIVATE KEY-----
    MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQDHdn8BuUvcZTba
    t27BeGdwaT2+M86Rns1LifER8dVwHG3K5YtEGZG7giOQyl5u7rzIClTbeCBXMdU0
    BjdaDG7A0KkOc/yRowy9rGwN/MMtMJV9MH1f1F9op/mzBJ05WKY2lRJAjCZW5LbJ
    G4VvCjCLWlD4I7PlkEaLlx0SZB6OZnKDFt5lai66lCQ7yth8dpgNwLVxOkrJjV9F
    pXuAOhoHiwcKFwcRrtm5uafroe3DlQy3tZm+Ux/zNfwVXRjbdpsPC+Ly7M0XAPr7
    6UEhEYv+Z4OfPm7m2HjPCR9q6859Cj+Qo89Nef1H8DnKGogDfeM0YwRtZsYplCO+
    NGJ40VMTAgMBAAECggEAE4+plVEx6+DZ4tQ8yT4reB48vw5UnU+uFtDl3UUoEfEa
    drH77kdK//vGIiPT5Abcvl9+V/GtdkT9rDb0hGEWFtRqfUTfCadXD149UJfadPA/
    +4GJt3Vb5VHH5Ahj+jpD6V7FkKKjUJU93yDS/VifTyNMhTFMf2Bz/VTqCyIveaEi
    RiDWsG1XqejOKIlnPsh9wOMs/OZ9r7EZQ3HlcR/ApfvB9Qhew+KwN62xZ6lICL9z
    mNuJJEdmvkGMTUfHATJGPT/zjw+OoDSEo7ucuZsxrwdaHIWIAhWZZh3wAgMhwLUg
    xIQABKbMPtNja6oxqOZwKZesiohHobEmvthfCCAhGQKBgQD2J+/N+tkhduEkNHLN
    lQRhNE4c/+mN4hi/piuZrgGFRWceDaiBSKxFVbOVGyT+sdGumhOUlSXtpdRilAoG
    To/4Y0z+uoUt5rEueT/67or32Q4NrtqXgR5vSKG8I2/De2RYIlYOzUHVJqWfoIQ9
    3UJuf10t2f3y/0hOvSMwqrYtuQKBgQDPcIfamcqjF3tCu1t6C3vU+6bmAPJQs+jd
    f6Gtfu1DYz19lWwsilueGftKDWwC3u7NhGXlOUy6elofVKTyZQTgVbdv/I+SSv/U
    yQToLKWwOXZwUj4FT6mpJT4qGpwERKRMap2GeyempDQlzQkMrgndJ+bWd9BTXLew
    puYJN69NKwKBgQCcZym2fgGCgs9wuqaLO3jp7lsHkA8s6JEDDKk9X1N2A3AOp2z+
    oFddQqP1RKcP8ZoiT6HLUa0kv64f6KIp+bb+gtHENG00ihTgS4g8f17rNg344bXg
    d9kHqmWhbf6wfXF3knGNvBttPL4Vm98Kk9CG9wQUgyMZR90AsqpuXLmeeQKBgGPi
    lrgPF8DifKrMVqb0wqLyrhHQYN21U6rcWziUhqDNN32yJo1n7ee6MQMeZWUYfbqe
    RwZSSfz9D0pI0sgZFnkDLToSTfuue3O1e9RkM0Ag20QIhe6+xj45Pa6+c2OmvcpC
    CCoKQTR/mtCc4v+lCgDgxsl8leaeHaFFLD1B//pTAoGAbIkQmM4XaQpMUezf31nP
    6/qyasQnGQ/9bKhWXIRa39JMtW4ktM0UKKOcUojGu6F76H8H6AVufhGgn8Gl6Q+j
    lq/tBIf12CaFpPvQ2QRqTm6NA7ER6OUp46Urm/p9qnZ65xnK6NYqtDLo0fXmQvFb
    fwGbbLU4kRm8NmXJAP1zFI0=
    -----END PRIVATE KEY-----
    """

    let port: Int
    private let listener: Channel
    private let tracker: ChildTracker

    init(script: [(delay: Duration, bytes: String)]) async throws {
        let certificates = try NIOSSLCertificate.fromPEMBytes([UInt8](Self.certPEM.utf8))
        let key = try NIOSSLPrivateKey(bytes: [UInt8](Self.keyPEM.utf8), format: .pem)
        let configuration = TLSConfiguration.makeServerConfiguration(
            certificateChain: certificates.map { .certificate($0) },
            privateKey: .privateKey(key)
        )
        let sslContext = try NIOSSLContext(configuration: configuration)
        let group = MultiThreadedEventLoopGroup.singleton
        let tracker = ChildTracker()
        let channel = try await ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(NIOSSLServerHandler(context: sslContext)).flatMap {
                    channel.pipeline.addHandler(ScriptHandler(script: script, tracker: tracker))
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        self.tracker = tracker
        listener = channel
        port = Int(listener.localAddress!.port!)
    }

    func makeClientTransport() -> NIOSSLStreamTransport {
        // swiftlint:disable:next force_try
        let ca = try! NIOSSLCertificate.fromPEMBytes([UInt8](Self.certPEM.utf8))
        return NIOSSLStreamTransport(allowedPorts: [port], trustRoots: .certificates(ca))
    }

    func shutdown() async {
        await tracker.closeAll()
        try? await listener.close().get()
    }
}

private final class ChildTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var channels: [Channel] = []

    func add(_ channel: Channel) {
        lock.lock(); channels.append(channel); lock.unlock()
    }

    private func takeAll() -> [Channel] {
        lock.lock(); defer { lock.unlock() }
        let open = channels
        channels.removeAll()
        return open
    }

    func closeAll() async {
        for channel in takeAll() {
            try? await channel.close().get()
        }
    }
}

private final class ScriptHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let script: [(delay: Duration, bytes: String)]
    private let tracker: ChildTracker

    init(script: [(delay: Duration, bytes: String)], tracker: ChildTracker) {
        self.script = script
        self.tracker = tracker
    }

    func channelActive(context: ChannelHandlerContext) {
        tracker.add(context.channel)
        let channel = context.channel
        let script = self.script
        Task {
            for (delay, text) in script {
                try? await Task.sleep(for: delay)
                var buffer = channel.allocator.buffer(capacity: text.utf8.count)
                buffer.writeString(text)
                try? await channel.writeAndFlush(buffer).get()
            }
        }
    }
}
