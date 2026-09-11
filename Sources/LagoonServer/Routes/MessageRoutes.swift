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

    /// Raw request body bytes, capped so a hostile client cannot make the
    /// server buffer without bound. The caller maps a failure onto 400.
    static func collectBody(_ request: Request) async throws -> Data {
        let buffer = try await request.body.collect(upTo: 1 << 20)
        return Data(buffer: buffer)
    }
}

/// `POST /api/messages/{remoteId}/send` response.
struct SendResponse: Codable { let ok: Bool; let providerMessageId: String? }

/// Message-level M1 endpoints: full body, read state, pinning and AI summary.
public enum MessageRoutes {
    public static func register(
        on router: Router<BasicRequestContext>,
        db: PostgresConnection,
        client: GmailClient,
        tokens: GmailTokenService,
        logger: Logger,
        summarizer: (any MessageSummarizing)? = nil,
        makeProvider: MailProviderFactory.Builder? = nil
    ) {
        let makeProvider = makeProvider
            ?? MailProviderFactory.factory(client: client, tokens: tokens, db: db, logger: logger)

        // GET /api/messages/{remoteId}/body?accountId=<uuid>
        // 200 MessageBody | 400 malformed | 404 unknown | 410 message-gone
        // | 401 provider-auth-failed | 502 provider-unreachable
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
            guard let provider = makeProvider(account) else {
                return RouteJSON.error(.serviceUnavailable, "provider-not-configured")
            }
            do {
                let body = try await Self.fetchBody(
                    account: account,
                    remoteId: remoteId,
                    provider: provider,
                    db: db
                )
                return RouteJSON.response(body)
            } catch let error as MailError {
                return Self.providerError(error, logger: logger, remoteId: remoteId)
            } catch {
                logger.error("body fetch failed", metadata: [
                    "accountId": .string(accountId.uuidString),
                    "remoteId": .string(remoteId),
                    "err": .string("\(error)")
                ])
                return RouteJSON.error(.badGateway, "provider-unreachable")
            }
        }

        // POST /api/messages/{remoteId}/read?accountId=<uuid> -> 204
        // Local state is authoritative and never blocks on the network; the
        // remote `\Seen` write is best-effort (spec §3.7).
        router.post("api/messages/:remoteId/read") { request, context -> Response in
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
                logger.error("markRead lookup failed", metadata: [
                    "accountId": .string(accountId.uuidString),
                    "err": .string("\(error)")
                ])
                return RouteJSON.error(.internalServerError, "internal-error")
            }
            do {
                try await MessageStore.markRead(remoteId: remoteId, accountId: accountId, db: db)
            } catch {
                logger.error("markRead failed", metadata: [
                    "accountId": .string(accountId.uuidString),
                    "remoteId": .string(remoteId),
                    "err": .string("\(error)")
                ])
                return RouteJSON.error(.internalServerError, "internal-error")
            }
            if let provider = makeProvider(account) {
                do {
                    try await provider.setRead(remoteId: remoteId, isRead: true)
                } catch {
                    logger.warning("markRead.remoteFailed", metadata: [
                        "remoteId": .string(remoteId),
                        "label": .string(Self.providerLabel(error)),
                    ])
                }
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
                guard let provider = makeProvider(account) else {
                    return RouteJSON.error(.serviceUnavailable, "provider-not-configured")
                }
                body = try await Self.fetchBody(
                    account: account,
                    remoteId: remoteId,
                    provider: provider,
                    db: db
                )
            } catch let error as MailError {
                return Self.providerError(error, logger: logger, remoteId: remoteId)
            } catch {
                logger.error("summary body fetch failed", metadata: [
                    "accountId": .string(accountId.uuidString),
                    "remoteId": .string(remoteId),
                    "err": .string("\(error)")
                ])
                return RouteJSON.error(.badGateway, "provider-unreachable")
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

        // POST /api/messages/{remoteId}/send?accountId=<uuid>  {"body":"..."}
        // 200 SendResponse | 400 malformed-body | 404 unknown-message
        // | 401 smtp-auth-failed | 502 smtp-send-failed | 503 provider-not-configured
        router.post("api/messages/:remoteId/send") { request, context -> Response in
            return await Self.sendHandler(
                request: request, context: context, db: db,
                makeProvider: makeProvider, logger: logger
            )
        }
    }

    // MARK: - Send

    /// Send a plain-text reply to the message's sender. Everything the wire
    /// needs (recipient, subject, threading headers) comes from the synced
    /// row — the client only supplies the body, so it cannot redirect a reply.
    /// The `Re:` prefix and RFC 2047 encoding belong to `MIMEBuilder`, which
    /// both providers run.
    private static func sendHandler(
        request: Request,
        context: BasicRequestContext,
        db: PostgresConnection,
        makeProvider: MailProviderFactory.Builder,
        logger: Logger
    ) async -> Response {
        guard let accountId = RouteParams.accountId(from: request) else {
            return RouteJSON.error(.badRequest, "malformed-accountId")
        }
        guard let remoteId = RouteParams.remoteId(from: context) else {
            return RouteJSON.error(.badRequest, "malformed-remoteId")
        }
        let rawBody: Data
        do {
            rawBody = try await RouteParams.collectBody(request)
        } catch {
            return RouteJSON.error(.badRequest, "malformed-body")
        }
        struct SendRequest: Decodable { let body: String }
        guard let decoded = try? JSONDecoder().decode(SendRequest.self, from: rawBody),
              !decoded.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return RouteJSON.error(.badRequest, "malformed-body")
        }

