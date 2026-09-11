import Foundation
import Logging
import Hummingbird
import NIOCore
import PostgresNIO
import LagoonKit

/// Shared JSON response helpers for the M1 routes. Dates are ISO-8601 to match
/// the macOS client's `JSONDecoder.dateDecodingStrategy = .iso8601`.
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

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }
}

/// Untrusted-input helpers. Every value is either parsed into a typed value or
/// bound as a SQL parameter — nothing is ever concatenated into SQL.
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
    /// percent-encoded into the Gmail URL.
    static func remoteId(from context: BasicRequestContext) -> String? {
        guard let raw = context.parameters.get("remoteId"), !raw.isEmpty else { return nil }
        let decoded = raw.removingPercentEncoding ?? raw
        return decoded.isEmpty ? nil : decoded
    }
}

/// Message-level M1 endpoints: full body, read state, pinning and AI summary.
public enum MessageRoutes {
    public static func register(
        on router: Router<BasicRequestContext>,
        db: PostgresConnection,
        client: GmailClient,
        tokens: GmailTokenService,
        logger: Logger,
        summarizer: (any MessageSummarizing)? = nil
    ) {
        // GET /api/messages/{remoteId}/body?accountId=<uuid>
        // 200 MessageBody | 400 malformed | 404 unknown | 502 Gmail error
        router.get("api/messages/:remoteId/body") { request, context -> Response in
            guard let accountId = RouteParams.accountId(from: request) else {
                return RouteJSON.error(.badRequest, "malformed-accountId")
            }
            guard let remoteId = RouteParams.remoteId(from: context) else {
                return RouteJSON.error(.badRequest, "malformed-remoteId")
            }
            let account: Account
            do {
                guard let found = try await AccountStore.find(byId: accountId, db: db) else {
                    return RouteJSON.error(.notFound, "unknown-account")
                }
                account = found
            } catch {
                logger.error("account lookup failed", metadata: [
                    "accountId": .string(accountId.uuidString),
                    "err": .string("\(error)")
                ])
                return RouteJSON.error(.internalServerError, "internal-error")
            }
            do {
                let body = try await Self.fetchBody(
                    account: account,
                    remoteId: remoteId,
                    client: client,
                    tokens: tokens
                )
                return RouteJSON.response(body)
            } catch GmailClientError.http(let status, _) where status == 404 {
                return RouteJSON.error(.notFound, "unknown-message")
            } catch {
                logger.error("body fetch failed", metadata: [
                    "accountId": .string(accountId.uuidString),
                    "remoteId": .string(remoteId),
                    "err": .string("\(error)")
                ])
                return RouteJSON.error(.badGateway, "gmail-error")
            }
        }

        // POST /api/messages/{remoteId}/read?accountId=<uuid> -> 204
        router.post("api/messages/:remoteId/read") { request, context -> Response in
            guard let accountId = RouteParams.accountId(from: request) else {
                return RouteJSON.error(.badRequest, "malformed-accountId")
            }
            guard let remoteId = RouteParams.remoteId(from: context) else {
                return RouteJSON.error(.badRequest, "malformed-remoteId")
            }
            do {
                guard try await AccountStore.find(byId: accountId, db: db) != nil else {
                    return RouteJSON.error(.notFound, "unknown-account")
                }
                try await MessageStore.markRead(remoteId: remoteId, accountId: accountId, db: db)
            } catch {
                logger.error("markRead failed", metadata: [
                    "accountId": .string(accountId.uuidString),
                    "remoteId": .string(remoteId),
                    "err": .string("\(error)")
                ])
                return RouteJSON.error(.internalServerError, "internal-error")
            }
            return Response(status: .noContent)
        }

        // POST /api/messages/{remoteId}/pin?accountId=<uuid>&pinned=true|false -> 204
        router.post("api/messages/:remoteId/pin") { request, context -> Response in
            guard let accountId = RouteParams.accountId(from: request) else {
                return RouteJSON.error(.badRequest, "malformed-accountId")
            }
            guard let remoteId = RouteParams.remoteId(from: context) else {
                return RouteJSON.error(.badRequest, "malformed-remoteId")
            }
            guard let rawPinned = request.uri.queryParameters["pinned"].map(String.init) else {
                return RouteJSON.error(.badRequest, "malformed-pinned")
            }
            let pinned: Bool
            switch rawPinned.lowercased() {
            case "true": pinned = true
            case "false": pinned = false
            default: return RouteJSON.error(.badRequest, "malformed-pinned")
            }
            do {
                // Validate the account first: without this a pin for an unknown
                // account hit the message_pins FK and surfaced as a 500.
                guard try await AccountStore.find(byId: accountId, db: db) != nil else {
                    return RouteJSON.error(.notFound, "unknown-account")
                }
                try await MessageStore.setPinned(
                    pinned,
                    remoteId: remoteId,
                    accountId: accountId,
                    db: db
                )
            } catch {
                logger.error("setPinned failed", metadata: [
                    "accountId": .string(accountId.uuidString),
                    "remoteId": .string(remoteId),
                    "err": .string("\(error)")
                ])
                return RouteJSON.error(.internalServerError, "internal-error")
            }
            return Response(status: .noContent)
        }

        // GET /api/messages/{remoteId}/summary?accountId=<uuid>
        // 200 MessageSummary | 503 {"error":"ai-not-configured"} | 502 AI error
        router.get("api/messages/:remoteId/summary") { request, context -> Response in
            guard let accountId = RouteParams.accountId(from: request) else {
                return RouteJSON.error(.badRequest, "malformed-accountId")
            }
            guard let remoteId = RouteParams.remoteId(from: context) else {
                return RouteJSON.error(.badRequest, "malformed-remoteId")
            }
            guard let summarizer else {
                return RouteJSON.error(.serviceUnavailable, "ai-not-configured")
            }
            let account: Account
            do {
                guard let found = try await AccountStore.find(byId: accountId, db: db) else {
                    return RouteJSON.error(.notFound, "unknown-account")
                }
                account = found
            } catch {
                logger.error("account lookup failed", metadata: [
                    "accountId": .string(accountId.uuidString),
                    "err": .string("\(error)")
                ])
                return RouteJSON.error(.internalServerError, "internal-error")
            }
            let body: MessageBody
            do {
                body = try await Self.fetchBody(
                    account: account,
                    remoteId: remoteId,
                    client: client,
                    tokens: tokens
                )
            } catch GmailClientError.http(let status, _) where status == 404 {
                return RouteJSON.error(.notFound, "unknown-message")
            } catch {
                logger.error("summary body fetch failed", metadata: [
                    "accountId": .string(accountId.uuidString),
                    "remoteId": .string(remoteId),
                    "err": .string("\(error)")
                ])
                return RouteJSON.error(.badGateway, "gmail-error")
            }
            do {
                let result = try await summarizer.summarize(
                    body,
                    language: RouteParams.preferredLanguage(fromHeader: request.headers[.acceptLanguage]),
                    accountEmail: account.email
                )
                // Normalize the id to the requested message and never pass the
                // provider's raw error text back to the client.
                let summary = MessageSummary(
                    remoteId: body.remoteId,
                    summary: result.summary,
                    actionItems: result.actionItems,
                    provider: result.provider
                )
                return RouteJSON.response(summary)
            } catch {
                logger.error("summarizer failed", metadata: [
                    "accountId": .string(accountId.uuidString),
                    "remoteId": .string(remoteId),
                    "err": .string("\(error)")
                ])
                return RouteJSON.error(.badGateway, "ai-error")
            }
        }
    }

