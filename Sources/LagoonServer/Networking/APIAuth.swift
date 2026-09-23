import Foundation
import Hummingbird
import NIOCore

/// Per-install bearer token for `/api/*` (V2 A5).
///
/// The token comes from `LAGOON_API_TOKEN`. Unset/empty → the middleware is
/// open (legacy loopback posture, unchanged behavior). Set → every `/api/`
/// request needs `Authorization: Bearer <token>`; anything else gets 401
/// `api-unauthorized`. Non-API paths (health, OAuth browser flow, webhook —
/// which has its own secret) are never gated.
///
/// Deliberately one install token, not per-device credentials: rotation is
/// "change the env and restart both ends". Per-device pairing when iOS lands.
public struct APIAuthMiddleware<Context: RequestContext>: RouterMiddleware {
    /// `/api/` prefix (with slash, so `/apifoo` is not gated).
    public static var gatedPrefix: String { "/api/" }

    public let token: String?

    public init(token: String? = nil) {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.token = (trimmed?.isEmpty == false) ? trimmed : nil
    }

    /// Production convenience: reads the environment.
    public static func fromEnvironment() -> Self {
        Self(token: ProcessInfo.processInfo.environment["LAGOON_API_TOKEN"])
    }

    public func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        guard let token else {
            return try await next(request, context)
        }
        guard request.uri.path.hasPrefix(Self.gatedPrefix) else {
            return try await next(request, context)
        }
        guard Self.timingSafeEqual(request.headers[.authorization], "Bearer \(token)") else {
            return Response(
                status: .unauthorized,
                headers: [.contentType: "application/json; charset=utf-8"],
                body: .init(byteBuffer: ByteBuffer(string: #"{"error":"api-unauthorized"}"#))
            )
        }
        return try await next(request, context)
    }

    /// Constant-time string comparison so the 401 timing does not oracle the
    /// token prefix. Pure function, unit-tested below via the middleware.
    static func timingSafeEqual(_ lhs: String?, _ rhs: String) -> Bool {
        guard let lhs else { return false }
        let x = Array(lhs.utf8), y = Array(rhs.utf8)
        guard x.count == y.count else { return false }
        var diff = 0
        for (a, b) in zip(x, y) { diff |= Int(a ^ b) }
        return diff == 0
    }
}
