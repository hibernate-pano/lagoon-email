import Foundation
import Logging

/// One IMAP session: TCP + implicit TLS + greeting, then strictly serial
/// commands. QQ is sensitive to concurrent logins, so a single connection with
/// no pipelining is deliberate (spec §3.1).
///
/// Framing lives here: `{N}` literals are read as exact byte runs and merged
/// back into their logical line, so callers only ever see whole responses.
/// Commands are never logged — `LOGIN` / `AUTHENTICATE` carry credentials.
public actor IMAPConnection {
    public static let connectTimeout: Duration = .seconds(10)
    public static let defaultReadTimeout: Duration = .seconds(30)

    private let transport: any StreamTransport
    private let logger: Logger
    private let readTimeout: Duration

    private var isConnected = false
    private var commandCounter = 0

    public init(
        transport: any StreamTransport,
        logger: Logger,
        readTimeout: Duration = IMAPConnection.defaultReadTimeout
    ) {
        self.transport = transport
        self.logger = logger
        self.readTimeout = readTimeout
    }

    /// Connects and consumes the greeting. The server must speak first
    /// (RFC 3501 §7.1.1), so anything but an untagged OK is a protocol error.
    public func connect(host: String, port: Int) async throws {
        try await transport.connect(host: host, port: port)
        let greeting = try await readResponse(timeout: Self.connectTimeout)
        guard let greeting,
              case .untagged = greeting.kind,
              greeting.raw.uppercased().hasPrefix("* OK") else {
            throw MailError.protocolError("unexpected greeting")
        }
        isConnected = true
        logger.debug(
            "imap.connected",
            metadata: ["host": .string(host), "port": .string("\(port)")]
        )
    }

    /// Sends one command under a freshly minted tag and collects every response
    /// up to (and including) the tagged completion. `.no`/`.bad` completions
    /// surface as `MailError`; a rejected login is typed `.authFailed` so the
    /// sync loop can stop retrying.
    public func execute(_ command: String) async throws -> [IMAPResponse] {
        guard isConnected else { throw StreamTransportError.notConnected }
        let tag = nextTag()
        try await write("\(tag) \(command)")

        var responses: [IMAPResponse] = []
        while true {
            guard let response = try await readResponse(timeout: readTimeout) else { continue }
            switch response.kind {
            case .tagged(let received, let status):
                guard received == tag else {
                    logger.warning("imap.unexpectedTag")
                    responses.append(response)
                    continue
                }
                switch status {
                case .ok:
                    responses.append(response)
                    return responses
                case .no:
                    if response.raw.uppercased().contains("AUTHENTICATIONFAILED") {
                        throw MailError.authFailed
                    }
                    throw MailError.protocolError("tagged NO")
                case .bad:
                    throw MailError.protocolError("tagged BAD")
                }
            case .continuation:
                // No command at this layer sends a payload after a
                // continuation; answer with a bare CRLF so the server does not
                // stall waiting for one (RFC 3501 §7.5).
                try await transport.write(Data("\r\n".utf8))
            case .untagged:
                responses.append(response)
            }
        }
    }

    /// APPEND one literal message to a mailbox. The command uses a
    /// synchronizing literal: wait for `+`, write the exact bytes, then send
    /// the CRLF that terminates the client command.
    public func append(mailbox: String, message: Data) async throws {
        guard isConnected else { throw StreamTransportError.notConnected }
        let tag = nextTag()
        try await write("\(tag) APPEND \(mailbox) (\\Seen) {\(message.count)}")

        while true {
            guard let response = try await readResponse(timeout: readTimeout) else { continue }
            switch response.kind {
            case .continuation:
                try await transport.write(message)
                try await transport.write(Data("\r\n".utf8))
                try await awaitTaggedCompletion(tag: tag)
                return
            case .tagged(_, let status):
                throw Self.error(for: status, raw: response.raw)
            case .untagged:
                continue
            }
        }
    }

    /// Enters IDLE, waits up to `waitUpTo` for a mailbox event, then sends DONE
    /// and re-enters a clean state. Returns as soon as one EXISTS / EXPUNGE /
    /// FETCH arrives so new mail is not delayed by the rest of the budget;
    /// keep-alive noise (`* OK still here`) is not an event.
    public func idle(waitUpTo: Duration) async throws -> [IMAPResponse] {
        guard isConnected else { throw StreamTransportError.notConnected }
        let tag = nextTag()
        try await write("\(tag) IDLE")

        // The server acknowledges with `+ idling`; untagged chatter may precede.
        while true {
            guard let ack = try await readResponse(timeout: readTimeout) else { continue }
            if case .continuation = ack.kind { break }
            if case .tagged = ack.kind {
                throw MailError.protocolError("IDLE refused")
            }
        }

        var events: [IMAPResponse] = []
        let deadline = ContinuousClock.now.advanced(by: waitUpTo)
        while true {
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { break }
            let response: IMAPResponse?
            do {
                response = try await readResponse(timeout: remaining)
            } catch let error as StreamTransportError where error == .timedOut {
                break
            }
            guard let response else { continue }
            if case .untagged = response.kind, Self.isSyncEvent(response) {
                events.append(response)
                break
            }
            if case .tagged = response.kind {
                throw MailError.protocolError("IDLE terminated early")
            }
        }

        try await write("DONE")
        try await drainUntilTagged(tag: tag)
        return events
    }

    public func close() async {
        isConnected = false
        await transport.close()
    }

    // MARK: - Framing

    /// Reads one logical line. When the line declares a `{N}` literal the bytes
    /// are read exactly and the tail that follows them (usually `)`) is merged
    /// back in, so a split FETCH response comes out whole.
    private func readResponse(timeout: Duration) async throws -> IMAPResponse? {
        let transport = self.transport
        var line = try await withReadTimeout(timeout) { try await transport.readLine() }
        var literal: Data?
        while let length = IMAPResponseParser.literalLength(in: line) {
            let chunk = try await withReadTimeout(timeout) { try await transport.readExactly(length) }
            if literal == nil {
                literal = chunk
            } else {
                literal?.append(chunk)
            }
            let tail = try await withReadTimeout(timeout) { try await transport.readLine() }
            line += tail
        }
        return IMAPResponseParser.parse(line: line, literal: literal)
    }

    private func drainUntilTagged(tag: String) async throws {
        while true {
            guard let response = try await readResponse(timeout: readTimeout) else { continue }
            if case .tagged(let received, let status) = response.kind, received == tag {
                guard status == .ok else { throw MailError.protocolError("IDLE DONE refused") }
                return
            }
        }
    }

    private func write(_ line: String) async throws {
        try await transport.write(Data("\(line)\r\n".utf8))
    }

    private func awaitTaggedCompletion(tag: String) async throws {
        while true {
            guard let response = try await readResponse(timeout: readTimeout) else { continue }
            if case .tagged(let received, let status) = response.kind {
                guard received == tag else {
                    logger.warning("imap.unexpectedTag")
                    continue
                }
                if case .ok = status { return }
                throw Self.error(for: status, raw: response.raw)
            }
        }
    }

    private static func error(for status: IMAPStatus, raw: String) -> MailError {
        switch status {
        case .ok:
            return .protocolError("unexpected tagged OK")
        case .no:
            if raw.uppercased().contains("AUTHENTICATIONFAILED") {
                return .authFailed
            }
            return .protocolError("tagged NO")
        case .bad:
            return .protocolError("tagged BAD")
        }
    }

    private func nextTag() -> String {
        commandCounter += 1
        return String(format: "A%04d", commandCounter)
    }

    static func isSyncEvent(_ response: IMAPResponse) -> Bool {
        guard response.atoms.count >= 3 else { return false }
        return ["EXISTS", "EXPUNGE", "FETCH"].contains(response.atoms[2].uppercased())
    }

    /// Races one transport read against `duration`. The read must be
    /// cancellation-aware (both implementations are), otherwise the losing
    /// task would keep the group alive.
    private func withReadTimeout<T: Sendable>(
        _ duration: Duration,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await AsyncTimeout.sleep(for: duration)
                throw StreamTransportError.timedOut
            }
            guard let result = try await group.next() else {
                throw StreamTransportError.timedOut
            }
            group.cancelAll()
            // Drain the losing child before leaving the task-group scope. This
            // avoids a release-runtime teardown crash seen when the timeout
            // child was still deallocating after the result was returned.
            while !group.isEmpty {
                _ = try? await group.next()
            }
            return result
        }
    }
}
