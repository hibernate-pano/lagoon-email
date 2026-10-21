import Foundation
import Logging
import Hummingbird
import NIOCore
import GRDB
import LagoonKit
import LagoonAI

/// `POST /api/messages/{remoteId}/send` response.
struct SendResponse: Codable { let ok: Bool; let providerMessageId: String? }

/// One attachment in a compose request.
///
/// The bytes travel as base64 because JSON has no byte type; the name and
/// the MIME type travel as plain strings. All three are remote-controlled
/// as far as the server is concerned, and each is handled where it can do
/// damage: the name and the type end up in MIME headers (so `MIMEBuilder`
/// sanitises them), and the bytes are only ever written into the encoded
/// body.
struct ComposeAttachmentPayload: Codable, Sendable {
    let filename: String
    let mimeType: String
    let dataBase64: String
}

/// What a send request may do next, decided by the claim it took (or did
/// not get).
private enum SendPermit {
    /// Send the mail. `claimRowId` is the claim row to complete when the
    /// mail is on the wire, or to release when it is not; nil when the
    /// client sent no idempotency key, in which case there is no claim
    /// and the audit row is written after the send, as it always was.
    case proceed(claimRowId: Int64?)
    /// The mail already went out under this idempotency key: replay the
    /// stored result instead of sending it a second time.
    case replay(providerMessageId: String?)
    /// Another request holds this idempotency key and is still sending.
    case conflict
}

/// Message-level M1 endpoints: full body, read state, pinning and AI summary.
public enum MessageRoutes {
    public static func register(
        on router: Router<BasicRequestContext>,
        db: LagoonDB,
        logger: Logger,
        summarizer: (any MessageSummarizing)? = nil,
        makeProvider: MailProviderFactory.Builder? = nil
    ) {
        let makeProvider = makeProvider
            ?? MailProviderFactory.factory(db: db, logger: logger).builder

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
                    db: db,
                    logger: logger
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

        // GET /api/messages/{remoteId}/attachments/{attachmentId}?accountId=<uuid>
        // 200 application/octet-stream | 404 attachment-not-found | 413 too-large
        router.get("api/messages/:remoteId/attachments/:attachmentId") { request, context -> Response in
            guard let accountId = RouteParams.accountId(from: request) else {
                return RouteJSON.error(.badRequest, "malformed-accountId")
            }
            guard let remoteId = RouteParams.remoteId(from: context) else {
                return RouteJSON.error(.badRequest, "malformed-remoteId")
            }
            guard let attachmentId = context.parameters.get("attachmentId"),
                  !attachmentId.isEmpty else {
                return RouteJSON.error(.badRequest, "malformed-attachmentId")
            }
            let account: Account
            do {
                guard let found = try await AccountStore.find(byId: accountId, db: db) else {
                    return RouteJSON.error(.notFound, "unknown-account")
                }
                account = found
            } catch {
                return RouteJSON.failure(
                    .internalServerError, "internal-error",
                    label: "messages", logger: logger, failure: error
                )
            }
            guard let provider = makeProvider(account) else {
                return RouteJSON.error(.serviceUnavailable, "provider-not-configured")
            }
            return await downloadAttachment(
                account: account,
                remoteId: remoteId,
                attachmentId: attachmentId,
                provider: provider,
                logger: logger
            )
        }

        // GET /api/messages/{remoteId}/raw.eml?accountId=<uuid>
        // 200 message/rfc822 | 4xx
        router.get("api/messages/:remoteId/raw.eml") { request, context -> Response in
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
                return RouteJSON.failure(
                    .internalServerError, "internal-error",
                    label: "messages", logger: logger, failure: error
                )
            }
            guard let provider = makeProvider(account) else {
                return RouteJSON.error(.serviceUnavailable, "provider-not-configured")
            }
            return await downloadRawMessage(
                account: account,
                remoteId: remoteId,
                provider: provider,
                // Best-effort: an unsynced row just falls back to a generic
                // name. One local read, no second round trip to the server.
                subject: try? await MessageStore.find(
                    remoteId: remoteId, accountId: account.id, db: db
                )?.subject,
                logger: logger
            )
        }

