import Foundation
import LagoonKit
import os

/// Three tiers of request timeout (spec §5.1).
///
/// `.fast` (10s) is the common read/write path and auto-retries once on
/// transient transport / 5xx — covers the brief network blips that would
/// otherwise surface as red banners for no reason. `.interactive` (30s)
/// covers AI paths (summary, drafts, send) where the server legitimately
/// can take longer and a second attempt wouldn't help. `.slow` (75s) is
/// only used by the QQ connect probe, which does real IMAP work before
/// persisting — short-circuiting that path recreates the false-timeout
/// window M1.5 worked to close.
public enum APITimeout: Sendable {
    case fast
    case interactive
    case slow

    public var seconds: TimeInterval {
        switch self {
        case .fast: return 10
        case .interactive: return 30
        case .slow: return 75
        }
    }
}

/// Typed client-side API failures. The HTTP status + a stable error code
/// reach the UI; raw response bodies do not — server-side text is never
/// trusted to render verbatim (spec §5.5). `bodySnippet` is kept for typed
/// code extraction and `os.Logger` diagnostics only.
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
        case .badStatus(let code, _):
            return L10n.current.httpStatus(code)
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

    /// Per-install API token (V2 A5): `LAGOON_API_TOKEN` env wins, else the
    /// value stored by the settings UI. Nil/empty → no header (legacy server
    /// with auth unconfigured keeps working).

    /// Base URL resolution: `LAGOON_SERVER_URL` if set and parseable, otherwise
    /// the M0 local default. The literal is known-good; `??` avoids a force unwrap.
    static var apiToken: String? {
        if let raw = ProcessInfo.processInfo.environment["LAGOON_API_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return raw
        }
        let stored = UserDefaults.standard.string(forKey: "lagoon.apiToken")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (stored?.isEmpty == false) ? stored : nil
    }

    /// Persist the token entered in settings (env wins at runtime regardless).
    public static func storeAPIToken(_ token: String) {
        UserDefaults.standard.set(token, forKey: "lagoon.apiToken")
    }

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
            // Session-level ceilings are safety nets well above any
            // per-request timeout (`.slow` = 75s). Per-request values
            // (set by `send(_, timeout:)`) take precedence; this just
            // bounds runaway tasks.
            config.timeoutIntervalForRequest = 60
            config.timeoutIntervalForResource = 90
            self.session = URLSession(configuration: config)
        }
    }

    /// Browser entry point for the OAuth dance. Used by ConnectView.
    public var oauthStartURL: URL {
        baseURL.appendingPathComponent("oauth/gmail/start")
    }

    /// `sender` narrows to one exact `from_address` (发件人归集); nil keeps
    /// the unfiltered recent list.
    public func fetchMessages(accountId: UUID, limit: Int = 50, sender: String? = nil) async throws -> SyncResponse {
        guard var c = URLComponents(url: baseURL.appendingPathComponent("api/messages"), resolvingAgainstBaseURL: false) else {
            throw APIError.invalidURL(baseURL.absoluteString + "/api/messages")
        }
        var items: [URLQueryItem] = [
            .init(name: "accountId", value: accountId.uuidString),
            .init(name: "limit", value: String(limit))
        ]
        if let sender {
            items.append(.init(name: "sender", value: sender))
        }
        c.queryItems = items
        guard let url = c.url else {
            throw APIError.invalidURL(baseURL.absoluteString + "/api/messages")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = APITimeout.fast.seconds
        let (data, _) = try await send(request, timeout: .fast)
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
        var request = URLRequest(url: url)
        request.timeoutInterval = APITimeout.fast.seconds
        let (data, _) = try await send(request, timeout: .fast)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode([ConnectedAccount].self, from: data)
    }

    /// Global AI degraded signal for the banner (V2 C1). Best-effort:
    /// callers treat failure as "unknown", never as down.
    public func fetchAIStatus() async throws -> AIStatus {
        let url = baseURL.appendingPathComponent("api/ai-status")
        var request = URLRequest(url: url)
        request.timeoutInterval = APITimeout.fast.seconds
        let (data, _) = try await send(request, timeout: .fast)
        return try JSONDecoder().decode(AIStatus.self, from: data)
    }

    // MARK: - M1.6 attachments + raw message

    /// Download a single attachment's bytes. `accountId` is required even
    /// though the route only uses it for the server-side provider lookup,
    /// because the same `remoteId` is not unique across accounts. The bytes
    /// are written to the user-selected path by the caller; this method
    /// just returns the raw response body.
    public func downloadAttachment(
        accountId: UUID,
        remoteId: String,
        attachmentId: String
    ) async throws -> (data: Data, mimeType: String, filename: String?) {
        let url = try makeURL(
            path: ["api", "messages", remoteId, "attachments", attachmentId],
            query: [.init(name: "accountId", value: accountId.uuidString)]
        )
        var request = URLRequest(url: url)
        request.timeoutInterval = APITimeout.interactive.seconds
        // The attachment endpoint streams bytes — the `send` helper validates
        // 2xx and throws on non-2xx, but we want the raw Data and headers
        // back here, so bypass validation and handle non-2xx directly.
        let (data, resp) = try await session.data(for: request)
        guard let http = resp as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.badStatus(code: http.statusCode, bodySnippet: "")
        }
        let mimeType = http.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
        let filename = Self.filenameFromContentDisposition(
            http.value(forHTTPHeaderField: "Content-Disposition")
        )
        return (data, mimeType, filename)
    }

    /// Download the raw RFC 5322 bytes of a message (`.eml` export).
    public func downloadRawMessage(
        accountId: UUID,
        remoteId: String
    ) async throws -> Data {
        let url = try makeURL(
            path: ["api", "messages", remoteId, "raw.eml"],
            query: [.init(name: "accountId", value: accountId.uuidString)]
        )
        var request = URLRequest(url: url)
        request.timeoutInterval = APITimeout.interactive.seconds
        let (data, resp) = try await send(request, timeout: .interactive)
        _ = resp
        return data
    }

    /// Parse the `filename=` parameter out of a `Content-Disposition`
    /// header. We use this on the way out (after saving) to confirm the
    /// server's suggested filename when the user did not provide one.
    private static func filenameFromContentDisposition(_ header: String?) -> String? {
        guard let header else { return nil }
        for segment in header.split(separator: ";") {
            let trimmed = segment.trimmingCharacters(in: .whitespaces)
            let prefix = "filename="
            guard trimmed.lowercased().hasPrefix(prefix) else { continue }
            var value = String(trimmed.dropFirst(prefix.count))
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            return value.isEmpty ? nil : value
        }
        return nil
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
        // resolveArchiveFolder + selectInbox can take well over 10s on a cold
        // connection. `.slow` (75s) gives the probe room to finish; a retry
        // here would just race against the already-in-flight server probe.
        request.timeoutInterval = APITimeout.slow.seconds
        let body: [String: Any] = [
            "provider": MailProviderKind.qq.rawValue,
            "email": email,
            "authCode": authCode,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await send(request, timeout: .slow)
        return try Self.decode(ConnectedAccount.self, from: data)
    }

    /// POST /api/accounts/{id}/activate → 204. The server moves the single
    /// sync owner and puts every other mailbox to sleep.
    public func activateAccount(id: UUID) async throws {
        let url = try makeURL(path: ["api", "accounts", id.uuidString, "activate"], query: [])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = APITimeout.fast.seconds
        _ = try await send(request, timeout: .fast)
    }

    /// DELETE /api/accounts/{id} → 204. Foreign keys cascade to that account's
    /// messages, pins and drafts.
    public func deleteAccount(id: UUID) async throws {
        let url = try makeURL(path: ["api", "accounts", id.uuidString], query: [])
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = APITimeout.fast.seconds
        _ = try await send(request, timeout: .fast)
    }

    // MARK: - M1 Briefing Feed

    /// GET /api/briefing?accountId=&limit= — every message the server could
    /// classify, tagged with its `BriefingGroup`. `.interactive` because
    /// the briefing endpoint waits for AI classification on the first call
    /// after each sync, which can stretch past 10s.
    public func fetchBriefing(accountId: UUID, limit: Int = 100) async throws -> BriefingResponse {
        let url = try makeURL(path: ["api", "briefing"], query: [
            .init(name: "accountId", value: accountId.uuidString),
            .init(name: "limit", value: String(limit))
        ])
        var request = URLRequest(url: url)
        request.timeoutInterval = APITimeout.interactive.seconds
        let (data, _) = try await send(request, timeout: .interactive)
        return try Self.decode(BriefingResponse.self, from: data)
    }

    /// GET /api/messages/{remoteId}/body?accountId= — plain-text body (spec §3).
    /// `.fast` is fine because the route pool reuses an authenticated QQ
    /// connection; the first cold call may exceed 10s and trigger the
    /// auto-retry, which then hits the warm path.
    public func fetchBody(remoteId: String, accountId: UUID) async throws -> MessageBody {
        let url = try makeURL(path: ["api", "messages", remoteId, "body"], query: [
            .init(name: "accountId", value: accountId.uuidString)
        ])
        var request = URLRequest(url: url)
        request.timeoutInterval = APITimeout.fast.seconds
        let (data, _) = try await send(request, timeout: .fast)
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
        request.timeoutInterval = APITimeout.fast.seconds
        let (data, _) = try await send(request, timeout: .fast)
        return try Self.decode(ArchiveResponse.self, from: data)
    }

    /// POST /api/messages/{remoteId}/unsubscribe?accountId= → {ok, unsubscribed, publisher}.
    public func unsubscribeMessage(remoteId: String, accountId: UUID) async throws -> UnsubscribeResponse {
        let url = try makeURL(path: ["api", "messages", remoteId, "unsubscribe"], query: [
            .init(name: "accountId", value: accountId.uuidString)
        ])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = APITimeout.fast.seconds
        let (data, _) = try await send(request, timeout: .fast)
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
        request.timeoutInterval = APITimeout.fast.seconds
        _ = try await send(request, timeout: .fast)
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
        var request = URLRequest(url: url)
        request.timeoutInterval = APITimeout.fast.seconds
        let (data, _) = try await send(request, timeout: .fast)
        return try Self.decode(AIActionListResponse.self, from: data).actions
    }

    /// POST /api/actions/{id}/undo.
    public func undoAction(id: Int64, accountId: UUID) async throws {
        let url = try makeURL(path: ["api", "actions", "\(id)", "undo"], query: [
            .init(name: "accountId", value: accountId.uuidString)
        ])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = APITimeout.fast.seconds
        _ = try await send(request, timeout: .fast)
    }

    /// POST /api/messages/{remoteId}/send {body} → SendResponse.
    ///
    /// Recipient, subject and threading headers are taken from the stored
    /// message on the server; only the body travels from here. `.interactive`
    /// because the server waits for SMTP + (QQ) Sent APPEND before returning.
    /// - Parameters:
    ///   - to: Reply-all recipient override. nil means "reply to the stored
    ///     From only" and lets the server derive the envelope; a non-nil
    ///     array replaces the envelope entirely (the client computed it
    ///     from the body response's `to` + `cc` minus self).
    ///   - cc: Reply-all carbon-copy list. nil and `[]` are equivalent
    ///     (no `Cc:` header).
    public func sendReply(
        remoteId: String,
        accountId: UUID,
        body: String,
        requestId: String,
        to: [String]? = nil,
        cc: [String]? = nil
    ) async throws -> SendResponse {
        let url = try makeURL(path: ["api", "messages", remoteId, "send"], query: [
            .init(name: "accountId", value: accountId.uuidString)
        ])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = [
            "body": body,
            "requestId": requestId,
        ]
        if let to, !to.isEmpty { payload["to"] = to }
        if let cc, !cc.isEmpty { payload["cc"] = cc }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.timeoutInterval = APITimeout.interactive.seconds
        let (data, _) = try await send(request, timeout: .interactive)
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
        request.timeoutInterval = APITimeout.interactive.seconds
        let (data, _) = try await send(request, timeout: .interactive)
        return try Self.decode(SendResponse.self, from: data)
    }

    /// POST /api/messages/{remoteId}/draft → DraftReply. `.interactive`
    /// because the server runs LLM inference before responding.
    public func generateDrafts(remoteId: String, accountId: UUID, language: String? = nil) async throws -> DraftReply {
        let url = try makeURL(path: ["api", "messages", remoteId, "draft"], query: [
            .init(name: "accountId", value: accountId.uuidString)
        ])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if let language, !language.isEmpty {
            request.setValue(language, forHTTPHeaderField: "Accept-Language")
        }
        request.timeoutInterval = APITimeout.interactive.seconds
        let (data, _) = try await send(request, timeout: .interactive)
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
        request.timeoutInterval = APITimeout.fast.seconds
        let (data, _) = try await send(request, timeout: .fast)
        return try Self.decode(ChooseDraftResponse.self, from: data)
    }

    /// GET /api/search?q=&accountId=
    public func search(query: String, accountId: UUID) async throws -> [MessageHeader] {
        let url = try makeURL(path: ["api", "search"], query: [
            .init(name: "accountId", value: accountId.uuidString),
            .init(name: "q", value: query)
        ])
        var request = URLRequest(url: url)
        request.timeoutInterval = APITimeout.fast.seconds
        let (data, _) = try await send(request, timeout: .fast)
        return try Self.decode(SearchResponse.self, from: data).results
    }

    /// GET /api/usage → UsageReport. `.interactive` because the server
    /// fans out to LLM providers to aggregate token counts.
    public func fetchUsage() async throws -> UsageReport {
        let url = baseURL.appendingPathComponent("api/usage")
        var request = URLRequest(url: url)
        request.timeoutInterval = APITimeout.interactive.seconds
        let (data, _) = try await send(request, timeout: .interactive)
        return try Self.decode(UsageReport.self, from: data)
    }

    /// GET /api/time-saved?accountId= → TimeSavedReport (spec principle #3).
    /// Pure Postgres aggregation over the audit log, so `.fast` is enough.
    public func fetchTimeSaved(accountId: UUID) async throws -> TimeSavedReport {
        let url = try makeURL(path: ["api", "time-saved"], query: [
            .init(name: "accountId", value: accountId.uuidString)
        ])
        var request = URLRequest(url: url)
        request.timeoutInterval = APITimeout.fast.seconds
        let (data, _) = try await send(request, timeout: .fast)
        return try Self.decode(TimeSavedReport.self, from: data)
    }

    /// GET /api/auto-archive?accountId= → current whitelist autopilot rules.
    public func fetchAutoArchiveRules(accountId: UUID) async throws -> [AutoArchiveRule] {
        let url = try makeURL(path: ["api", "auto-archive"], query: [
            .init(name: "accountId", value: accountId.uuidString)
        ])
        var request = URLRequest(url: url)
        request.timeoutInterval = APITimeout.fast.seconds
        let (data, _) = try await send(request, timeout: .fast)
        return try Self.decode(AutoArchiveRuleListResponse.self, from: data).rules
    }

    /// POST /api/auto-archive?accountId= `{senderAddress}` → 201 rule.
    /// Idempotent server-side: recreating an existing rule returns that rule.
    public func addAutoArchiveRule(senderAddress: String, accountId: UUID) async throws -> AutoArchiveRule {
        let url = try makeURL(path: ["api", "auto-archive"], query: [
            .init(name: "accountId", value: accountId.uuidString)
        ])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["senderAddress": senderAddress])
        request.timeoutInterval = APITimeout.fast.seconds
        let (data, _) = try await send(request, timeout: .fast)
        return try Self.decode(AutoArchiveRule.self, from: data)
    }

    /// DELETE /api/auto-archive/{id}?accountId= → 204.
    public func deleteAutoArchiveRule(id: Int64, accountId: UUID) async throws {
        let url = try makeURL(path: ["api", "auto-archive", "\(id)"], query: [
            .init(name: "accountId", value: accountId.uuidString)
        ])
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = APITimeout.fast.seconds
        _ = try await send(request, timeout: .fast)
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
    /// "AI 未配置" hint rather than a red error. `.interactive` because the
    /// server blocks on LLM inference.
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
        request.timeoutInterval = APITimeout.interactive.seconds
        let (data, _) = try await send(request, timeout: .interactive)
        return try Self.decode(MessageSummary.self, from: data)
    }

    private func post(path: [String], query: [URLQueryItem], timeout: APITimeout = .fast) async throws {
        let url = try makeURL(path: path, query: query)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout.seconds
        _ = try await send(request, timeout: timeout)
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

    // MARK: - Per-request timeout + auto-retry

    /// `send` is the *only* place that both issues the request and
    /// validates the HTTP status, so the 5xx path can be observed by
    /// `shouldAutoRetry`. Validating in callers would leave 5xx invisible
    /// to the retry layer. Callers therefore receive the validated
    /// (Data, URLResponse) and skip their own `validate(...)` call.
    private func send(_ request: URLRequest, timeout: APITimeout) async throws -> (Data, URLResponse) {
        var request = request
        if let token = Self.apiToken, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let attempt: () async throws -> (Data, URLResponse) = {
            let (data, resp) = try await self.session.data(for: request)
            try Self.validate(resp, data: data)
            return (data, resp)
        }
        do {
            return try await attempt()
        } catch {
            guard timeout == .fast, Self.shouldAutoRetry(error) else { throw error }
            return try await attempt()
        }
    }

    private static func shouldAutoRetry(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return [
                .timedOut, .networkConnectionLost,
                .notConnectedToInternet, .dnsLookupFailed,
            ].contains(urlError.code)
        }
        if let apiError = error as? APIError,
           case .badStatus(let code, _) = apiError,
           (500...599).contains(code) {
            return true
        }
        return false
    }
}
