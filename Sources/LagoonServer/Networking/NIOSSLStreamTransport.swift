import Foundation
import NIOCore
import NIOPosix
import NIOSSL

/// Production `StreamTransport`: TCP + implicit TLS through NIO/NIOSSL.
///
/// Only 993/465 are allowed and certificates are fully verified (spec §5.2) —
/// there is deliberately no "skip verification" switch. Hosts come from
/// server-side presets, never from user input.
///
/// Reads run through a single background pump: it alone owns the inbound
/// iterator (NIO precondition-fails on concurrent `next()`) and copies every
/// chunk into a buffer that `readLine`/`readExactly` wait on. An abandoned
/// read (read timeout) therefore can no longer tear the producer down for
/// the reads that follow it.
public actor NIOSSLStreamTransport: StreamTransport {
    private let allowedPorts: Set<Int>
    private let trustRoots: NIOSSLTrustRoots?

    private let group: EventLoopGroup
    private var channel: Channel?
    private var pending = ByteBuffer()

    private var pumpTask: Task<Void, Never>?
    private var pumpEpoch = 0
    private var pumpRunning = false
    private var readFailure: Error?
    private var readWaiters: [ReadWaiter] = []

    public init(
        group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
        allowedPorts: Set<Int> = [993, 465],
        trustRoots: NIOSSLTrustRoots? = nil
    ) {
        self.group = group
        self.allowedPorts = allowedPorts
        self.trustRoots = trustRoots
    }

    public func connect(host: String, port: Int) async throws {
        await close()
        guard allowedPorts.contains(port) else {
            throw MailError.notConfigured("port \(port) is not an approved implicit-TLS port")
        }
        let sslContext: NIOSSLContext
        do {
            // Full certificate + hostname verification against the system
            // roots; there is deliberately no "skip verification" switch.
            var configuration = TLSConfiguration.makeClientConfiguration()
            if let trustRoots {
                configuration.trustRoots = trustRoots
            }
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
            //
            // `wrappingChannelSynchronously` must run on the channel's event
            // loop (it precondition-checks); this actor method runs on the
            // cooperative pool, so hop over first. Off-loop wrapping crashes
            // the process on the FIRST real connection.
            let asyncChannel = try await channel.eventLoop.submit {
                try NIOAsyncChannel<ByteBuffer, Never>(
                    wrappingChannelSynchronously: channel
                )
            }.get()
            let box = IteratorBox(asyncChannel.inbound.makeAsyncIterator())
            self.channel = channel
            // From here on, only the read pump touches the inbound iterator.
            pumpEpoch += 1
            let epoch = pumpEpoch
            pumpRunning = true
            readFailure = nil
            // The pump is handed the iterator and a *weak* owner, never
            // `self`: a parked `next()` is the normal state of an idle
            // session, and a pump that retained the transport — directly or
            // through its own closure — would keep the TLS session and its
            // file descriptor alive for as long as the process ran.
            let owner = Owner(transport: self)
            pumpTask = Task {
                await Self.runPump(box: box, epoch: epoch, owner: owner)
            }
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
        // Bump the epoch first so a pump from an older connection exits
        // without touching the new generation's state.
        pumpEpoch += 1
        pumpTask?.cancel()
        pumpTask = nil
        pumpRunning = false
        if let channel {
            try? await channel.close().get()
            readFailure = StreamTransportError.closed
        }
        channel = nil
        pending.clear()
        wakeReadWaiters()
    }

    /// Last resort for a transport that is dropped without `close()` — a
    /// provider rebuilt in place, an account deleted, a failed connect. By
    /// this point nothing else can reach the transport (the read pump no
    /// longer retains it), so this is the only chance to hand the socket back
    /// rather than leave an authenticated session on the server until its own
    /// idle timeout. `close(promise: nil)` is fire-and-forget: the event loop
    /// keeps the channel alive until the close runs, and a deinit cannot await.
    deinit {
        pumpTask?.cancel()
        channel?.close(promise: nil)
    }

    // MARK: - Byte plumbing

    /// Sole consumer of the inbound iterator. NIO's producer precondition-fails
    /// on concurrent `next()` calls, which is exactly what happened when a
    /// read-timeout abandoned one read and IDLE/a command read overlapped it.
    /// Here `next()` is only ever called by this loop, sequentially; readers
    /// wait on `pending` instead of on the wire.
    ///
    /// `nonisolated` on purpose. The loop spends its life parked inside
    /// `box.next()`; running it as an actor method would hold the transport
    /// for exactly that long, and a retained transport holds the TLS session
    /// and the file descriptor. Everything it touches goes back through
    /// `Owner`, which reaches the actor only for the length of one call.
    private nonisolated static func runPump(box: IteratorBox, epoch: Int, owner: Owner) async {
        do {
            while let chunk = try await box.next() {
                guard await owner.deliver(chunk, epoch: epoch) else { return }
            }
            await owner.pumpEnded(epoch: epoch, unreachable: false)
        } catch is CancellationError {
            await owner.pumpEnded(epoch: epoch, unreachable: false)
        } catch {
            // TLS handshake, certificate and socket failures are all
            // "cannot reach the mailbox" as far as the sync loop is
            // concerned.
            await owner.pumpEnded(epoch: epoch, unreachable: true)
        }
    }

    /// Publish one chunk. False means the pump belongs to a superseded
    /// generation (or the transport is gone): stop reading.
    fileprivate func absorb(_ chunk: ByteBuffer, epoch: Int) -> Bool {
        guard epoch == pumpEpoch else { return false }
        pending.writeImmutableBuffer(chunk)
        wakeReadWaiters()
        return true
    }

    /// The pump stopped. A stale epoch means `close()`/`connect()` already
    /// published the failure and woke the readers; only the current generation
    /// finalizes here.
    fileprivate func pumpEnded(epoch: Int, unreachable: Bool) {
        guard epoch == pumpEpoch else { return }
        readFailure = unreachable ? MailError.unreachable("read") : StreamTransportError.closed
        pumpRunning = false
        wakeReadWaiters()
    }

    private func wakeReadWaiters() {
        let waiters = readWaiters
        readWaiters.removeAll()
        for waiter in waiters {
            waiter.take()?.resume()
        }
    }

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

    /// Parks until the pump delivers another chunk, then returns. Deliberately a
    /// single wait, NOT `while pending.readableBytes == 0`.
    ///
    /// Both callers already carry their own completion condition: `readLine`
    /// loops until `extractLine()` yields a whole line, `readExactly` loops
    /// until the buffer holds `count` bytes. `fillBuffer`'s only job is therefore
    /// "block until there is *new* data". A non-empty buffer does not imply the
    /// caller is satisfied — a partial line, or a partial `{N}` literal, leaves
    /// bytes present while the read is still unfinished. The old zero-length
    /// guard mistook "buffer non-empty" for "data is sufficient", returned
    /// immediately on that partial input, and made both callers spin at 100% CPU:
    /// the spin never reached `Task.checkCancellation()`, so a read timeout could
    /// not drain its task group (the sync never finished), and the spinning
    /// tasks starved the pump off the cooperative pool, so the bytes that would
    /// have completed the read were never delivered. A single wait parks the
    /// reader until the pump wakes it, and throws on failure/close instead of
    /// ever returning with the caller's condition unmet.
    private func fillBuffer() async throws {
        if let readFailure { throw readFailure }
        guard pumpRunning else { throw StreamTransportError.notConnected }
        // A read abandoned by IMAPConnection's read timeout is cancelled:
        // surface that here instead of parking again.
        try Task.checkCancellation()
        let waiter = ReadWaiter()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiter.store(continuation)
                readWaiters.append(waiter)
            }
        } onCancel: {
            // Already-cancelled task: `store` may not have run yet. `cancel()`
            // covers both orderings (see `ReadWaiter`) so the continuation is
            // always resumed exactly once.
            waiter.cancel()
        }
        // A cancellation that raced the wake-up must not let a caller keep
        // looping as if fresh bytes had arrived; bail out to the next check.
        try Task.checkCancellation()
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

/// The read pump's route back into the transport, held weakly on purpose:
/// the pump outlives individual calls by design, and it must never be the
/// reason a transport stays alive.
private final class Owner: @unchecked Sendable {
    private weak var transport: NIOSSLStreamTransport?

    init(transport: NIOSSLStreamTransport) {
        self.transport = transport
    }

    /// False when the generation was superseded or the transport is gone.
    func deliver(_ chunk: ByteBuffer, epoch: Int) async -> Bool {
        guard let transport else { return false }
        return await transport.absorb(chunk, epoch: epoch)
    }

    func pumpEnded(epoch: Int, unreachable: Bool) async {
        await transport?.pumpEnded(epoch: epoch, unreachable: unreachable)
    }
}

/// Registration handle for a reader blocked in `fillBuffer`. Cancellation can
/// fire on any thread (and even before `store` runs, when the task is already
/// cancelled on entry), so the continuation swap is lock-guarded.
///
/// Invariant: the continuation is resumed **exactly once**, for any interleaving
/// of `store()`, `cancel()` and the pump's `take()`. Whichever of `store`/
/// `cancel` observes the lock first wins: `cancel` marks itself and resumes a
/// stored continuation (or `store` sees the flag and resumes in place), and
/// `take` never hands the same continuation to two owners.
private final class ReadWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var cancelled = false

    func store(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if cancelled {
            lock.unlock()
            continuation.resume()
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    /// Called from `onCancel`. If the continuation is not stored yet, the
    /// `cancelled` flag makes the later `store` resume it immediately.
    func cancel() {
        lock.lock()
        cancelled = true
        let taken = continuation
        continuation = nil
        lock.unlock()
        taken?.resume()
    }

    /// Pump wake-up path: atomically claims the continuation. Returns nil when
    /// `cancel` already resumed it.
    func take() -> CheckedContinuation<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        let taken = continuation
        continuation = nil
        return taken
    }
}