        // POST /api/messages/{remoteId}/read?accountId=<uuid>[&isRead=false] -> 204
        // Local state is authoritative and never blocks on the network; the
        // remote `\Seen` write is best-effort (spec §3.7). `isRead` defaults
        // to true so every existing caller keeps working; `isRead=false`
        // clears `\Seen` remotely AND locally — the store's monotonic OR is
        // bypassed with a direct write, the same shape the undo route uses.
        router.post("api/messages/:remoteId/read") { request, context -> Response in
            guard let accountId = RouteParams.accountId(from: request) else {
                return RouteJSON.error(.badRequest, "malformed-accountId")
            }
            guard let remoteId = RouteParams.remoteId(from: context) else {
                return RouteJSON.error(.badRequest, "malformed-remoteId")
            }
            let isRead: Bool
            if let raw = request.uri.queryParameters["isRead"].map(String.init) {
                switch raw.lowercased() {
                case "true", "1", "yes": isRead = true
                case "false", "0", "no": isRead = false
                default: return RouteJSON.error(.badRequest, "malformed-isRead")
                }
            } else {
                isRead = true
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
            // `record=true` marks this as a *deliberate* read/unread toggle
            // rather than a side effect of opening the message. The two are
            // indistinguishable on the wire otherwise: the implicit path posts
            // `isRead=true` and so does an explicit "mark as read", so without
            // this flag every message the user merely opened would enter the
            // undo log — and ⌘Z would then undo "you opened this mail", which
            // is both wrong and noisy enough that the user would stop trusting
            // undo. Opening a message is not an action to take back.
            let record = request.uri.queryParameters["record"].map(String.init)
                .map { ["true", "1", "yes"].contains($0.lowercased()) } ?? false

            let actionId: Int64?
            do {
                // The previous value and the audit row land in one transaction:
                // an action whose payload disagrees with the row it describes
                // would undo to the wrong state.
                actionId = try db.write { raw -> Int64? in
                    let previous = try MessageStore.setReadSync(
                        remoteId: remoteId, accountId: accountId, isRead: isRead, db: raw
                    )
                    guard record else { return nil }
                    // No header row means there is nothing to undo: the UPDATE
                    // matched nothing, so an audit row would describe a state
                    // change that never happened and its inverse would silently
                    // do nothing too.
                    guard previous != nil else { return nil }
                    let action = try AIActionStore.recordSync(
                        accountId: accountId,
                        kind: .markRead,
                        payload: [
                            "remoteId": remoteId,
                            // Undo restores THIS, not a hardcoded false: marking
                            // a read mail unread is a real action whose inverse
                            // is "read again".
                            "previousIsRead": previous == true ? "true" : "false",
                        ],
                        db: raw
                    )
                    return action.id
                }
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
                    try await provider.setRead(remoteId: remoteId, isRead: isRead)
                } catch {
                    logger.warning("markRead.remoteFailed", metadata: [
                        "remoteId": .string(remoteId),
                        "label": .string(Self.providerLabel(error)),
                    ])
                }
            }
            // Unchanged 204 for callers that did not ask for an audit row, so
            // the implicit "opened a message" path keeps its existing contract.
            guard record else { return Response(status: .noContent) }
            return RouteJSON.response(StateChangeResponse(
                ok: true, remoteId: remoteId, actionId: actionId
            ))
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
            let actionId: Int64?
            do {
                // Validate the account first: without this a pin for an unknown
                // account hit the message_pins FK and surfaced as a 500.
                guard try await AccountStore.find(byId: accountId, db: db) != nil else {
                    return RouteJSON.error(.notFound, "unknown-account")
                }
                // A pin is always a deliberate user action — unlike mark-read
                // there is no implicit path that flips it — so it always joins
                // the undo log. `.pin`/`.unpin` are separate kinds because
                // reverse() has to know which direction to undo toward; the
                // flag itself is not enough (unpinning an already-unpinned
                // message must not "undo" into a pin).
                actionId = try db.write { raw -> Int64? in
                    try MessageStore.setPinnedSync(
                        pinned, remoteId: remoteId, accountId: accountId, db: raw
                    )
                    let action = try AIActionStore.recordSync(
                        accountId: accountId,
                        kind: pinned ? .pin : .unpin,
                        payload: ["remoteId": remoteId],
                        db: raw
                    )
                    return action.id
                }
            } catch {
                logger.error("setPinned failed", metadata: [
                    "accountId": .string(accountId.uuidString),
                    "remoteId": .string(remoteId),
                    "err": .string("\(error)")
                ])
                return RouteJSON.error(.internalServerError, "internal-error")
            }
            return RouteJSON.response(StateChangeResponse(
                ok: true, remoteId: remoteId, actionId: actionId
            ))
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
                    db: db,
                    logger: logger
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
            } catch let llmError as LLMError where llmError.code == "insufficient-credit" {
                logger.warning("summarizer.outOfCredit", metadata: [
                    "accountId": .string(accountId.uuidString),
                    "remoteId": .string(remoteId),
                ])
                return RouteJSON.error(.serviceUnavailable, "ai-credit-exhausted")
            } catch let llmError as LLMError where llmError.code == "budget-exceeded" {
                // Deliberately not logged here: `AIGateway` already records
                // `llm.budget.preCheckFailed` at error level with the
                // account and the cap, so a second line would be noise for
                // an expected, self-explaining state.
                return RouteJSON.error(.serviceUnavailable, "ai-budget-exceeded")
            } catch let llmError as LLMError where llmError.code == "circuit-open" {
                // An open breaker means the provider was returning a 5xx
                // storm. This was the one degradation path that left no
                // trace anywhere — the client saw "AI unavailable" and the
                // server recorded nothing about why.
                logger.warning("summarizer.circuitOpen", metadata: [
                    "accountId": .string(accountId.uuidString),
                    "remoteId": .string(remoteId),
                    "detail": .string(llmError.localizedDescription),
                ])
                return RouteJSON.error(.serviceUnavailable, "ai-circuit-open")
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

        // POST /api/compose/send?accountId=<uuid>
        // 200 SendResponse | 400 malformed-compose
        // | 401 smtp-auth-failed | 502 smtp-send-failed | 503 provider-not-configured
        router.post("api/compose/send") { request, _ -> Response in
            return await Self.composeHandler(
                request: request,
                db: db,
                makeProvider: makeProvider,
                logger: logger
            )
        }

        // POST /api/messages/{remoteId}/forward?accountId=<uuid>
        // 200 SendResponse | 400 malformed-forward | 404 unknown-message
        // | 409 forward-too-large | 401 smtp-auth-failed | 502 smtp-send-failed
        router.post("api/messages/:remoteId/forward") { request, context -> Response in
            return await Self.forwardHandler(
                request: request, context: context, db: db,
                makeProvider: makeProvider, logger: logger
            )
        }
    }

    // MARK: - Send

