import Foundation
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

    /// Regression for the P0 read-pump livelock. `fillBuffer()` used to return
    /// as soon as the buffer was non-empty, so a partial line (bytes present,
    /// but no `\n` yet) made `readLine`'s own completion loop spin at 100% CPU
    /// instead of parking until the pump delivered the rest. Before the fix
    /// this test never returns.
    func test_readLine_waitsForTheRestOfAPartialLine() async throws {
        let server = try await ScriptedTLSServer(script: [
            (.milliseconds(0), "partial-line-without-crlf"),
            (.milliseconds(200), "-tail\r\n"),
        ])
        defer { Task { await server.shutdown() } }

        let transport = server.makeClientTransport()
        defer { Task { await transport.close() } }
        try await transport.connect(host: "localhost", port: server.port)

        let line = try await transport.readLine()
        XCTAssertEqual(line, "partial-line-without-crlf-tail")
    }

    /// Same trigger for the literal path: `readExactly(N)` must park while the
    /// buffer holds fewer than `N` bytes rather than spin on its own count loop.
    /// The `{N}` literal is delivered in two halves 200 ms apart.
    func test_readExactly_waitsForTheRestOfAPartialLiteral() async throws {
        let server = try await ScriptedTLSServer(script: [
            (.milliseconds(0), "01234"),
            (.milliseconds(200), "56789"),
        ])
        defer { Task { await server.shutdown() } }

        let transport = server.makeClientTransport()
        defer { Task { await transport.close() } }
        try await transport.connect(host: "localhost", port: server.port)

        let data = try await transport.readExactly(10)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "0123456789")
    }

    /// A read parked on partial data must still be cancellable. Before the fix
    /// the spin never reached `Task.checkCancellation()`, so an abandoned read
    /// (IMAPConnection's read timeout) kept the task group alive forever and
    /// starved the pump. After the fix the cancel channel resumes the parked
    /// continuation and the read throws promptly.
    func test_readParkedOnPartialData_honoursCancellation() async throws {
        let server = try await ScriptedTLSServer(script: [
            (.milliseconds(0), "PARTIAL"),
            (.milliseconds(250), "TAIL\r\n"),
        ])
        defer { Task { await server.shutdown() } }

        let transport = server.makeClientTransport()
        defer { Task { await transport.close() } }
        try await transport.connect(host: "localhost", port: server.port)

        let read = Task { try await transport.readLine() }
        // Let the read observe "PARTIAL" and park in `fillBuffer`.
        try await Task.sleep(for: .milliseconds(50))
        read.cancel()

        do {
            _ = try await read.value
            XCTFail("expected the cancelled read to throw")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }

        // The abandoned read must not have poisoned the transport nor eaten the
        // buffered bytes: the next read sees the whole line once the tail lands.
        let line = try await transport.readLine()
        XCTAssertEqual(line, "PARTIALTAIL")
    }
}

// MARK: - Scripted TLS server

/// A TLS server that writes a fixed script of CRLF lines (with delays) to
/// every accepted connection. The client side gets `trustRoots` pointed at
/// the embedded CA, so certificate verification still runs end to end.
private final class ScriptedTLSServer: @unchecked Sendable {
    let port: Int
    private let listener: Channel
    private let tracker: ChildTracker
    private let certificates: [NIOSSLCertificate]

    init(script: [(delay: Duration, bytes: String)]) async throws {
        let material = try Self.generateCertificate()
        let certificates = try NIOSSLCertificate.fromPEMBytes([UInt8](material.certificate.utf8))
        let key = try NIOSSLPrivateKey(bytes: [UInt8](material.key.utf8), format: .pem)
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
        self.certificates = certificates
        listener = channel
        port = Int(listener.localAddress!.port!)
    }

    func makeClientTransport() -> NIOSSLStreamTransport {
        NIOSSLStreamTransport(allowedPorts: [port], trustRoots: .certificates(certificates))
    }

    func shutdown() async {
        await tracker.closeAll()
        try? await listener.close().get()
    }

    private static func generateCertificate() throws -> (certificate: String, key: String) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lagoon-test-tls-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let certificateURL = directory.appendingPathComponent("certificate.pem")
        let keyURL = directory.appendingPathComponent("key.pem")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = [
            "req", "-x509", "-nodes", "-newkey", "rsa:2048",
            "-keyout", keyURL.path,
            "-out", certificateURL.path,
            "-days", "1",
            "-subj", "/CN=localhost",
            "-addext", "subjectAltName=DNS:localhost",
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw StreamTransportError.notConnected
        }
        return (
            try String(contentsOf: certificateURL, encoding: .utf8),
            try String(contentsOf: keyURL, encoding: .utf8)
        )
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
