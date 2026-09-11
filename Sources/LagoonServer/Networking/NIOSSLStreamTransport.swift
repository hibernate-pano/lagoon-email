import Foundation
import NIOCore
import NIOPosix
import NIOSSL

/// Production `StreamTransport`: TCP + implicit TLS through NIO/NIOSSL.
///
/// Only 993/465 are allowed and certificates are fully verified (spec §5.2) —
/// there is deliberately no "skip verification" switch. Hosts come from
/// server-side presets, never from user input.
public actor NIOSSLStreamTransport: StreamTransport {
    private static let allowedPorts: Set<Int> = [993, 465]

    private let group: EventLoopGroup
    private var channel: Channel?
    private var inbound: IteratorBox?
    private var pending = ByteBuffer()

    public init(group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton) {
        self.group = group
    }

    public func connect(host: String, port: Int) async throws {
        guard Self.allowedPorts.contains(port) else {
            throw MailError.notConfigured("port \(port) is not an approved implicit-TLS port")
        }
        let sslContext: NIOSSLContext
        do {
            // Full certificate + hostname verification against the system
            // roots; there is deliberately no "skip verification" switch.
            var configuration = TLSConfiguration.makeClientConfiguration()
            configuration.certificateVerification = .fullVerification
            sslContext = try NIOSSLContext(configuration: configuration)
        } catch {
            throw MailError.notConfigured("tls configuration unavailable")
        }

        let bootstrap = ClientBootstrap(group: group)
            // Mirrors `IMAPConnection.connectTimeout`: the greeting read that
            // follows is covered by the connection's own read timeout.
            .connectTimeout(.seconds(10))
            .channelInitializer { channel in
                do {
                    let handler = try NIOSSLClientHandler(
                        context: sslContext,
                        serverHostname: host
                    )
                    try channel.pipeline.syncOperations.addHandler(handler)
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }

        let channel: Channel
        do {
            channel = try await bootstrap.connect(host: host, port: port).get()
        } catch {
            throw MailError.unreachable("tcp-connect")
        }

        do {
            // The scoped `executeThenClose` API cannot express a transport that
            // stays open across many calls, so the (deprecated) long-lived
            // inbound stream accessor is the intended fit here.
            let asyncChannel = try NIOAsyncChannel<ByteBuffer, Never>(
                wrappingChannelSynchronously: channel
            )
            self.inbound = IteratorBox(asyncChannel.inbound.makeAsyncIterator())
            self.channel = channel
        } catch {
            try? await channel.close().get()
            throw MailError.unreachable("tls-handshake")
        }
    }

    public func write(_ bytes: Data) async throws {
        guard let channel else { throw StreamTransportError.notConnected }
        var buffer = channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        do {
            try await channel.writeAndFlush(buffer).get()
        } catch {
            throw MailError.unreachable("write")
        }
    }

    public func readLine() async throws -> String {
        while true {
            if let line = extractLine() { return line }
            try await fillBuffer()
        }
    }

    public func readExactly(_ count: Int) async throws -> Data {
        while pending.readableBytes < count {
            try await fillBuffer()
        }
        guard count > 0, let slice = pending.readSlice(length: count) else {
            return Data()
        }
        return Data(slice.readableBytesView)
    }

    public func close() async {
        inbound = nil
        if let channel {
            try? await channel.close().get()
        }
        channel = nil
        pending.clear()
    }

    // MARK: - Byte plumbing

    private func extractLine() -> String? {
        guard let newline = pending.readableBytesView.firstIndex(of: UInt8(ascii: "\n")) else {
            return nil
        }
        let length = newline - pending.readerIndex
        guard let slice = pending.readSlice(length: length) else { return nil }
        pending.moveReaderIndex(forwardBy: 1)
        var line = String(decoding: slice.readableBytesView, as: UTF8.self)
        if line.hasSuffix("\r") { line.removeLast() }
        return line
    }

    private func fillBuffer() async throws {
        guard let inbound else { throw StreamTransportError.notConnected }
        do {
            guard let chunk = try await inbound.next() else {
                throw StreamTransportError.closed
            }
            pending.writeImmutableBuffer(chunk)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as StreamTransportError {
            throw error
        } catch {
            // TLS handshake, certificate and socket failures are all "cannot
            // reach the mailbox" as far as the sync loop is concerned.
            throw MailError.unreachable("read")
        }
    }
}

/// `NIOAsyncChannel`'s inbound iterator is a struct, so `next()` needs an
/// lvalue; this box provides one. The owning actor serializes all access.
private final class IteratorBox: @unchecked Sendable {
    private var iterator: NIOAsyncChannelInboundStream<ByteBuffer>.AsyncIterator

    init(_ iterator: NIOAsyncChannelInboundStream<ByteBuffer>.AsyncIterator) {
        self.iterator = iterator
    }

    func next() async throws -> ByteBuffer? {
        try await iterator.next()
    }
}