    // MARK: - Body fetch (shared by /body and /summary)

    /// Fetch a full message and turn it into the shared `MessageBody`. A 401 is
    /// retried once with a forced refresh (unless this call already refreshed).
    static func fetchBody(
        account: Account,
        remoteId: String,
        client: GmailClient,
        tokens: GmailTokenService
    ) async throws -> MessageBody {
        let token = try await tokens.validToken(for: account)
        let raw: RawGmailMessage
        do {
            raw = try await client.getMessageFull(accessToken: token.accessToken, remoteId: remoteId)
        } catch GmailClientError.unauthorized {
            guard !token.didRefresh else { throw GmailClientError.unauthorized }
            let refreshed = try await tokens.forceRefresh(for: account)
            raw = try await client.getMessageFull(accessToken: refreshed, remoteId: remoteId)
        }
        return messageBody(from: raw, fallbackGmailId: remoteId)
    }

    /// Map a raw Gmail full response onto the shared `MessageBody` contract.
    static func messageBody(from raw: RawGmailMessage, fallbackGmailId: String) -> MessageBody {
        func header(_ name: String) -> String? {
            raw.payload?.headers?.first { $0.name.lowercased() == name }?.value
        }
        let (fromAddress, fromName) = FromHeader.parse(header("from") ?? "")
        let receivedAt = raw.internalDate.flatMap { Int64($0) }
            .map { Date(timeIntervalSince1970: TimeInterval($0) / 1000.0) } ?? Date()
        return MessageBody(
            remoteId: raw.id.isEmpty ? fallbackGmailId : raw.id,
            subject: header("subject"),
            fromAddress: fromAddress,
            fromName: fromName,
            toAddress: header("to"),
            receivedAt: receivedAt,
            text: GmailBodyExtractor.plainText(from: raw.payload)
        )
    }
}
