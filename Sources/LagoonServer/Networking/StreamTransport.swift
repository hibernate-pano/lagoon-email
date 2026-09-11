import Foundation

/// A line-oriented byte stream shared by IMAP and SMTP. Tests inject a scripted
/// double; production uses `NIOSSLStreamTransport` (implicit TLS only).
public protocol StreamTransport: Sendable {
    func connect(host: String, port: Int) async throws
    func write(_ bytes: Data) async throws
    /// Reads one line and strips the trailing CRLF; throws `.closed` when the
    /// peer goes away.
    func readLine() async throws -> String
    /// Reads exactly `count` bytes (for `{N}` literals).
    func readExactly(_ count: Int) async throws -> Data
    func close() async
}

public enum StreamTransportError: Error, Equatable {
    case closed
    case notConnected
    case timedOut
}
