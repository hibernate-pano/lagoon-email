import Foundation
import Hummingbird
import NIOCore
import Logging

/// Route infrastructure shared by every file in `Routes/`.
///
/// This lives in its own file rather than in `MessageRoutes.swift`, where it
/// started, because nine route files depend on it. As long as it was a guest
/// in `MessageRoutes.swift` the dependency read backwards: opening
/// `StackRoutes` and grepping for `RouteJSON` pointed at an unrelated feature
/// file, and a newcomer had no way to tell that editing `MessageRoutes.swift`
/// could change the response envelope for every route in the server.
///
/// The two enums have opposite jobs and are deliberately kept apart:
///
/// * `RouteJSON` — how a response is serialised. One envelope shape for the
///   whole API, so the macOS client can decode `{"error":"<code>"}` without
///   per-route special cases.
/// * `RouteParams` — how untrusted input is parsed. Every value is either
///   converted to a typed value or bound as a SQL parameter; nothing here is
///   ever concatenated into SQL. That invariant is what `ci-guardrails.sh`
///   rule 1 enforces across the tree.

/// Response serialisation. Dates are ISO-8601 to match the macOS client's
/// `JSONDecoder.dateDecodingStrategy = .iso8601`.
enum RouteJSON {
    static func response<T: Encodable>(
        _ value: T,
        status: HTTPResponse.Status = .ok
    ) -> Response {
        guard let data = try? encode(value) else {
            return error(.internalServerError, "encoding-failed")
        }
        return Response(
            status: status,
            headers: [.contentType: "application/json; charset=utf-8"],
            body: .init(byteBuffer: ByteBuffer(data: data))
        )
    }

    /// Generic error envelope: `{"error":"<code>"}`. Error responses never echo
    /// upstream/provider text.
    static func error(_ status: HTTPResponse.Status, _ code: String) -> Response {
        let data = (try? JSONSerialization.data(withJSONObject: ["error": code]))
            ?? Data(#"{"error":"error"}"#.utf8)
        return Response(
            status: status,
            headers: [.contentType: "application/json; charset=utf-8"],
            body: .init(byteBuffer: ByteBuffer(data: data))
        )
    }

    /// Log a server-side failure and answer with the standard envelope.
    ///
    /// `label` is the domain name ("actions", "drafts") so a 500 still says
    /// which route produced it. This exists because two files carried a
    /// byte-for-byte identical copy of it, differing only in that string, and
    /// four more handlers answered 500 with no logging at all — a failed
    /// request left no trace anywhere, so a store error was indistinguishable
    /// from a client bug. The silent-catch lint only scans
    /// Sources/Lagoon/Views/, so nothing caught those.
    static func failure(
        _ status: HTTPResponse.Status,
        _ code: String,
        label: String,
        logger: Logger,
        failure: Error
    ) -> Response {
        logger.error("\(label).error", metadata: [
            "code": .string(code),
            "err": .string("\(failure)"),
        ])
        // Not `error(...)` unqualified: the parameter used to be named `error`,
        // which shadowed the static method and made this line a call into
        // `any Error`.
        return RouteJSON.error(status, code)
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }
}

/// Untrusted-input parsing.
enum RouteParams {
    /// `accountId` query parameter, validated as a UUID. nil when missing or
    /// malformed (caller answers 400).
    static func accountId(from request: Request) -> UUID? {
        guard let raw = request.uri.queryParameters["accountId"].map(String.init) else {
            return nil
        }
        return UUID(uuidString: raw)
    }

    /// First language tag of an `Accept-Language` header ("zh-CN,zh;q=0.9"
    /// -> "zh-CN"). nil when absent or blank, so the AI gateway keeps its
    /// configured default.
    static func preferredLanguage(fromHeader raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let first = raw.split(separator: ",").first.map(String.init) ?? raw
        let tag = first.split(separator: ";").first.map(String.init) ?? first
        let trimmed = tag.trimmingCharacters(in: .whitespaces)
        // Untrusted header: accept only a well-formed language tag
        // (letters/digits/dashes starting with a letter), never a stray
        // quality value or parameter fragment.
        guard !trimmed.isEmpty,
              trimmed.first?.isLetter == true,
              trimmed.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" })
        else { return nil }
        return trimmed
    }

    /// `remoteId` path component: percent-decoded, non-empty, treated as an
    /// opaque string. It is only ever passed to parameterized queries or
    /// percent-encoded into the message URL.
    static func remoteId(from context: BasicRequestContext) -> String? {
        guard let raw = context.parameters.get("remoteId"), !raw.isEmpty else { return nil }
        let decoded = raw.removingPercentEncoding ?? raw
        return decoded.isEmpty ? nil : decoded
    }

    /// Raw request body bytes, capped so a hostile client cannot make the
    /// server buffer without bound. The caller maps a failure onto 400.
    static func collectBody(_ request: Request) async throws -> Data {
        let buffer = try await request.body.collect(upTo: 1 << 20)
        return Data(buffer: buffer)
    }
}
