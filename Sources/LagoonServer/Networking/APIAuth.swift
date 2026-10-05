import Foundation
import Hummingbird
import NIOCore
import Crypto

/// Per-install bearer token for `/api/*` (V2 A5).
///
/// The token comes from `LAGOON_API_TOKEN`. Unset/empty → the middleware is
/// open (legacy loopback posture, unchanged behavior). Set → every request
/// needs `Authorization: Bearer <token>` EXCEPT the explicitly ungated
/// diagnostics path; anything else gets 401 `api-unauthorized`.
///
/// Gating is **fail-closed**: it skips only the paths listed in
/// `ungatedPaths` and gates everything else. The previous shape — "gate iff
/// `path.hasPrefix("/api/")`" — was fail-open against path spelling: the
/// router matches `//api/ping` to the `api/ping` handler, but that raw path
/// does not start with `/api/`, so the middleware waved it through and an
/// unauthenticated caller reached a gated route (probed: `//api/ping` → 200
/// while `/api/ping` → 401). Inverting the default means any spelling the
/// router can still match is gated unless it is exactly `/healthz`.
///
/// Deliberately one install token, not per-device credentials: rotation is
/// "change the env and restart both ends". Per-device pairing when iOS lands.
public struct APIAuthMiddleware<Context: RequestContext>: RouterMiddleware {
    /// Paths that stay reachable without a token. Exact-match on the raw
    /// request path, so a misspelling (`//healthz`) is gated, not skipped —
    /// the safe direction for a diagnostics endpoint.
    public static var ungatedPaths: Set<String> { ["/healthz"] }

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
        // Fail-closed: only the exact ungated diagnostics paths pass without
        // a token. Every other spelling — including router-matched variants
        // like `//api/ping` — must carry the bearer.
        guard !Self.ungatedPaths.contains(request.uri.path) else {
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
