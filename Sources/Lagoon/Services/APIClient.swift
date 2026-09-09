import Foundation
import LagoonKit

/// Typed client-side API failures. Carries enough detail (status + body
/// snippet) that the UI can show something actionable.
extension Error {
    /// UI-facing text: the typed `APIError` message when we have one, otherwise
    /// Foundation's description. Views use this so failures name the cause.
    var lagoonUIMessage: String {
        (self as? APIError)?.localizedDescription ?? localizedDescription
    }
}

public enum APIError: LocalizedError, Sendable {
    case invalidURL(String)
    case invalidResponse
    case badStatus(code: Int, bodySnippet: String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let description):
            return "Invalid server URL: \(description)"
        case .invalidResponse:
            return "The server returned a non-HTTP response."
        case .badStatus(let code, let bodySnippet):
            return "Server returned HTTP \(code): \(bodySnippet)"
        }
    }
}

public final class APIClient: Sendable {
    public let baseURL: URL
    private let session: URLSession

    /// Base URL resolution: `LAGOON_SERVER_URL` if set and parseable, otherwise
    /// the M0 local default. The literal is known-good; `??` avoids a force unwrap.
    private static func resolvedBaseURL() -> URL {
        if let raw = ProcessInfo.processInfo.environment["LAGOON_SERVER_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty,
           let url = URL(string: raw),
           url.scheme != nil, url.host != nil {
            return url
        }
        return URL(string: "http://127.0.0.1:8080") ?? URL(fileURLWithPath: "/")
    }

    public init(baseURL: URL? = nil, session: URLSession? = nil) {
        self.baseURL = baseURL ?? Self.resolvedBaseURL()
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 10
            config.timeoutIntervalForResource = 30
            self.session = URLSession(configuration: config)
        }
    }

    /// Browser entry point for the OAuth dance. Used by ConnectGmailView.
    public var oauthStartURL: URL {
        baseURL.appendingPathComponent("oauth/gmail/start")
    }

    public func fetchMessages(accountId: UUID, limit: Int = 50) async throws -> SyncResponse {
        guard var c = URLComponents(url: baseURL.appendingPathComponent("api/messages"), resolvingAgainstBaseURL: false) else {
            throw APIError.invalidURL(baseURL.absoluteString + "/api/messages")
        }
        c.queryItems = [
            .init(name: "accountId", value: accountId.uuidString),
            .init(name: "limit", value: String(limit))
        ]
        guard let url = c.url else {
            throw APIError.invalidURL(baseURL.absoluteString + "/api/messages")
        }
        let (data, resp) = try await session.data(from: url)
        try Self.validate(resp, data: data)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(SyncResponse.self, from: data)
    }

    /// OAuth completion handshake (M0): polled by ConnectGmailView because the
    /// app is a bare SwiftPM executable and cannot register a URL scheme.
    public func fetchAccounts() async throws -> [ConnectedAccount] {
        let url = baseURL.appendingPathComponent("api/accounts")
        let (data, resp) = try await session.data(from: url)
        try Self.validate(resp, data: data)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode([ConnectedAccount].self, from: data)
    }

    // MARK: - M1 Briefing Feed

    /// GET /api/briefing?accountId=&limit= — every message the server could
    /// classify, tagged with its `BriefingGroup`.
    public func fetchBriefing(accountId: UUID, limit: Int = 100) async throws -> BriefingResponse {
        let url = try makeURL(path: ["api", "briefing"], query: [
            .init(name: "accountId", value: accountId.uuidString),
            .init(name: "limit", value: String(limit))
        ])
        let (data, resp) = try await session.data(from: url)
        try Self.validate(resp, data: data)
        return try Self.decode(BriefingResponse.self, from: data)
    }

    /// GET /api/messages/{gmailId}/body?accountId= — plain-text body (spec §3).
    public func fetchBody(gmailId: String, accountId: UUID) async throws -> MessageBody {
        let url = try makeURL(path: ["api", "messages", gmailId, "body"], query: [
            .init(name: "accountId", value: accountId.uuidString)
        ])
        let (data, resp) = try await session.data(from: url)
        try Self.validate(resp, data: data)
        return try Self.decode(MessageBody.self, from: data)
    }

    /// POST /api/messages/{gmailId}/read?accountId= → 204.
    public func markRead(gmailId: String, accountId: UUID) async throws {
        try await post(path: ["api", "messages", gmailId, "read"], query: [
            .init(name: "accountId", value: accountId.uuidString)
        ])
    }

    /// POST /api/messages/{gmailId}/pin?accountId=&pinned= → 204.
    public func setPinned(gmailId: String, accountId: UUID, pinned: Bool) async throws {
        try await post(path: ["api", "messages", gmailId, "pin"], query: [
            .init(name: "accountId", value: accountId.uuidString),
            .init(name: "pinned", value: pinned ? "true" : "false")
        ])
    }

    /// GET /api/messages/{gmailId}/summary?accountId=.
    ///
    /// When no LLM provider is configured the server answers 503; that surfaces
    /// as `APIError.badStatus(code: 503, …)` and the view renders the muted
    /// "AI 未配置" hint rather than a red error.
    public func fetchSummary(gmailId: String, accountId: UUID) async throws -> MessageSummary {
        let url = try makeURL(path: ["api", "messages", gmailId, "summary"], query: [
            .init(name: "accountId", value: accountId.uuidString)
        ])
        let (data, resp) = try await session.data(from: url)
        try Self.validate(resp, data: data)
        return try Self.decode(MessageSummary.self, from: data)
    }

    private func post(path: [String], query: [URLQueryItem]) async throws {
        let url = try makeURL(path: path, query: query)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let (data, resp) = try await session.data(for: request)
        try Self.validate(resp, data: data)
    }

    /// Builds a URL where every supplied path component is percent-encoded.
    /// Gmail ids are opaque and may contain `/`, `?` or `#`, which
    /// `appendingPathComponent` would leave in place and thus change the route.
    private func makeURL(path: [String], query: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw APIError.invalidURL(baseURL.absoluteString)
        }
        var encodedPath = components.percentEncodedPath
        if encodedPath.hasSuffix("/") { encodedPath.removeLast() }
        for component in path {
            encodedPath += "/" + Self.percentEncodedPathComponent(component)
        }
        components.percentEncodedPath = encodedPath
        components.queryItems = query
        guard let url = components.url else {
            throw APIError.invalidURL(baseURL.absoluteString + encodedPath)
        }
        return url
    }

    private static func percentEncodedPathComponent(_ raw: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")
        return raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }

    private static func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.badStatus(code: http.statusCode, bodySnippet: bodySnippet(from: data))
        }
    }

    private static func bodySnippet(from data: Data) -> String {
        let raw = String(decoding: data.prefix(200), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? "(empty body)" : raw
    }
}
