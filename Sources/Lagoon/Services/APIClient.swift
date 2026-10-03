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
        // Embedded runtime: the in-process server records the port it actually
        // bound (8080, or the next free port when 8080 was taken).
        let port = UserDefaults.standard.integer(forKey: "lagoon.serverPort")
        if port > 0 {
            return URL(string: "http://127.0.0.1:\(port)") ?? URL(fileURLWithPath: "/")
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

    /// The app-wide client. A `private let api = APIClient()` stored on a
    /// `View` re-runs its default initializer every time the parent
    /// re-renders the struct, so each render built a fresh `URLSession` —
    /// and a session that is immediately discarded strands its connections
    /// instead of draining them. Views must read this instead; the
    /// `init(baseURL:session:)` seam above stays for tests.
    public static let shared = APIClient()

    /// `sender` narrows to one exact `from_address` (发件人归集); nil keeps
    /// the unfiltered recent list. `archived = true` serves the 档案柜;
    /// `stackId` narrows to one user-defined 聚合规则.
    public func fetchMessages(
        accountId: UUID,
        limit: Int = 50,
        sender: String? = nil,
        archived: Bool = false,
        stackId: UUID? = nil
    ) async throws -> SyncResponse {
        guard var c = URLComponents(url: baseURL.appendingPathComponent("api/messages"), resolvingAgainstBaseURL: false) else {
            throw APIError.invalidURL(baseURL.absoluteString + "/api/messages")
        }
        var items: [URLQueryItem] = [
            .init(name: "accountId", value: accountId.uuidString),
            .init(name: "limit", value: String(limit)),
            .init(name: "archived", value: archived ? "true" : "false")
        ]
        if let sender {
            items.append(.init(name: "sender", value: sender))
        }
        if let stackId {
            items.append(.init(name: "stackId", value: stackId.uuidString))
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
        // back here, so bypass validation and handle non-2xx directly. The
        // bearer token still has to be stamped: this route lives behind the
        // same auth middleware as everything else under /api/.
        let (data, resp) = try await session.data(for: Self.authenticated(request))
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

    /// POST /api/messages/{remoteId}/delete?accountId= — 删除 = 移入服务器
    /// 废纸篓；响应形状与归档一致（{ok, remoteId, remote, actionId}）。
    public func deleteMessage(remoteId: String, accountId: UUID) async throws -> ArchiveResponse {
        let url = try makeURL(path: ["api", "messages", remoteId, "delete"], query: [
            .init(name: "accountId", value: accountId.uuidString)
        ])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = APITimeout.fast.seconds
        let (data, _) = try await send(request, timeout: .fast)
        return try Self.decode(ArchiveResponse.self, from: data)
    }

    /// POST /api/archive-bulk?accountId= — 清扫：远端逐封归档，逐项回报。
    public func archiveBulk(remoteIds: [String], accountId: UUID) async throws -> ArchiveBulkResponse {
        let url = try makeURL(path: ["api", "archive-bulk"], query: [
            .init(name: "accountId", value: accountId.uuidString)
        ])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = APITimeout.slow.seconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ArchiveBulkRequest(remoteIds: remoteIds))
        let (data, _) = try await send(request, timeout: .slow)
        return try Self.decode(ArchiveBulkResponse.self, from: data)
    }

    // MARK: - 聚合规则 (Stacks)

    public func fetchStacks(accountId: UUID) async throws -> StackRuleListResponse {
        let url = try makeURL(path: ["api", "stacks"], query: [
            .init(name: "accountId", value: accountId.uuidString)
        ])
        var request = URLRequest(url: url)
        request.timeoutInterval = APITimeout.fast.seconds
        let (data, _) = try await send(request, timeout: .fast)
        return try Self.decode(StackRuleListResponse.self, from: data)
    }

    public func createStack(_ req: StackCreateRequest, accountId: UUID) async throws -> StackCreateResponse {
        let url = try makeURL(path: ["api", "stacks"], query: [
            .init(name: "accountId", value: accountId.uuidString)
        ])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = APITimeout.fast.seconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(req)
        let (data, _) = try await send(request, timeout: .fast)
        return try Self.decode(StackCreateResponse.self, from: data)
    }

    public func deleteStack(id: UUID, accountId: UUID) async throws {
        let url = try makeURL(path: ["api", "stacks", id.uuidString], query: [
            .init(name: "accountId", value: accountId.uuidString)
        ])
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = APITimeout.fast.seconds
        _ = try await send(request, timeout: .fast)
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

    /// POST /api/drafts/{id}/choose {variant}.
    public func chooseDraft(draftId: Int64, variant: Int) async throws -> ChooseDraftResponse {
        let url = try makeURL(path: ["api", "drafts", "\(draftId)", "choose"], query: [])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["variant": variant]
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

    /// GET /api/advice?accountId=[&decision=][&limit=] → the suggestion queue.
    ///
    /// Read-only by contract (constitution §3): nothing in this call, and
    /// nothing in the type it returns, can change a message. `decision` omitted
    /// or blank asks for the pending queue, which is what the panel opens;
    /// `any` is the audit view.
    public func fetchAdvice(
        accountId: UUID,
        decision: AdviceDecisionQuery? = .pending,
        limit: Int = 200
    ) async throws -> [AdviceRecord] {
        var query = [URLQueryItem(name: "accountId", value: accountId.uuidString)]
        switch decision {
        case .none:
            break
        case .some(.pending):
            break
        case .some(.exactly(let value)):
            query.append(.init(name: "decision", value: value.rawValue))
        case .some(.all):
            query.append(.init(name: "decision", value: "any"))
        }
        query.append(.init(name: "limit", value: String(limit)))
        let url = try makeURL(path: ["api", "advice"], query: query)
        var request = URLRequest(url: url)
        request.timeoutInterval = APITimeout.fast.seconds
        let (data, _) = try await send(request, timeout: .fast)
        return try Self.decode(AdviceListResponse.self, from: data).advice
    }

    /// POST /api/advice/{id}/decision?accountId= `{decision}` → the stored verdict.
    ///
    /// The only write the advice surface has, and it writes the `advice` table
    /// only. It does not archive, delete, unsubscribe or send: recording a
    /// verdict is not performing the advice.
    public func setAdviceDecision(
        id: Int64,
        decision: AdviceDecision,
        accountId: UUID
    ) async throws -> AdviceDecisionResponse {
        let url = try makeURL(path: ["api", "advice", "\(id)", "decision"], query: [
            .init(name: "accountId", value: accountId.uuidString)
        ])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["decision": decision.rawValue])
        request.timeoutInterval = APITimeout.fast.seconds
        let (data, _) = try await send(request, timeout: .fast)
        return try Self.decode(AdviceDecisionResponse.self, from: data)
    }

    /// POST /api/messages/{remoteId}/read?accountId=[&isRead=] → 204.
    /// `isRead` defaults to true; pass false to mark unread.
    /// POST /api/messages/{remoteId}/read?accountId=[&isRead=false][&record=true]
    ///
    /// `record` is what separates a deliberate read/unread toggle from the
    /// implicit one that fires when a message is opened. The two are
    /// indistinguishable on the wire otherwise, and the server may only put
    /// deliberate ones in the undo log — otherwise ⌘Z would undo "you opened
    /// this mail". Returns 204 with no audit row when `record` is false (the
    /// implicit path, unchanged), or 200 with an `actionId` when it is true.
    @discardableResult
    public func markRead(
        remoteId: String, accountId: UUID, isRead: Bool = true, record: Bool = false
    ) async throws -> Int64? {
        var query = [URLQueryItem(name: "accountId", value: accountId.uuidString)]
        if !isRead { query.append(URLQueryItem(name: "isRead", value: "false")) }
        if record { query.append(URLQueryItem(name: "record", value: "true")) }
        let url = try makeURL(path: ["api", "messages", remoteId, "read"], query: query)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = APITimeout.fast.seconds
        let (data, _) = try await send(request, timeout: .fast)
        guard !data.isEmpty else { return nil }
        return try Self.decode(StateChangeResponse.self, from: data).actionId
    }

    /// POST /api/messages/{remoteId}/pin?accountId=&pinned= → 200 + actionId.
    /// A pin is always deliberate, so it always returns an undoable action.
    @discardableResult
    public func setPinned(
        remoteId: String, accountId: UUID, pinned: Bool
    ) async throws -> Int64? {
        let url = try makeURL(path: ["api", "messages", remoteId, "pin"], query: [
            .init(name: "accountId", value: accountId.uuidString),
            .init(name: "pinned", value: pinned ? "true" : "false")
        ])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = APITimeout.fast.seconds
        let (data, _) = try await send(request, timeout: .fast)
        return try Self.decode(StateChangeResponse.self, from: data).actionId
    }

    /// POST /api/actions/undo-bulk?accountId= → UndoBulkResponse.
    ///
    /// One ⌘Z for a bulk operation. "Mark all as read" records one action per
    /// message; undoing only the newest would leave the rest in place and read
    /// to the user as "undo did nothing". `.slow` because each inverse may
    /// perform a remote IMAP write and they run serially over one connection.
    public func undoBulk(actionIds: [Int64], accountId: UUID) async throws -> UndoBulkResponse {
        let url = try makeURL(path: ["api", "actions", "undo-bulk"], query: [
            .init(name: "accountId", value: accountId.uuidString)
        ])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = APITimeout.slow.seconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(UndoBulkRequest(actionIds: actionIds))
        let (data, _) = try await send(request, timeout: .slow)
        return try Self.decode(UndoBulkResponse.self, from: data)
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
    /// Remote ids are opaque and may contain `/`, `?` or `#`, which
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
        let request = Self.authenticated(request)
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

    /// Stamps the per-install bearer token on a request.
    ///
    /// Every path that reaches the network goes through here, and it is a
    /// separate function precisely so that stays true: `send` covers the
    /// ~30 methods that use it, and `downloadAttachment` — which has to skip
    /// `send`'s status validation to keep the raw headers — uses this one.
    /// When the attachment download carried no token, every attachment
    /// 401'd in the shipping app (the embedded server always has a token)
    /// and HTML `cid:` inline images silently broke.
    static func authenticated(_ request: URLRequest) -> URLRequest {
        var request = request
        if let token = apiToken, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
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
