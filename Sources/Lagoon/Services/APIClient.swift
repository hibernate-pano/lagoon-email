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
            return L10n.current.invalidServerURL + description
        case .invalidResponse:
            return L10n.current.nonHTTPResponse
        case .badStatus(let code, let bodySnippet):
            return L10n.current.httpStatus(code) + bodySnippet
        }
    }

    /// Best-effort extraction of the server's error code from the
    /// `{"error":"<code>"}` envelope returned by `RouteJSON.error`.
    ///
    /// `bodySnippet` is capped at 200 bytes and the envelope is always far
    /// smaller, so parsing the snippet is safe. When the body is not the
    /// envelope (or was truncated) this returns nil and callers fall back to
    /// the numeric HTTP status.
    public var serverErrorCode: String? {
        guard case .badStatus(_, let bodySnippet) = self,
              let data = bodySnippet.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = object["error"] as? String,
              !code.isEmpty else {
            return nil
        }
        return code
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
            // Per-request inactivity still fails after 10s, but the resource cap
            // bounds the whole task. It must exceed the connect route's per-request
            // timeout (60s below) or a long IMAP probe would be killed early and
            // recreate the false-timeout window this fix is meant to close.
            config.timeoutIntervalForResource = 75
            self.session = URLSession(configuration: config)
        }
    }

    /// Browser entry point for the OAuth dance. Used by ConnectView.
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

    /// Ask the server sync loop to wake immediately.
    public func requestSync() async throws {
        try await post(path: ["api", "sync"], query: [])
    }

    /// OAuth completion handshake (M0): polled by ConnectView because the
    /// app is a bare SwiftPM executable and cannot register a URL scheme.
    public func fetchAccounts() async throws -> [ConnectedAccount] {
        let url = baseURL.appendingPathComponent("api/accounts")
        let (data, resp) = try await session.data(from: url)
        try Self.validate(resp, data: data)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode([ConnectedAccount].self, from: data)
    }

    // MARK: - M1.5 accounts (QQ/IMAP connect + activation)

    /// POST /api/accounts/imap {provider, email, authCode} → 201 ConnectedAccount.
    ///
    /// The auth code only ever travels request body → TLS → server; the response
    /// never echoes it. 401 means the provider rejected the code, 502 that the
    /// mailbox could not be reached, 409 that the account already exists.
    public func connectQQ(email: String, authCode: String) async throws -> ConnectedAccount {
        let url = try makeURL(path: ["api", "accounts", "imap"], query: [])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The server probes IMAP before persisting anything: TLS + LOGIN +
        // resolveArchiveFolder + selectInbox can exceed the 10s inactivity
        // default. This request-level timeout lifts the per-request ceiling to
        // 60s, and the session's `timeoutIntervalForResource` (75s) keeps the
        // whole task from being capped below it. Together they close the
        // false-timeout window where the client reports failure but the server
        // still writes the account.
        request.timeoutInterval = 60
        let body: [String: Any] = [
            "provider": MailProviderKind.qq.rawValue,
            "email": email,
            "authCode": authCode,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.data(for: request)
        try Self.validate(resp, data: data)
        return try Self.decode(ConnectedAccount.self, from: data)
    }

    /// POST /api/accounts/{id}/activate → 204. The server flips every other row
    /// inactive in the same statement.
    public func activateAccount(id: UUID) async throws {
        try await post(path: ["api", "accounts", id.uuidString, "activate"], query: [])
    }

    /// DELETE /api/accounts/{id} → 204. Foreign keys cascade to that account's
    /// messages, pins and drafts.
    public func deleteAccount(id: UUID) async throws {
        let url = try makeURL(path: ["api", "accounts", id.uuidString], query: [])
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        let (data, resp) = try await session.data(for: request)
        try Self.validate(resp, data: data)
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

    /// GET /api/messages/{remoteId}/body?accountId= — plain-text body (spec §3).
    public func fetchBody(remoteId: String, accountId: UUID) async throws -> MessageBody {
        let url = try makeURL(path: ["api", "messages", remoteId, "body"], query: [
            .init(name: "accountId", value: accountId.uuidString)
        ])
        var request = URLRequest(url: url)
        // The first body fetch may need a fresh QQ TLS + login round trip while
        // background IDLE is already connected. Ten seconds is too close to
        // that tail latency; once warm, the route pool reuses the session.
        request.timeoutInterval = 30
        let (data, resp) = try await session.data(for: request)
        try Self.validate(resp, data: data)
        return try Self.decode(MessageBody.self, from: data)
    }

    // MARK: - M2+ actions

    /// POST /api/messages/{remoteId}/archive?accountId= → {ok, remoteId, remote}.
    public func archiveMessage(remoteId: String, accountId: UUID) async throws -> ArchiveResponse {
        let url = try makeURL(path: ["api", "messages", remoteId, "archive"], query: [
            .init(name: "accountId", value: accountId.uuidString)
        ])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let (data, resp) = try await session.data(for: request)
        try Self.validate(resp, data: data)
        return try Self.decode(ArchiveResponse.self, from: data)
    }

    /// POST /api/messages/{remoteId}/unsubscribe?accountId= → {ok, unsubscribed, publisher}.
    public func unsubscribeMessage(remoteId: String, accountId: UUID) async throws -> UnsubscribeResponse {
        let url = try makeURL(path: ["api", "messages", remoteId, "unsubscribe"], query: [
            .init(name: "accountId", value: accountId.uuidString)
        ])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let (data, resp) = try await session.data(for: request)
        try Self.validate(resp, data: data)
        return try Self.decode(UnsubscribeResponse.self, from: data)
    }

    /// POST /api/messages/{remoteId}/classify {fromGroup,toGroup}.
    public func overrideClassification(
        remoteId: String,
        accountId: UUID,
        from: BriefingGroup?,
        to: BriefingGroup
    ) async throws {
        let url = try makeURL(path: ["api", "messages", remoteId, "classify"], query: [
            .init(name: "accountId", value: accountId.uuidString)
        ])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["toGroup": to.rawValue]
        if let from {
            body["fromGroup"] = from.rawValue
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.data(for: request)
        try Self.validate(resp, data: data)
    }

    /// GET /api/actions?accountId=&since=
    public func fetchActions(accountId: UUID, since: Date? = nil) async throws -> [AIAction] {
        var items: [URLQueryItem] = [.init(name: "accountId", value: accountId.uuidString)]
        if let since {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            items.append(.init(name: "since", value: f.string(from: since)))
        }
        let url = try makeURL(path: ["api", "actions"], query: items)
        let (data, resp) = try await session.data(from: url)
        try Self.validate(resp, data: data)
        return try Self.decode(AIActionListResponse.self, from: data).actions
    }

    /// POST /api/actions/{id}/undo.
    public func undoAction(id: Int64, accountId: UUID) async throws {
        let url = try makeURL(path: ["api", "actions", "\(id)", "undo"], query: [
            .init(name: "accountId", value: accountId.uuidString)
        ])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let (data, resp) = try await session.data(for: request)
        try Self.validate(resp, data: data)
    }

    /// POST /api/messages/{remoteId}/send {body} → SendResponse.
    ///
    /// Recipient, subject and threading headers are taken from the stored
    /// message on the server; only the body travels from here.
    public func sendReply(
        remoteId: String,
        accountId: UUID,
        body: String,
        requestId: String
    ) async throws -> SendResponse {
        let url = try makeURL(path: ["api", "messages", remoteId, "send"], query: [
            .init(name: "accountId", value: accountId.uuidString)
        ])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "body": body,
            "requestId": requestId,
        ])
        let (data, resp) = try await session.data(for: request)
        try Self.validate(resp, data: data)
        return try Self.decode(SendResponse.self, from: data)
    }

    /// POST /api/compose/send {to,subject,body,requestId} → SendResponse.
    public func sendNewMessage(
        to: String,
        subject: String,
        body: String,
        accountId: UUID,
        requestId: String
    ) async throws -> SendResponse {
        let url = try makeURL(path: ["api", "compose", "send"], query: [
            .init(name: "accountId", value: accountId.uuidString)
        ])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "to": to,
            "subject": subject,
            "body": body,
            "requestId": requestId,
        ])
        let (data, resp) = try await session.data(for: request)
        try Self.validate(resp, data: data)
        return try Self.decode(SendResponse.self, from: data)
    }

    /// POST /api/messages/{remoteId}/draft → DraftReply.
    public func generateDrafts(remoteId: String, accountId: UUID, language: String? = nil) async throws -> DraftReply {
        let url = try makeURL(path: ["api", "messages", remoteId, "draft"], query: [
            .init(name: "accountId", value: accountId.uuidString)
        ])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if let language, !language.isEmpty {
            request.setValue(language, forHTTPHeaderField: "Accept-Language")
        }
        let (data, resp) = try await session.data(for: request)
        try Self.validate(resp, data: data)
        return try Self.decode(DraftReply.self, from: data)
    }

    /// POST /api/drafts/{id}/choose {variant, pushToGmail}.
    public func chooseDraft(draftId: Int64, variant: Int, pushToGmail: Bool) async throws -> ChooseDraftResponse {
        let url = try makeURL(path: ["api", "drafts", "\(draftId)", "choose"], query: [])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["variant": variant, "pushToGmail": pushToGmail]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.data(for: request)
        try Self.validate(resp, data: data)
        return try Self.decode(ChooseDraftResponse.self, from: data)
    }

    /// GET /api/search?q=&accountId=
    public func search(query: String, accountId: UUID) async throws -> [MessageHeader] {
        let url = try makeURL(path: ["api", "search"], query: [
            .init(name: "accountId", value: accountId.uuidString),
            .init(name: "q", value: query)
        ])
        let (data, resp) = try await session.data(from: url)
        try Self.validate(resp, data: data)
        return try Self.decode(SearchResponse.self, from: data).results
    }

    /// GET /api/usage → UsageReport.
    public func fetchUsage() async throws -> UsageReport {
        let url = baseURL.appendingPathComponent("api/usage")
        let (data, resp) = try await session.data(from: url)
        try Self.validate(resp, data: data)
        return try Self.decode(UsageReport.self, from: data)
    }

    /// POST /api/messages/{remoteId}/read?accountId= → 204.
    public func markRead(remoteId: String, accountId: UUID) async throws {
        try await post(path: ["api", "messages", remoteId, "read"], query: [
            .init(name: "accountId", value: accountId.uuidString)
        ])
    }

    /// POST /api/messages/{remoteId}/pin?accountId=&pinned= → 204.
    public func setPinned(remoteId: String, accountId: UUID, pinned: Bool) async throws {
        try await post(path: ["api", "messages", remoteId, "pin"], query: [
            .init(name: "accountId", value: accountId.uuidString),
            .init(name: "pinned", value: pinned ? "true" : "false")
        ])
    }

    /// GET /api/messages/{remoteId}/summary?accountId=.
    ///
    /// When no LLM provider is configured the server answers 503; that surfaces
    /// as `APIError.badStatus(code: 503, …)` and the view renders the muted
    /// "AI 未配置" hint rather than a red error.
    /// - Parameter language: sent as `Accept-Language`, which is how the AI
    ///   summary follows the UI language. nil omits the header and lets the
    ///   server use its configured default.
    public func fetchSummary(
        remoteId: String,
        accountId: UUID,
        language: String? = nil
    ) async throws -> MessageSummary {
        let url = try makeURL(path: ["api", "messages", remoteId, "summary"], query: [
            .init(name: "accountId", value: accountId.uuidString)
        ])
        var request = URLRequest(url: url)
        if let language, !language.isEmpty {
            request.setValue(language, forHTTPHeaderField: "Accept-Language")
        }
        let (data, resp) = try await session.data(for: request)
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