        let account: Account
        do {
            guard let found = try await AccountStore.find(byId: accountId, db: db) else {
                return RouteJSON.error(.notFound, "unknown-account")
            }
            account = found
        } catch {
            logger.error("send account lookup failed", metadata: [
                "accountId": .string(accountId.uuidString),
                "err": .string("\(error)")
            ])
            return RouteJSON.error(.internalServerError, "internal-error")
        }
        let stored: MessageHeader
        do {
            guard let found = try await MessageStore.find(
                remoteId: remoteId, accountId: accountId, db: db
            ) else {
                return RouteJSON.error(.notFound, "unknown-message")
            }
            stored = found
        } catch {
            logger.error("send message lookup failed", metadata: [
                "accountId": .string(accountId.uuidString),
                "remoteId": .string(remoteId),
                "err": .string("\(error)")
            ])
            return RouteJSON.error(.internalServerError, "internal-error")
        }
        guard let provider = makeProvider(account) else {
            return RouteJSON.error(.serviceUnavailable, "provider-not-configured")
        }

        // Threading: reply to the parent's Message-ID and extend the parent's
        // chain with that id, so clients that only walk References still see
        // this reply as part of the thread.
        let references = [stored.references, stored.messageIdHeader]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let outbound = OutboundMessage(
            fromEmail: account.email,
            fromName: nil,
            to: stored.fromAddress,
            subject: stored.subject ?? "",
            body: decoded.body,
            inReplyTo: stored.messageIdHeader,
            references: references.isEmpty ? nil : references
        )

        let providerMessageId: String?
        do {
            providerMessageId = try await provider.send(outbound)
        } catch {
            return Self.sendError(error, logger: logger, remoteId: remoteId)
        }
        // The reply is already on the wire: a failed audit write must not turn
        // a delivered message into a 500 the client would retry.
        do {
            let _ = try await AIActionStore.record(
                accountId: accountId,
                kind: .send,
                payload: ["remoteId": remoteId, "to": stored.fromAddress],
                db: db
            )
        } catch {
            logger.warning("send.auditFailed", metadata: [
                "remoteId": .string(remoteId),
                "err": .string("\(error)")
            ])
        }
        return RouteJSON.response(SendResponse(ok: true, providerMessageId: providerMessageId))
    }

    /// Send failures get their own labels: the client tells "wrong auth code"
    /// apart from "mailbox unreachable" without seeing provider text.
    static func sendError(_ error: Error, logger: Logger, remoteId: String) -> Response {
        guard let mailError = error as? MailError else {
            logger.error("smtp.sendFailed", metadata: [
                "remoteId": .string(remoteId),
                "label": .string("\(type(of: error))"),
            ])
            return RouteJSON.error(.badGateway, "smtp-send-failed")
        }
        logger.warning("smtp.sendFailed", metadata: [
            "remoteId": .string(remoteId),
            "label": .string(mailError.logLabel),
        ])
        switch mailError {
        case .authFailed:
            return RouteJSON.error(.unauthorized, "smtp-auth-failed")
        case .notConfigured:
            return RouteJSON.error(.serviceUnavailable, "provider-not-configured")
        case .messageGone:
            return RouteJSON.error(.gone, "message-gone")
        case .unreachable, .protocolError, .archiveUnavailable:
            return RouteJSON.error(.badGateway, "smtp-send-failed")
        }
    }

    // MARK: - Body fetch (shared by /body and /summary)

    /// Fetch a full message through the account's provider and shape it as the
    /// shared `MessageBody` contract. Metadata comes from the synced row (best
    /// effort: a row that vanished still yields the body text).
    static func fetchBody(
        account: Account,
        remoteId: String,
        provider: any MailProvider,
        db: PostgresConnection
    ) async throws -> MessageBody {
        let text = try await provider.fetchBody(remoteId: remoteId)
        let stored = try? await MessageStore.find(remoteId: remoteId, accountId: account.id, db: db)
        return MessageBody(
            remoteId: remoteId,
            subject: stored?.subject,
            fromAddress: stored?.fromAddress ?? "",
            fromName: stored?.fromName,
            toAddress: nil,
            receivedAt: stored?.receivedAt ?? Date(),
            text: text
        )
    }

    /// Map a provider failure onto the route-level status. Only the stable
    /// label is logged; upstream text never reaches the client (spec §5.2).
    static func providerError(
        _ error: MailError,
        logger: Logger,
        remoteId: String
    ) -> Response {
        logger.warning("provider.requestFailed", metadata: [
            "remoteId": .string(remoteId),
            "label": .string(error.logLabel),
        ])
        switch error {
        case .messageGone:
            return RouteJSON.error(.gone, "message-gone")
        case .authFailed:
            return RouteJSON.error(.unauthorized, "provider-auth-failed")
        case .notConfigured:
            return RouteJSON.error(.serviceUnavailable, "provider-not-configured")
        case .archiveUnavailable:
            return RouteJSON.error(.conflict, "archive-unavailable")
        case .unreachable, .protocolError:
            return RouteJSON.error(.badGateway, "provider-unreachable")
        }
    }

    static func providerLabel(_ error: Error) -> String {
        (error as? MailError)?.logLabel ?? "\(type(of: error))"
    }
}
