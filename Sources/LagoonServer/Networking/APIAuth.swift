import Foundation
import Hummingbird
import NIOCore
import Crypto

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
    /// token. Comparing digests rather than the strings themselves is what
    /// makes it constant-time: a `count` check on the raw bytes returns
    /// early, which leaks the token's *length* — and the presented value's,
    /// since the header and the token are both attacker-influenced.
    static func timingSafeEqual(_ lhs: String?, _ rhs: String) -> Bool {
        guard let lhs else { return false }
        let a = SHA256.hash(data: Data(lhs.utf8))
        let b = SHA256.hash(data: Data(rhs.utf8))
        var diff = 0
        for (x, y) in zip(a, b) { diff |= Int(x ^ y) }
        return diff == 0
    }
}
