import Foundation
import Logging

/// One SMTP delivery: implicit TLS (465), `AUTH PLAIN`, one recipient.
///
/// The spec's retry rule is encoded in `Phase`: anything that fails *before*
/// the DATA payload is on the wire may be retried once (a second full session);
/// once the payload has been sent the outcome is terminal, because a retry
/// could deliver the message twice.
public actor SMTPClient {
    /// EHLO argument. QQ does not verify it, and a fixed name avoids leaking the
    /// user's hostname to the server.
    public static let clientName = "lagoon.local"

    public static let defaultReadTimeout: Duration = .seconds(30)

    /// Where the failure happened, which decides retryability.
    private enum Phase {
        case auth
        case preData
        case postData
    }

    /// Internal wrapper: the `MailError` to surface plus whether a retry is
    /// still safe. Never escapes `send`.
    private struct SMTPFailure: Error {
        let error: MailError
        let retryable: Bool
    }

    private let transport: any StreamTransport
    private let logger: Logger
    private let readTimeout: Duration

    public init(
        transport: any StreamTransport,
        logger: Logger,
        readTimeout: Duration = SMTPClient.defaultReadTimeout
    ) {
        self.transport = transport
        self.logger = logger
        self.readTimeout = readTimeout
    }

    /// Sends one reply and returns the locally generated `Message-ID`
    /// (`<uuid@lagoon>`) so the caller can record it.
    public func send(
        _ outbound: OutboundMessage,
        host: String,
        port: Int,
        username: String,
        authCode: String
    ) async throws -> String? {
        let messageId = "<\(UUID().uuidString.lowercased())@lagoon>"
        let message = MIMEBuilder.reply(outbound, messageId: messageId)

        var attempt = 0
        while true {
            attempt += 1
            do {
                try await runSession(
                    outbound: outbound,
                    message: message,
                    host: host,
                    port: port,
                    username: username,
                    authCode: authCode
                )
                await transport.close()
                return messageId
            } catch let failure as SMTPFailure {
                // A failed session is never resumed: close first, reconnect in
                // the next attempt.
                await transport.close()
                guard failure.retryable, attempt == 1 else { throw failure.error }
                logger.warning(
                    "smtp.retry",
                    metadata: ["label": .string(failure.error.logLabel)]
                )
            }
        }
    }

    // MARK: - Session

    private func runSession(
        outbound: OutboundMessage,
        message: Data,
        host: String,
        port: Int,
        username: String,
        authCode: String
    ) async throws {
        try await perform(phase: .preData) {
            try await self.transport.connect(host: host, port: port)
        }

        try await expect(220, phase: .preData)  // greeting
        try await command("EHLO \(Self.clientName)", expecting: 250, phase: .preData)

        let credentials = Data("\0\(username)\0\(authCode)".utf8).base64EncodedString()
        try await command("AUTH PLAIN \(credentials)", expecting: 235, phase: .auth)

        try await command("MAIL FROM:<\(outbound.fromEmail)>", expecting: 250, phase: .preData)
        try await command("RCPT TO:<\(outbound.to)>", expecting: 250, phase: .preData)
        try await command("DATA", expecting: 354, phase: .preData)

        try await perform(phase: .postData) {
            try await self.transport.write(Self.dotStuffedForData(message))
        }
        try await expect(250, phase: .postData)
        try await command("QUIT", expecting: 221, phase: .postData)
    }

    private func command(_ line: String, expecting code: Int, phase: Phase) async throws {
        try await perform(phase: phase) {
            try await self.transport.write(Data("\(line)\r\n".utf8))
        }
        try await expect(code, phase: phase)
    }

    /// Reads one (possibly multi-line) reply and checks its status code.
    private func expect(_ expected: Int, phase: Phase) async throws {
        let code = try await readReply(phase: phase)
        guard code == expected else {
            logger.warning(
                "smtp.rejected",
                metadata: ["code": .string("\(code)"), "phase": .string("\(phase)")]
            )
            throw Self.failure(code: code, phase: phase)
        }
    }

    private func readReply(phase: Phase) async throws -> Int {
        while true {
            let line = try await perform(phase: phase) {
                try await self.transport.readLine()
            }
            guard line.count >= 3, let code = Int(line.prefix(3)) else {
                throw SMTPFailure(error: .protocolError("smtp-short-line"), retryable: phase != .postData)
            }
            // `250-...` continues the reply; `250 ...` or a bare `250` ends it.
            if line.count > 3, line[line.index(line.startIndex, offsetBy: 3)] == "-" { continue }
            return code
        }
    }

    /// The server's own explanation is intentionally not surfaced or logged (it
    /// can name the mailbox); the code is enough to map a user-facing hint.
    private static func failure(code: Int, phase: Phase) -> SMTPFailure {
        switch phase {
        case .auth:
            // A rejected AUTH is a credential verdict: stop retrying and ask
            // the user for a fresh authorization code (spec §3.4).
            if (400...499).contains(code) { return SMTPFailure(error: .unreachable("smtp-\(code)"), retryable: true) }
            return SMTPFailure(error: .authFailed, retryable: false)
        case .postData:
            // The payload is already on the wire; a retry could duplicate it.
            return SMTPFailure(error: .protocolError("smtp-data-\(code)"), retryable: false)
        case .preData:
            if (400...499).contains(code) {
                return SMTPFailure(error: .unreachable("smtp-\(code)"), retryable: true)
            }
            return SMTPFailure(error: .protocolError("smtp-\(code)"), retryable: false)
        }
    }

    /// Runs one transport operation, typing any error as an `SMTPFailure`.
    private func perform<T: Sendable>(
        phase: Phase,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        do {
            return try await withTimeout(phase: phase, operation)
        } catch let failure as SMTPFailure {
            throw failure
        } catch {
            let error = (error as? MailError) ?? .unreachable("smtp-transport")
            throw SMTPFailure(error: error, retryable: phase != .postData)
        }
    }

    /// Races one operation against `readTimeout`. Cancellation-safe: both
    /// production and test transports honour task cancellation.
    private func withTimeout<T: Sendable>(
        phase: Phase,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: self.readTimeout)
                throw StreamTransportError.timedOut
            }
            guard let result = try await group.next() else {
                throw StreamTransportError.timedOut
            }
            group.cancelAll()
            return result
        }
    }

    // MARK: - Payload

    /// Applies RFC 5321 §4.5.2 dot-stuffing and terminates the payload with
    /// `<CRLF>.<CRLF>`. A base64 body never starts a line with `.`, so the
    /// stuffing is a guard for bodies built by other callers, not a no-op
    /// assumption baked into the wire path.
    static func dotStuffedForData(_ payload: Data) -> Data {
        var text = String(decoding: payload, as: UTF8.self)
        if !text.hasSuffix("\r\n") { text += "\r\n" }
        let stuffed = text
            .components(separatedBy: "\r\n")
            .map { $0.hasPrefix(".") ? "." + $0 : $0 }
            .joined(separator: "\r\n")
        return Data((stuffed + ".\r\n").utf8)
    }
}
