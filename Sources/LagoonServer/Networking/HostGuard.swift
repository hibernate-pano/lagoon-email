import Foundation
import Hummingbird
import NIOCore

/// Loopback host names the local server accepts, and the normalization used to
/// compare a request's host against them.
public enum LoopbackHost {
    /// Names a legitimate local client may use. Any port is ignored.
    public static let allowedNames: Set<String> = ["127.0.0.1", "localhost", "::1"]

    /// "evil.com", "evil.com:8080", "[::1]:8080" and "::1" all normalize to
    /// a bare, lowercased host name (port and IPv6 brackets stripped).
    public static func normalize(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if value.hasPrefix("[") {
            guard let end = value.firstIndex(of: "]") else { return value }
            return String(value[value.index(after: value.startIndex)..<end])
        }
        // A bare IPv6 literal ("::1") carries several colons; only a single
        // colon means "host:port".
        guard value.filter({ $0 == ":" }).count == 1,
              let colon = value.firstIndex(of: ":")
        else { return value }
        return String(value[value.startIndex..<colon])
    }

    public static func isLoopback(
        _ raw: String,
        allowedNames: Set<String> = LoopbackHost.allowedNames
    ) -> Bool {
        allowedNames.contains(normalize(raw))
    }
}

/// Rejects requests whose host is not loopback.
///
/// M1 has no API authentication, so the server binds 127.0.0.1. A loopback
/// bind is not a security boundary on its own: a page in any browser on this
/// machine can be pointed at 127.0.0.1 by DNS rebinding, and the server would
/// answer with the user's synced mail. Browsers always send the
/// attacker-controlled hostname as the request authority, so validating it
/// closes that path. (A per-install bearer token is the M2 fix for
/// non-browser local callers.)
public struct LoopbackHostMiddleware<Context: RequestContext>: RouterMiddleware {
    public let allowedNames: Set<String>
    /// Reads the client-supplied host. HTTP/1.1 derives `authority` from the
    /// Host header and HTTP/2 from `:authority`; both surface as
    /// `request.head.authority`. Injectable so the reject path is testable
    /// (the in-process test framework hardcodes a localhost authority).
    public let host: @Sendable (Request) -> String?

    public init(
        allowedNames: Set<String> = LoopbackHost.allowedNames,
        host: @escaping @Sendable (Request) -> String? = { $0.head.authority }
    ) {
        self.allowedNames = allowedNames
        self.host = host
    }

    public func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        // Fail closed: a request with no host at all is not a legitimate
        // loopback client.
        guard let raw = host(request),
              LoopbackHost.isLoopback(raw, allowedNames: allowedNames)
        else {
            return Response(
                status: .forbidden,
                headers: [.contentType: "application/json; charset=utf-8"],
                body: .init(byteBuffer: ByteBuffer(string: #"{"error":"forbidden-host"}"#))
            )
        }
        return try await next(request, context)
    }
}