    private static func composeHandler(
        request: Request,
        db: LagoonDB,
        makeProvider: MailProviderFactory.Builder,
        logger: Logger
    ) async -> Response {
        guard let accountId = RouteParams.accountId(from: request) else {
            return RouteJSON.error(.badRequest, "malformed-accountId")
        }
        let rawBody: Data
        do {
            // The attachment-sized cap: this is the one endpoint that may
            // carry files, and 1 MB would refuse a perfectly ordinary
            // attachment before the user ever got to see why.
            rawBody = try await RouteParams.collectAttachmentBody(request)
        } catch {
            return RouteJSON.error(.badRequest, "malformed-compose")
        }
        struct ComposeRequest: Decodable {
            let to: String
            let subject: String
            let body: String
            let requestId: String?
            /// Carbon-copy recipients. Optional so an older client that only
            /// knows `to` still works.
            let cc: [String]?
            /// Blind carbon-copy recipients. Optional for the same reason.
            let bcc: [String]?
            /// Files to attach. Optional for the same reason.
            let attachments: [ComposeAttachmentPayload]?
        }
        guard let decoded = try? JSONDecoder().decode(ComposeRequest.self, from: rawBody)
        else {
            return RouteJSON.error(.badRequest, "malformed-compose")
        }
        let to = decoded.to.trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = decoded.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = decoded.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !subject.containsHeaderInjection, !body.isEmpty else {
            return RouteJSON.error(.badRequest, "malformed-compose")
        }
        // The To field is a **list**: one address per recipient, separated
        // by commas. It used to be one address, and two addresses came back
        // as `malformed-compose` — the user typed a perfectly ordinary
        // "one@example.com, two@example.com" and got a 400 with nothing to
        // act on.
        //
        // Each entry is validated on its own, and one bad address refuses
        // the whole request rather than being dropped: a silently missing
        // recipient is a mail that went to fewer people than the user
        // asked, and nothing in the UI would say so.
        let toAddresses = Self.recipientList(from: to)
        guard let toAddresses, !toAddresses.isEmpty else {
            return RouteJSON.error(.badRequest, "malformed-recipient")
        }
        // Cc and Bcc are lists, and each entry is validated on its own: one
        // bad address must not invalidate the good ones, and it must not be
        // silently dropped either. The list is rejected as a whole, with a
        // distinct code, so the client can say "that address is not valid"
        // instead of "the send failed".
        let cc = Self.recipientList(decoded.cc)
        let bcc = Self.recipientList(decoded.bcc)
        guard cc != nil, bcc != nil else {
            return RouteJSON.error(.badRequest, "malformed-recipient")
        }
        let attachments = Self.decodeAttachments(decoded.attachments)
        guard attachments != nil else {
            return RouteJSON.error(.badRequest, "malformed-attachment")
        }
        let ccAddresses = cc ?? []
        let bccAddresses = bcc ?? []
        let outboundAttachments = attachments ?? []
        let requestId = decoded.requestId.flatMap { UUID(uuidString: $0)?.uuidString.lowercased() }
        if decoded.requestId != nil, requestId == nil {
            return RouteJSON.error(.badRequest, "malformed-request-id")
        }

        let account: Account
        do {
            guard let found = try await AccountStore.find(byId: accountId, db: db) else {
                return RouteJSON.error(.notFound, "unknown-account")
            }
            account = found
        } catch {
            logger.error("compose account lookup failed", metadata: [
                "accountId": .string(accountId.uuidString),
                "err": .string("\(error)"),
            ])
            return RouteJSON.error(.internalServerError, "internal-error")
        }
        guard let provider = makeProvider(account) else {
            return RouteJSON.error(.serviceUnavailable, "provider-not-configured")
        }
        // Fast path: this requestId has already gone out. Replay the stored
        // result instead of sending a second copy.
        if let requestId {
            do {
                if let existing = try await AIActionStore.findSend(
                    accountId: accountId,
                    requestId: requestId,
                    db: db
                ) {
                    return RouteJSON.response(SendResponse(
                        ok: true,
                        providerMessageId: existing.payload["providerMessageId"]
                    ))
                }
            } catch {
                logger.error("compose.idempotencyLookupFailed", metadata: [
                    "accountId": .string(accountId.uuidString),
                    "err": .string("\(error)"),
                ])
                return RouteJSON.error(.internalServerError, "internal-error")
            }
        }

        // Claim the send before it goes out. Two requests carrying the
        // same requestId must not both put the mail on the wire.
        let claimRowId: Int64?
        do {
            switch try await Self.claimSend(
                accountId: accountId,
                requestId: requestId,
                payload: ["to": to, "type": "compose"],
                db: db
            ) {
            case .replay(let providerMessageId):
                return RouteJSON.response(SendResponse(
                    ok: true,
                    providerMessageId: providerMessageId
                ))
            case .conflict:
                return RouteJSON.error(.conflict, "send-in-flight")
            case .proceed(let rowId):
                claimRowId = rowId
            }
        } catch {
            logger.error("compose.claimFailed", metadata: [
                "accountId": .string(accountId.uuidString),
                "err": .string("\(error)"),
            ])
            return RouteJSON.error(.internalServerError, "internal-error")
        }

        let outbound = OutboundMessage(
            fromEmail: account.email,
            fromName: nil,
            to: to,
            cc: ccAddresses,
            bcc: bccAddresses,
            subject: subject,
            body: body,
            inReplyTo: nil,
            references: nil,
            isReply: false,
            attachments: outboundAttachments
        )
        let providerMessageId: String?
        do {
            providerMessageId = try await provider.send(outbound)
        } catch {
            // The mail is not out, so the claim must go back: the user's
            // retry with the same requestId has to be able to try again.
            await Self.releaseClaim(
                claimRowId, reason: Self.providerLabel(error), db: db, logger: logger
            )
            return Self.sendError(error, logger: logger, remoteId: "compose")
        }
        var payload = ["to": to, "type": "compose"]
        if let providerMessageId {
            payload["providerMessageId"] = providerMessageId
        }
        await Self.recordSendOutcome(
            accountId: accountId,
            claimRowId: claimRowId,
            payload: payload,
            db: db,
            logger: logger
        )
        return RouteJSON.response(SendResponse(ok: true, providerMessageId: providerMessageId))
    }

