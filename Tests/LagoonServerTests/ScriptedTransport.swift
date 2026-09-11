import Foundation
@testable import LagoonServer

/// Scripted `StreamTransport` for `IMAPConnectionTests`: the whole IMAP wire
/// conversation is queued up front, so tests assert exact command bytes and
/// exact framing without a socket.
///
/// - `closeAfterScript` (default true): reads past the end of the script throw
///   `StreamTransportError.closed`, mimicking a server that hung up.
/// - `closeAfterScript: false`: reads block until `enqueue` supplies more —
///   the only way to exercise read timeouts.
actor ScriptedTransport: StreamTransport {
    enum ScriptError: Error, Equatable {
        /// A test asked for bytes the script does not have in that shape
        /// (e.g. `readLine` where only a literal was enqueued).
        case typeMismatch
    }

    private enum Event {
        case line(String)
        case literal(Data)
        /// Delivered only once the client has written `minWrites` commands:
        /// lets a test express "the server answers after DONE" deterministically,
        /// without sleeping.
        case deferredLine(String, minWrites: Int)
    }

    private var script: [Event]
    private let closeAfterScript: Bool

    private(set) var writes: [Data] = []
    private(set) var connectedHost: String?
    private(set) var connectedPort: Int?
    private var isClosed = false

    init(closeAfterScript: Bool = true) {
        self.script = []
        self.closeAfterScript = closeAfterScript
    }

    func enqueue(_ line: String) {
        script.append(.line(line))
    }

    func enqueue(_ line: String, onlyAfterWrites minWrites: Int) {
        script.append(.deferredLine(line, minWrites: minWrites))
    }

    func enqueueLiteral(_ data: Data) {
        script.append(.literal(data))
    }

    // MARK: - StreamTransport

    func connect(host: String, port: Int) async throws {
        connectedHost = host
        connectedPort = port
        // A fresh connect is a fresh session: a client that reconnects after
        // `close()` (SMTP retry/next send) must be able to write again.
        isClosed = false
    }

    func write(_ bytes: Data) async throws {
        guard !isClosed else { throw StreamTransportError.closed }
        writes.append(bytes)
    }

    func readLine() async throws -> String {
        while true {
            if let first = script.first {
                switch first {
                case .line(let line):
                    script.removeFirst()
                    return line
                case .deferredLine(let line, let minWrites):
                    if writes.count >= minWrites {
                        script.removeFirst()
                        return line
                    }
                case .literal:
                    throw ScriptError.typeMismatch
                }
            }
            try await waitForMore()
        }
    }

    func readExactly(_ count: Int) async throws -> Data {
        while true {
            if let first = script.first {
                switch first {
                case .literal(let data):
                    script.removeFirst()
                    guard data.count == count else { throw ScriptError.typeMismatch }
                    return data
                case .line:
                    throw ScriptError.typeMismatch
                case .deferredLine(_, let minWrites):
                    if writes.count >= minWrites { throw ScriptError.typeMismatch }
                }
            }
            try await waitForMore()
        }
    }

    func close() async {
        isClosed = true
    }

    /// Blocks until the script head can be delivered, the transport is closed,
    /// or the read is cancelled (the connection's timeout race cancels it).
    /// Polling keeps this double free of continuation bookkeeping while staying
    /// cancellation-safe.
    private func waitForMore() async throws {
        while true {
            if isHeadDeliverable { return }
            if isClosed { throw StreamTransportError.closed }
            if closeAfterScript && script.isEmpty { throw StreamTransportError.closed }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private var isHeadDeliverable: Bool {
        guard let first = script.first else { return false }
        switch first {
        case .line, .literal:
            return true
        case .deferredLine(_, let minWrites):
            return writes.count >= minWrites
        }
    }
}
