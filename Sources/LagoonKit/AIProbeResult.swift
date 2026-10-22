import Foundation

/// What a 「测试连接」 actually learned.
///
/// ## Why this type exists
///
/// The button used to reload the configuration and read the resulting
/// status, which answered a different question: "can these settings be
/// parsed?". `configured` only ever meant "the key is a non-empty string
/// and the base URL parses as https" — so a revoked key, a wrong model
/// name and a base URL pointing at nothing all came back as a green
/// 「连接成功」.
///
/// The probe route really talks to the provider, and the answer has to
/// carry *which* failure happened: a 401 and a 404 and a timeout have
/// three different fixes, and one "failed" would make the user guess.
///
/// ## One list, two readers
///
/// The server encodes it and the client decodes it, so the type lives in
/// `LagoonKit` — the one module both sides depend on. A second copy of
/// the wire format would be free to drift, and the drift would show up as
/// a probe that always fails to parse.
public struct AIProbeResult: Codable, Sendable, Equatable {
    /// What the provider said.
    public enum Outcome: String, Codable, Sendable {
        /// The provider answered 2xx: the endpoint, the key and the model
        /// all work.
        case reachable
        /// 401 / 403 — the provider refused the key.
        case unauthorized
        /// 404 — there is no such endpoint (or no such model) there.
        case notFound
        /// 402 — the provider's own account is out of credit.
        case outOfCredit
        /// 429 — the provider is rate limiting.
        case rateLimited
        /// 400 and the other 4xx — the provider refused the request.
        case rejected
        /// 5xx — the provider failed on its own side.
        case providerError
        /// The provider answered, but not with a completion this client
        /// can read. The connection worked; the conversation did not.
        case unexpectedResponse
        /// The request timed out.
        case timedOut
        /// The provider could not be reached at all.
        case unreachable
        /// The endpoint answered with a redirect. Lagoon refuses to follow
        /// one — a redirect could hand the key to a host that was never
        /// allowed to see it.
        case redirected
        /// The settings cannot form a request at all: no key, or a base
        /// URL that is not an https URL with a host.
        case invalidSettings
        /// The service could not run the probe — its own provider config
        /// is missing or broken. Not the user's key.
        case serviceError
    }

    /// The verdict.
    public let outcome: Outcome
    /// The provider's HTTP status, when there was one.
    public let httpStatus: Int?
    /// A short, non-sensitive note for the log.
    ///
    /// Never the provider's response body: it can echo the key back, and
    /// the key must not end up in a log the user can read.
    public let detail: String?

    public init(outcome: Outcome, httpStatus: Int? = nil, detail: String? = nil) {
        self.outcome = outcome
        self.httpStatus = httpStatus
        self.detail = detail
    }

    /// Whether the provider answered the request.
    public var isSuccess: Bool { outcome == .reachable }
}