    /// Forwards a message to someone else.
    ///
    /// ## Why this is a server route and not client-side string surgery
    ///
    /// The old forward took the message's plain-text body, wrapped it in
    /// `>` characters, and sent that as a new message. The recipient got
    /// a wall of quoted text: the original's HTML formatting was gone, its
    /// attachments were gone, its headers were gone, and what was left
    /// could not be replied to in the original thread.
    ///
    /// RFC 5322 §3.6.4 has the answer. A forwarded message travels as a
    /// `message/rfc822` part — the **original message**, bytes and all,
    /// wrapped inside the new one. The recipient's client renders the
    /// original as it was and offers its attachments as the original's
    /// attachments.
    ///
    /// And the original's bytes have to come from the server: only the
    /// server has the raw RFC 5322 message. The client has a *parsed*
    /// body — the text, the HTML and the attachment metadata — and
    /// reassembling an original from a parse is a guess.
    ///
    /// So the client says "forward this message to these people with this
    /// note", and the server fetches the original raw message, wraps it,
    /// and sends.
    private static func forwardHandler(
        request: Request,
        context: BasicRequestContext,
        db: LagoonDB,
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
            return RouteJSON.error(.badRequest, "malformed-forward")
        }
        struct ForwardRequest: Decodable {
            /// The people the original goes to.
            let to: [String]
            /// The user's own note above the forwarded message.
            let body: String?
            /// The subject of the new message. Empty means "Fwd: <original>".
            let subject: String?
            let cc: [String]?
            let bcc: [String]?
            let requestId: String?
        }
        guard let decoded = try? JSONDecoder().decode(ForwardRequest.self, from: rawBody),
              !decoded.to.isEmpty
        else {
            return RouteJSON.error(.badRequest, "malformed-forward")
        }
        // Every recipient must be a routable address, and one bad address
        // refuses the whole forward rather than silently dropping a
        // recipient: a mail that reached fewer people than the user asked
        // is a mail the user cannot tell was wrong.
        for address in decoded.to where !Self.isValidRecipient(address) {
            return RouteJSON.error(.badRequest, "malformed-recipient")
        }
        if let copies = decoded.cc {
            for address in copies where !Self.isValidRecipient(address) {
                return RouteJSON.error(.badRequest, "malformed-recipient")
            }
        }
        let bcc = Self.recipientList(decoded.bcc)
        guard bcc != nil else {
            return RouteJSON.error(.badRequest, "malformed-recipient")
        }
        let requestId = decoded.requestId.flatMap { UUID(uuidString: $0)?.uuidString.lowercased() }
        if decoded.requestId != nil, requestId == nil {
            return RouteJSON.error(.badRequest, "malformed-request-id")
        }

        let account: Account
        do {
            guard let found = try await AccountStore.find(byId: accountId, db: db) else {
                return RouteJSON.error(.notFound, "unknown-account")
            }
            account = found
        } catch {
            logger.error("forward account lookup failed", metadata: [
                "accountId": .string(accountId.uuidString),
                "err": .string("\(error)"),
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
            logger.error("forward message lookup failed", metadata: [
                "accountId": .string(accountId.uuidString),
                "remoteId": .string(remoteId),
                "err": .string("\(error)"),
            ])
            return RouteJSON.error(.internalServerError, "internal-error")
        }
        guard let provider = makeProvider(account) else {
            return RouteJSON.error(.serviceUnavailable, "provider-not-configured")
        }
        // Fast path: this requestId has already gone out.
        if let requestId {
            do {
                if let existing = try await AIActionStore.findSend(
                    accountId: accountId,
                    requestId: requestId,
                    db: db
                ) {
                    return RouteJSON.response(SendResponse(
                        ok: true,
                        providerMessageId: existing.payload["providerMessageId"]
                    ))
                }
            } catch {
                logger.error("forward.idempotencyLookupFailed", metadata: [
                    "remoteId": .string(remoteId),
                    "err": .string("\(error)"),
                ])
                return RouteJSON.error(.internalServerError, "internal-error")
            }
        }

        // The original message, verbatim. This is the whole point of the
        // route: the bytes have to be the *original*, not a reconstruction
        // from a parse.
        let original: Data
        do {
            original = try await provider.fetchRawMessage(remoteId: remoteId)
        } catch {
            logger.error("forward.rawFetchFailed", metadata: [
                "accountId": .string(accountId.uuidString),
                "remoteId": .string(remoteId),
                "err": .string("\(error)"),
            ])
            // A message that cannot be fetched cannot be forwarded, and
            // the client needs to say *that* rather than "the send
            // failed".
            if let mailError = error as? MailError, mailError == .messageGone {
                return RouteJSON.error(.gone, "message-gone")
            }
            return RouteJSON.error(.badGateway, "forward-original-unavailable")
        }
        guard !original.isEmpty else {
            return RouteJSON.error(.badGateway, "forward-original-unavailable")
        }
        // A message with a 25 MB attachment in it is a message whose
        // forward is also 25 MB — and the SMTP path has its own ceiling
        // below that. The cap is checked *before* the send so the user
        // gets "this one is too big to forward" rather than a send that
        // fails halfway.
        guard original.count <= OutboundAttachment.maxBytes else {
            return RouteJSON.error(.conflict, "forward-too-large")
        }

        // Claim the send before it goes out.
        let claimRowId: Int64?
        do {
            switch try await Self.claimSend(
                accountId: accountId,
                requestId: requestId,
                payload: ["remoteId": remoteId, "type": "forward"],
                db: db
            ) {
            case .replay(let providerMessageId):
                return RouteJSON.response(SendResponse(
                    ok: true,
                    providerMessageId: providerMessageId
                ))
            case .conflict:
                return RouteJSON.error(.conflict, "send-in-flight")
            case .proceed(let rowId):
                claimRowId = rowId
            }
        } catch {
            logger.error("forward.claimFailed", metadata: [
                "remoteId": .string(remoteId),
                "err": .string("\(error)"),
            ])
            return RouteJSON.error(.internalServerError, "internal-error")
        }

        // The subject. "Fwd:" once, and the original's subject kept — the
        // same de-dup rule the reply path uses for "Re:".
        let subject = Self.forwardSubject(decoded.subject, original: stored.subject)
        // The user's own note. It goes in the body, above the forwarded
        // message, and the forwarded message itself is the
        // `message/rfc822` part.
        let note = (decoded.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let filename = Self.forwardFilename(stored.subject)

        let outbound = OutboundMessage(
            fromEmail: account.email,
            fromName: nil,
            to: decoded.to.joined(separator: ", "),
            cc: decoded.cc ?? [],
            bcc: bcc ?? [],
            subject: subject,
            body: note,
            inReplyTo: nil,
            references: nil,
            isReply: false,
            attachments: [
                OutboundAttachment(
                    filename: filename,
                    mimeType: "message/rfc822",
                    data: original,
                    disposition: .inline
                )
            ]
        )
        let providerMessageId: String?
        do {
            providerMessageId = try await provider.send(outbound)
        } catch {
            await Self.releaseClaim(
                claimRowId, reason: Self.providerLabel(error), db: db, logger: logger
            )
            return Self.sendError(error, logger: logger, remoteId: remoteId)
        }
        var payload = ["remoteId": remoteId, "type": "forward"]
        if let providerMessageId {
            payload["providerMessageId"] = providerMessageId
        }
        await Self.recordSendOutcome(
            accountId: accountId,
            claimRowId: claimRowId,
            payload: payload,
            db: db,
            logger: logger
        )
        return RouteJSON.response(SendResponse(ok: true, providerMessageId: providerMessageId))
    }

    /// The subject of a forwarded message.
    ///
    /// "Fwd:" exactly once, the original's subject kept. The de-dup rule
    /// matters: forwarding an already-forwarded message must not produce
    /// "Fwd: Fwd: Fwd: …".
    static func forwardSubject(_ requested: String?, original: String?) -> String {
        let trimmed = (requested ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? (original ?? "") : trimmed
        if base.lowercased().hasPrefix("fwd:") { return base }
        return base.isEmpty ? "Fwd:" : "Fwd: \(base)"
    }

    /// The file name of the forwarded original.
    ///
    /// It is what the recipient's client shows for the `message/rfc822`
    /// part, so it should read like the original rather than like a blob.
    /// A subject with a path separator in it would be a poor file name,
    /// so the separators go.
    static func forwardFilename(_ subject: String?) -> String {
        let base = (subject ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = base
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
        let trimmed = cleaned.isEmpty ? "forwarded message" : cleaned
        return "\(trimmed).eml"
    }

    /// Takes the claim that lets this request send, or says why it may not.
    ///
    /// The claim is what makes the client's idempotency key work under
    /// concurrency. Looking the requestId up and sending when nothing is
    /// there is a check-then-act race: two requests that arrive together
    /// both find nothing and both put the mail on the wire, and the
    /// recipient gets two copies. The claim is taken *before* the send and
    /// the unique index decides its winner, so only one request may send.
    ///
    /// Without an idempotency key there is nothing to claim: the request
    /// stands on its own, exactly as before.
    private static func claimSend(
        accountId: UUID,
        requestId: String?,
        payload: [String: String],
        db: LagoonDB
    ) async throws -> SendPermit {
        guard let requestId else { return .proceed(claimRowId: nil) }
        switch try await AIActionStore.claimSend(
            accountId: accountId, requestId: requestId, payload: payload, db: db
        ) {
        case .claimed(let rowId):
            return .proceed(claimRowId: rowId)
        case .alreadySent(let action):
            return .replay(providerMessageId: action.payload["providerMessageId"])
        case .inFlight:
            return .conflict
        }
    }

    /// Records the outcome of a send.
    ///
    /// With an idempotency key the outcome is folded into the claim row
    /// that was taken before the mail went out; without one there is no
    /// claim, and the audit row is written here — after the mail is on the
    /// wire, which is the only moment a send is worth recording.
    ///
    /// A failed write is logged and not raised: the mail is already out,
    /// and turning that into an error would make the client send it again.
    private static func recordSendOutcome(
        accountId: UUID,
        claimRowId: Int64?,
        payload: [String: String],
        db: LagoonDB,
        logger: Logger
    ) async {
        do {
            if let claimRowId {
                try await AIActionStore.completeSend(id: claimRowId, payload: payload, db: db)
            } else {
                _ = try await AIActionStore.record(
                    accountId: accountId,
                    kind: .send,
                    payload: payload,
                    db: db
                )
            }
        } catch {
            logger.warning("send.auditFailed", metadata: [
                "err": .string("\(error)"),
            ])
        }
    }

    /// Releases a claim whose send failed, so the next request with the
    /// same idempotency key may take it over and try again. Without this
    /// the key would stay locked to a mail that was never sent.
    private static func releaseClaim(
        _ claimRowId: Int64?,
        reason: String,
        db: LagoonDB,
        logger: Logger
    ) async {
        guard let claimRowId else { return }
        do {
            try await AIActionStore.failSend(id: claimRowId, reason: reason, db: db)
        } catch {
            logger.error("send.claimReleaseFailed", metadata: [
                "err": .string("\(error)"),
            ])
        }
    }

    /// New-mail recipients cross a trust boundary. This deliberately accepts
    /// one ordinary address only: no display names, lists, line breaks or
    /// header injection.
    private static func isValidRecipient(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 254, !value.containsHeaderInjection else {
            return false
        }
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2,
              !parts[0].isEmpty,
              !parts[1].isEmpty,
              parts[1].contains("."),
              !value.contains(where: \.isWhitespace)
        else { return false }
        return true
    }

    /// Splits a comma-separated recipient field and validates each address.
    ///
    /// The split is `AddressList.split` — the RFC 5322 one — because a
    /// comma inside a quoted display name (`"Zhang, Wei" <j@x.com>`)
    /// belongs to the name, and cutting there produced one address and one
    /// unusable fragment.
    ///
    /// Returns nil when any entry is not a plain address.
    private static func recipientList(from raw: String) -> [String]? {
        let pieces = AddressList.split(raw)
        guard let result = recipientList(pieces) else { return nil }
        return result
    }

    /// Validates a Cc/Bcc list.
    ///
    /// The list is a *list*: each entry is one ordinary address, the same
    /// rule the `To:` field follows. Two things this deliberately does not
    /// do:
    ///
    /// * It does not accept a comma-joined string. The client sends an
    ///   array, so an entry that contains a comma is one address the user
    ///   typed wrong — not two addresses.
    /// * It does not drop the bad entries and keep the good ones. Silently
    ///   dropping one would send a mail to fewer people than the user
    ///   asked, with no way for them to notice. The whole list is refused
    ///   and the client says which address was wrong.
    ///
    /// Returns nil when the list is valid, and nil-vs-invalid is carried by
    /// the caller: an invalid list answers `malformed-recipient`.
    private static func recipientList(
        _ raw: [String]?
    ) -> [String]? {
        guard let raw else { return [] }
        var result: [String] = []
        for entry in raw {
            let value = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            // An empty entry is a blank line in the client's list, not an
            // address. It is skipped rather than refused: the user pressing
            /// Enter after the last address is a normal thing to do, and it
            // must not fail the send.
            if value.isEmpty { continue }
            guard isValidRecipient(value) else { return nil }
            result.append(value)
        }
        return result
    }

    /// Decodes the attachment payloads.
    ///
    /// base64 because JSON has no byte type. A payload that does not decode,
    /// or that is empty, or that is over the size cap, refuses the whole
    /// request: an attachment that silently went missing would be worse
    /// than a send that did not happen, because the user would believe the
    /// file was on its way.
    private static func decodeAttachments(
        _ raw: [ComposeAttachmentPayload]?
    ) -> [OutboundAttachment]? {
        guard let raw else { return [] }
        var result: [OutboundAttachment] = []
        var total = 0
        for entry in raw {
            guard let data = Data(base64Encoded: entry.dataBase64),
                  data.count <= OutboundAttachment.maxBytes
            else { return nil }
            total += data.count
            // A whole-message cap, on top of the per-file one. Ten 25 MB
            // files would be 250 MB of JSON, and the request body is already
            // capped at 1 MB upstream — this is the honest second line of
            // defence for the case where that cap moves.
            guard total <= OutboundAttachment.maxBytes * 4 else { return nil }
            let attachment = OutboundAttachment(
                filename: entry.filename,
                mimeType: entry.mimeType,
                data: data
            )
            guard attachment.isSendable else { return nil }
            result.append(attachment)
        }
        return result
    }

    /// Send a plain-text reply to the message's sender. Everything the wire
    /// needs (recipient, subject, threading headers) comes from the synced
    /// row — the client only supplies the body, so it cannot redirect a reply.
    /// The `Re:` prefix and RFC 2047 encoding belong to `MIMEBuilder`, which
    /// both providers run.
    private static func sendHandler(
        request: Request,
        context: BasicRequestContext,
        db: LagoonDB,
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
            // The attachment-sized cap: a reply can carry files, and 1 MB
            // would refuse a perfectly ordinary one before the user ever
            // got to see why.
            rawBody = try await RouteParams.collectAttachmentBody(request)
        } catch {
            return RouteJSON.error(.badRequest, "malformed-body")
        }
        struct SendRequest: Decodable {
            let body: String
            let requestId: String?
            /// Reply-all override: the full recipient list the client
            /// computed (sender + other To's minus self). Omitted for a
            /// plain reply, in which case the server falls back to the
            /// stored message's From — that is the single-recipient path
            /// and is left untouched.
            let to: [String]?
            /// Reply-all Cc list. Omitted means "no Cc header".
            let cc: [String]?
            /// Blind copies. Omitted means "no Bcc".
            let bcc: [String]?
            /// Files to attach. Omitted means "no attachments".
            let attachments: [ComposeAttachmentPayload]?
        }
        guard let decoded = try? JSONDecoder().decode(SendRequest.self, from: rawBody),
              !decoded.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return RouteJSON.error(.badRequest, "malformed-body")
        }
        // Every reply-all recipient must be a routable address. A malformed
        // entry would otherwise end up in the `To:` header verbatim.
        if let recipients = decoded.to, !recipients.isEmpty {
            for address in recipients where !Self.isValidRecipient(address) {
                return RouteJSON.error(.badRequest, "malformed-recipient")
            }
        }
        if let copies = decoded.cc {
            for address in copies where !Self.isValidRecipient(address) {
                return RouteJSON.error(.badRequest, "malformed-recipient")
            }
        }
        let bcc = Self.recipientList(decoded.bcc)
        guard bcc != nil else {
            return RouteJSON.error(.badRequest, "malformed-recipient")
        }
        let attachments = Self.decodeAttachments(decoded.attachments)
        guard attachments != nil else {
            return RouteJSON.error(.badRequest, "malformed-attachment")
        }
        let requestId = decoded.requestId.flatMap { UUID(uuidString: $0)?.uuidString.lowercased() }
        if decoded.requestId != nil, requestId == nil {
            return RouteJSON.error(.badRequest, "malformed-request-id")
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
        // Fast path: this requestId has already gone out. Replay the stored
        // result instead of sending a second copy.
        if let requestId {
            do {
                if let existing = try await AIActionStore.findSend(
                    accountId: accountId,
                    requestId: requestId,
                    db: db
                ) {
                    return RouteJSON.response(SendResponse(
                        ok: true,
                        providerMessageId: existing.payload["providerMessageId"]
                    ))
                }
            } catch {
                logger.error("send.idempotencyLookupFailed", metadata: [
                    "remoteId": .string(remoteId),
                    "err": .string("\(error)")
                ])
                return RouteJSON.error(.internalServerError, "internal-error")
            }
        }

        // Claim the send before it goes out. Two requests carrying the
        // same requestId must not both put the reply on the wire.
        let claimRowId: Int64?
        do {
            switch try await Self.claimSend(
                accountId: accountId,
                requestId: requestId,
                payload: ["remoteId": remoteId, "to": stored.fromAddress],
                db: db
            ) {
            case .replay(let providerMessageId):
                return RouteJSON.response(SendResponse(
                    ok: true,
                    providerMessageId: providerMessageId
                ))
            case .conflict:
                return RouteJSON.error(.conflict, "send-in-flight")
            case .proceed(let rowId):
                claimRowId = rowId
            }
        } catch {
            logger.error("send.claimFailed", metadata: [
                "remoteId": .string(remoteId),
                "err": .string("\(error)")
            ])
            return RouteJSON.error(.internalServerError, "internal-error")
        }

        // Threading: reply to the parent's Message-ID and extend the parent's
        // chain with that id, so clients that only walk References still see
        // this reply as part of the thread.
        let references = [stored.references, stored.messageIdHeader]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        // Reply-all: the client sends the full recipient set (it has the
        // parsed `to`/`cc` arrays from the body response). A plain reply
        // omits the overrides and keeps the pre-M1.7 behaviour of replying
        // to the stored `From` only.
        let recipients = decoded.to.flatMap { $0.isEmpty ? nil : $0 }
            ?? [stored.fromAddress]
        // Drop self and any address already in `To` so a reply-all to a
        // message you sent to yourself does not put you in your own Cc.
        let selfAddress = account.email.lowercased()
        let toSet = Set(recipients.map { $0.lowercased() })
        let cc = (decoded.cc ?? []).filter {
            let lower = $0.lowercased()
            return lower != selfAddress && !toSet.contains(lower)
        }
        let outbound = OutboundMessage(
            fromEmail: account.email,
            fromName: nil,
            to: recipients.joined(separator: ", "),
            cc: cc,
            bcc: bcc ?? [],
            subject: stored.subject ?? "",
            body: decoded.body,
            inReplyTo: stored.messageIdHeader,
            references: references.isEmpty ? nil : references,
            attachments: attachments ?? []
        )

        let providerMessageId: String?
        do {
            providerMessageId = try await provider.send(outbound)
        } catch {
            // The reply is not out, so the claim must go back: the user's
            // retry with the same requestId has to be able to try again.
            await Self.releaseClaim(
                claimRowId, reason: Self.providerLabel(error), db: db, logger: logger
            )
            return Self.sendError(error, logger: logger, remoteId: remoteId)
        }
        // The reply is already on the wire: a failed audit write must not turn
        // a delivered message into a 500 the client would retry.
        var payload = [
            "remoteId": remoteId,
            "to": stored.fromAddress
        ]
        if let providerMessageId {
            payload["providerMessageId"] = providerMessageId
        }
        await Self.recordSendOutcome(
            accountId: accountId,
            claimRowId: claimRowId,
            payload: payload,
            db: db,
            logger: logger
        )
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
        case .accountMissing:
            // The account row is gone, so there is nothing to send with. 404
            // rather than 502: nothing about the mail server failed.
            return RouteJSON.error(.notFound, "unknown-account")
        case .unreachable, .protocolError, .archiveUnavailable, .trashUnavailable,
            .sentUnavailable:
            return RouteJSON.error(.badGateway, "smtp-send-failed")
        }
    }

    // MARK: - Body fetch (shared by /body and /summary)

    /// Fetch a full message through the account's provider and shape it as the
    /// shared `MessageBody` contract. Metadata comes from the synced row (best
    /// effort: a row that vanished still yields the body text). Attachment
    /// data is stripped before the wire response — clients fetch each part
    /// separately via `/api/messages/{remoteId}/attachments/{aid}`.
    /// Body with durable write-through (V2 A3): serve the stored parse when
    /// present, otherwise fetch from the provider and persist for next time.
    /// Bodies are immutable, so a stored row is never stale; a provider-side
    /// `messageGone` drops the stale row and propagates the 410.
    static func fetchBody(
        account: Account,
        remoteId: String,
        provider: any MailProvider,
        db: LagoonDB,
        logger: Logger
    ) async throws -> MessageBody {
        if let stored = try? await BodyStore.get(
            accountId: account.id, remoteId: remoteId, db: db
        ) {
            let header = try? await MessageStore.find(
                remoteId: remoteId, accountId: account.id, db: db
            )
            return MessageBody(
                remoteId: remoteId,
                subject: header?.subject,
                fromAddress: header?.fromAddress ?? "",
                fromName: header?.fromName,
                toAddress: nil,
                receivedAt: header?.receivedAt ?? Date(),
                text: stored.text,
                html: stored.html,
                attachments: stored.attachments.map { $0.toWire() },
                hasMore: stored.hasMore,
                to: stored.to,
                cc: stored.cc
            )
        }
        do {
            let fetched = try await provider.fetchBody(remoteId: remoteId)
            // Best-effort persist: a store failure must not fail the read
            // the user is looking at. "No header row" is not a store failure
            // — `message_bodies` has a foreign key into `message_headers`, and
            // the client can open a message the sync loop never listed (or has
            // since reconciled away). Such a body is simply not cacheable, and
            // saying so keeps the real write faults readable in the log.
            do {
                try await BodyStore.put(
                    accountId: account.id, remoteId: remoteId, body: fetched, db: db
                )
            } catch BodyStoreError.headerMissing {
                logger.info("body.persistSkipped", metadata: [
                    "remoteId": .string(remoteId),
                    "reason": .string("no-header-row"),
                ])
            } catch {
                logger.warning("body.persistFailed", metadata: [
                    "remoteId": .string(remoteId),
                    "err": .string("\(error)"),
                ])
            }
            // 一键退订: harvest unsubscribe links while the fresh HTML is in
            // hand — this is the proactive scan the moment the body first
            // lands, so the endpoint can answer without re-fetching.
            try? await MessageStore.mergeUnsubscribeLinks(
                remoteId: remoteId,
                accountId: account.id,
                links: UnsubscribeScanner.bodyLinks(in: fetched.html ?? fetched.text),
                db: db
            )
            let stored = try? await MessageStore.find(remoteId: remoteId, accountId: account.id, db: db)
            return MessageBody(
                remoteId: remoteId,
                subject: stored?.subject,
                fromAddress: stored?.fromAddress ?? "",
                fromName: stored?.fromName,
                toAddress: nil,
                receivedAt: stored?.receivedAt ?? Date(),
                text: fetched.text,
                html: fetched.html,
                attachments: fetched.attachments.map { $0.toWire() },
                hasMore: fetched.hasMore,
                to: fetched.to,
                cc: fetched.cc
            )
        } catch let error as MailError where error == .messageGone {
            try? await BodyStore.delete(accountId: account.id, remoteId: remoteId, db: db)
            throw error
        }
    }

    // MARK: - Attachment + raw.eml routes

    static func downloadAttachment(
        account: Account,
        remoteId: String,
        attachmentId: String,
        provider: any MailProvider,
        logger: Logger
    ) async -> Response {
        do {
            let bytes = try await provider.fetchAttachment(
                remoteId: remoteId,
                attachmentId: attachmentId
            )
            var response = Response(status: .ok)
            // RFC 6266: filename* with UTF-8 encoding for non-ASCII names;
            // fall back to a quoted ASCII form when encoding isn't possible.
            let safeName = bytes.filename?
                .replacingOccurrences(of: "\"", with: "")
                .replacingOccurrences(of: "\r", with: "")
                .replacingOccurrences(of: "\n", with: "")
            if let safeName, !safeName.isEmpty {
                // RFC 6266: `filename` is what a client that does not
                // understand `filename*` shows, so it carries the name
                // itself; `filename*` carries the same name percent-encoded
                // exactly once. Putting the encoded form in both made the
                // save dialog offer `%E6%8A%A5…` as the file name.
                let encoded = safeName.addingPercentEncoding(
                    withAllowedCharacters: .urlPathAllowed
                ) ?? safeName
                response.headers[.contentDisposition] =
                    "attachment; filename=\"\(safeName)\"; filename*=UTF-8''\(encoded)"
            } else {
                response.headers[.contentDisposition] = "attachment"
            }
            response.headers[.contentType] = bytes.mimeType
            response.headers[.contentLength] = String(bytes.data.count)
            response.body = .init(byteBuffer: ByteBuffer(bytes: bytes.data))
            return response
        } catch AttachmentError.tooLarge {
            logger.warning("attachment.tooLarge", metadata: [
                "remoteId": .string(remoteId),
                "attachmentId": .string(attachmentId),
            ])
            // 413 is the contract the client's copy names ("单个附件上限
            // 25MB"). This used to answer 500 behind a comment claiming
            // Hummingbird exposed no named 413 case — the dependency chain
            // says otherwise (`HTTPResponse.Status.contentTooLarge` = 413),
            // and a "server broke" status for a size limit sends every retry
            // and retry-loop decision down the wrong path.
            return RouteJSON.error(.contentTooLarge, "attachment-too-large")
        } catch AttachmentError.notFound {
            return RouteJSON.error(.notFound, "attachment-not-found")
        } catch let error as MailError {
            return providerError(error, logger: logger, remoteId: remoteId)
        } catch {
            logger.error("attachment fetch failed", metadata: [
                "remoteId": .string(remoteId),
                "attachmentId": .string(attachmentId),
                "err": .string("\(error)")
            ])
            return RouteJSON.error(.badGateway, "provider-unreachable")
        }
    }

    static func downloadRawMessage(
        account: Account,
        remoteId: String,
        provider: any MailProvider,
        subject: String?,
        logger: Logger
    ) async -> Response {
        do {
            let raw = try await provider.fetchRawMessage(remoteId: remoteId)
            var response = Response(status: .ok)
            response.headers[.contentType] = "message/rfc822"
            response.headers[.contentDisposition] =
                "attachment; filename=\"\(rawMessageFilename(subject: subject))\""
            response.headers[.contentLength] = String(raw.count)
            response.body = .init(byteBuffer: ByteBuffer(bytes: raw))
            return response
        } catch let error as MailError {
            return providerError(error, logger: logger, remoteId: remoteId)
        } catch {
            logger.error("raw message fetch failed", metadata: [
                "remoteId": .string(remoteId),
                "err": .string("\(error)")
            ])
            return RouteJSON.error(.badGateway, "provider-unreachable")
        }
    }

    /// Download name for the raw message. The subject is attacker-supplied
    /// text going straight into a `Content-Disposition` header, so quotes and
    /// CR/LF are stripped rather than escaped — a header split here would let
    /// a message name its own response headers. Falls back to a neutral name
    /// when the row is unsynced or the subject is empty.
    static func rawMessageFilename(subject: String?) -> String {
        let cleaned = (subject ?? "")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // `/` and `\` would turn the name into a path the user did not choose.
        let safe = cleaned
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
        let capped = String(safe.prefix(80))
        return capped.isEmpty ? "message.eml" : "\(capped).eml"
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
        // A message whose encoded body is larger than the framing ceiling
        // is *too big*, not broken. 25 MB of attachment travels as ~33 MB
        // of base64, so this is a size the product promised to accept; it
        // used to be reported as 502 "server error", which told the user
        // the server broke and invited a retry that could never work.
        if case .protocolError(let label) = error,
           label == IMAPConnection.oversizeLiteralLabel {
            return RouteJSON.error(.contentTooLarge, "attachment-too-large")
        }
        switch error {
        case .messageGone:
            return RouteJSON.error(.gone, "message-gone")
        case .authFailed:
            return RouteJSON.error(.unauthorized, "provider-auth-failed")
        case .notConfigured:
            return RouteJSON.error(.serviceUnavailable, "provider-not-configured")
        case .archiveUnavailable:
            return RouteJSON.error(.conflict, "archive-unavailable")
        case .trashUnavailable:
            return RouteJSON.error(.conflict, "delete-unavailable")
        case .sentUnavailable:
            // 404, not an empty list: "this account has no Sent folder" and
            // "you have sent nothing" are different answers, and only one of
            // them is true here.
            return RouteJSON.error(.notFound, "sent-unavailable")
        case .accountMissing:
            // Same reason as the send path: the store has no row for this
            // account, so the failure is "unknown account", not "the mail
            // server misbehaved".
            return RouteJSON.error(.notFound, "unknown-account")
        case .unreachable, .protocolError:
            return RouteJSON.error(.badGateway, "provider-unreachable")
        }
    }

    static func providerLabel(_ error: Error) -> String {
        (error as? MailError)?.logLabel ?? "\(type(of: error))"
    }
}

private extension String {
    /// Judged on UTF-8 bytes, not on `Character`s. Swift treats CRLF as a
    /// single extended grapheme cluster, so `contains("\r")` and
    /// `contains("\n")` are both false for `"\r\n"` — the exact sequence a
    /// header injection is made of, and the only one these two checks were
    /// there to catch. Bare CR and bare LF are single clusters and were caught
    /// by accident.
    var containsHeaderInjection: Bool {
        let bytes = utf8
        return bytes.contains(0x0D) || bytes.contains(0x0A) || bytes.contains(0x00)
    }
}
