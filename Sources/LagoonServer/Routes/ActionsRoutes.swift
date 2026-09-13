import Foundation
import Hummingbird
import Logging
import PostgresNIO
import LagoonKit

struct ArchiveResponse: Encodable { let ok: Bool; let remoteId: String; let remote: Bool; let actionId: Int64 }
struct ClassifyResponse: Encodable {
    let ok: Bool
    let actionId: Int64
    let fromGroup: String
    let toGroup: String
}
struct UnsubscribeResponse: Encodable {
    let ok: Bool
    let unsubscribed: Bool
    let publisher: String
    let actionId: Int64
}
struct UndoResponse: Encodable { let ok: Bool; let undone: Int64 }

/// Some actions have no inverse — a sent reply is gone, an unsubscribe already
/// told the publisher. The route answers 400 `not-undoable` for these instead
/// of a 500 that reads like a server fault.
struct NotUndoable: Error { let kind: AIActionKind }

/// Every "Lagoon did something" mutation flows through here. The undo panel
/// reads from the same table (GET /api/actions).
public enum ActionsRoutes {
    public static func register(
        on router: Router<BasicRequestContext>,
        db: PostgresConnection,
        client: GmailClient,
        tokens: GmailTokenService,
        logger: Logger,
        makeProvider: MailProviderFactory.Builder? = nil
    ) {
        let makeProvider = makeProvider
            ?? MailProviderFactory.factory(client: client, tokens: tokens, db: db, logger: logger)

        // POST /api/messages/{remoteId}/archive?accountId=
        // Moves the message through the account's provider (`MailProvider.archive`).
        // Gated on the negotiated `capabilities.archiveFolder`: a provider that
        // cannot move messages is rejected before any local state changes.
        router.post("api/messages/:remoteId/archive") { request, context -> Response in
            return await archiveHandler(
                request: request, context: context, db: db,
                makeProvider: makeProvider, logger: logger
            )
        }

        // POST /api/messages/{remoteId}/unsubscribe
        // Reads the List-Unsubscribe header through the provider, fires an HTTP
        // POST/GET to the endpoint, then records + marks read locally. Returns
        // the publisher it called so the UI can show "Unsubscribed from <publisher>".
        router.post("api/messages/:remoteId/unsubscribe") { request, context -> Response in
            return await unsubscribeHandler(
                request: request, context: context, db: db,
                makeProvider: makeProvider, logger: logger
            )
        }

        // POST /api/messages/{remoteId}/classify  {toGroup}
        // The from-group is inferred from the current classifier output if
        // known, or the override is stored as a forward-only nudge.
        router.post("api/messages/:remoteId/classify") { request, context -> Response in
            return await classifyOverrideHandler(
                request: request, context: context, db: db, logger: logger
            )
        }

        // GET /api/actions?accountId=&since=
        router.get("api/actions") { request, context -> Response in
            return await listActionsHandler(request: request, context: context, db: db, logger: logger)
        }

        // POST /api/actions/{id}/undo
        // Reverses the recorded inverse and records an audit-only undo action.
        router.post("api/actions/:id/undo") { request, context -> Response in
            return await undoActionHandler(
                request: request, context: context, db: db,
                makeProvider: makeProvider, logger: logger
            )
        }
    }

    // MARK: - Archive

    private static func archiveHandler(
        request: Request, context: BasicRequestContext, db: PostgresConnection,
        makeProvider: MailProviderFactory.Builder, logger: Logger
    ) async -> Response {
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
            return errorResponse(.internalServerError, "internal-error", logger: logger, error: error)
        }

        // Spec §3.7: a provider without an archive target must not half-archive.
        // The gate runs before any write, so a 409 leaves both remote and local
        // state untouched.
        guard account.capabilities.archiveFolder else {
            return RouteJSON.error(.conflict, "archive-unavailable")
        }
        guard let provider = makeProvider(account) else {
            return RouteJSON.error(.serviceUnavailable, "provider-not-configured")
        }
        do {
            try await provider.archive(remoteId: remoteId)
        } catch let error as MailError {
            return MessageRoutes.providerError(error, logger: logger, remoteId: remoteId)
        } catch {
            logger.warning("archive.remoteFailed", metadata: [
                "remoteId": .string(remoteId),
                "label": .string(MessageRoutes.providerLabel(error)),
            ])
            return RouteJSON.error(.badGateway, "provider-unreachable")
        }

        let action: AIAction
        do {
            action = try await db.withTransaction(logger: logger) { transaction in
                try await transaction.query(
                    "UPDATE message_headers SET is_archived = TRUE WHERE remote_id = $1 AND account_id = $2",
                    [PostgresData(string: remoteId), PostgresData(uuid: accountId)]
                ).get()
                return try await AIActionStore.record(
                    accountId: accountId,
                    kind: .archive,
                    payload: ["remoteId": remoteId, "remoteWrite": "true"],
                    db: transaction
                )
            }
        } catch {
            // Do not leave a remote-only move behind if the local commit failed.
            do {
                try await provider.unarchive(remoteId: remoteId)
            } catch {
                logger.error("archive.compensationFailed", metadata: [
                    "remoteId": .string(remoteId),
                    "err": .string("\(error)"),
                ])
            }
            logger.error("archive.localUpdateFailed", metadata: [
                "remoteId": .string(remoteId),
                "err": .string("\(error)"),
            ])
            return RouteJSON.error(.internalServerError, "internal-error")
        }
        return RouteJSON.response(ArchiveResponse(
            ok: true,
            remoteId: remoteId,
            remote: true,
            actionId: action.id
        ))
    }

    // MARK: - Unsubscribe

    private static func unsubscribeHandler(
        request: Request, context: BasicRequestContext, db: PostgresConnection,
        makeProvider: MailProviderFactory.Builder, logger: Logger
    ) async -> Response {
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
            return errorResponse(.internalServerError, "internal-error", logger: logger, error: error)
        }

        // The List-Unsubscribe value is fetched on demand — it costs one
        // provider round-trip and only when the user actually clicks.
        guard let provider = makeProvider(account) else {
            return RouteJSON.error(.serviceUnavailable, "provider-not-configured")
        }

        let publisher: String
        let unsubscribeURL: URL
        do {
            let headers = try await provider.fetchRawHeaderValues(remoteId: remoteId)
            guard let raw = headers.first(where: { $0.key.lowercased() == "list-unsubscribe" })?.value,
                  let url = firstUnsubscribeURL(raw) else {
                return RouteJSON.error(.unprocessableContent, "unsubscribe-unavailable")
            }
            publisher = extractPublisher(raw) ?? ""
            if url.scheme?.lowercased() == "mailto" {
                return RouteJSON.error(.unprocessableContent, "unsubscribe-manual-required")
            }
            unsubscribeURL = url
        } catch let error as MailError {
            return MessageRoutes.providerError(error, logger: logger, remoteId: remoteId)
        } catch {
            logger.warning("unsubscribe.fetchFailed", metadata: [
                "remoteId": .string(remoteId),
                "label": .string(MessageRoutes.providerLabel(error)),
            ])
            return RouteJSON.error(.badGateway, "provider-unreachable")
        }

        let unsubscribed: Bool
        do {
            unsubscribed = try await hitUnsubscribe(url: unsubscribeURL)
        } catch {
            logger.warning("unsubscribe.requestFailed", metadata: [
                "remoteId": .string(remoteId),
                "label": .string(MessageRoutes.providerLabel(error)),
            ])
            return RouteJSON.error(.badGateway, "unsubscribe-failed")
        }
        guard unsubscribed else {
            return RouteJSON.error(.badGateway, "unsubscribe-failed")
        }

        let action: AIAction
        do {
            action = try await db.withTransaction(logger: logger) { transaction in
                try await transaction.query(
                    "UPDATE message_headers SET is_archived = TRUE, is_read = TRUE WHERE remote_id = $1 AND account_id = $2",
                    [PostgresData(string: remoteId), PostgresData(uuid: accountId)]
                ).get()
                return try await AIActionStore.record(
                    accountId: accountId,
                    kind: .unsubscribe,
                    payload: [
                        "remoteId": remoteId,
                        "publisher": publisher,
                        "remote": "true",
                    ],
                    db: transaction
                )
            }
        } catch {
            return errorResponse(.internalServerError, "internal-error", logger: logger, error: error)
        }
        return RouteJSON.response(UnsubscribeResponse(
            ok: true,
            unsubscribed: true,
            publisher: publisher,
            actionId: action.id
        ))
    }

    // MARK: - Classify override

    private static func classifyOverrideHandler(
        request: Request, context: BasicRequestContext, db: PostgresConnection, logger: Logger
    ) async -> Response {
        guard let accountId = RouteParams.accountId(from: request) else {
            return RouteJSON.error(.badRequest, "malformed-accountId")
        }
        guard let remoteId = RouteParams.remoteId(from: context) else {
            return RouteJSON.error(.badRequest, "malformed-remoteId")
        }
        let body: Data
        do { body = try await collectBody(request) } catch {
            return RouteJSON.error(.badRequest, "missing-body")
        }
        struct Req: Decodable {
            let toGroup: String
            let fromGroup: String?
        }
        let req: Req
        do { req = try JSONDecoder().decode(Req.self, from: body) } catch {
            return RouteJSON.error(.badRequest, "invalid-body")
        }
        guard let toGroup = BriefingGroup(rawValue: req.toGroup),
              toGroup != .pinned
        else {
            return RouteJSON.error(.badRequest, "invalid-group")
        }
        let account: Account
        do {
            guard let found = try await AccountStore.find(byId: accountId, db: db) else {
                return RouteJSON.error(.notFound, "unknown-account")
            }
            account = found
        } catch {
            return errorResponse(.internalServerError, "internal-error", logger: logger, error: error)
        }
        let fromGroup: BriefingGroup
        do {
            guard let message = try await MessageStore.find(
                remoteId: remoteId,
                accountId: accountId,
                db: db
            ) else {
                return RouteJSON.error(.notFound, "unknown-message")
            }
            if let raw = req.fromGroup,
               let explicit = BriefingGroup(rawValue: raw),
               explicit != .pinned {
                fromGroup = explicit
            } else {
                let overrides = try await AIActionStore.overridesBySender(
                    accountId: accountId,
                    db: db
                )
                let pinned = try await MessageStore.pinnedIds(forAccount: accountId, db: db)
                let unsubscribed = try await MessageStore.listUnsubscribeIds(
                    forAccount: accountId,
                    db: db
                )
                let heuristic = HeuristicBriefingClassifier(
                    signals: .init(
                        pinnedGmailIds: pinned,
                        listUnsubscribeGmailIds: unsubscribed
                    )
                ).group(for: message, accountEmail: account.email)
                fromGroup = overrides[message.fromAddress] ?? heuristic.group
            }
        } catch {
            return errorResponse(.internalServerError, "internal-error", logger: logger, error: error)
        }
        guard fromGroup != toGroup else {
            return RouteJSON.error(.badRequest, "group-unchanged")
        }

        let action: AIAction
        do {
            action = try await db.withTransaction(logger: logger) { transaction in
                try await AIActionStore.insertOverride(
                    accountId: accountId,
                    remoteId: remoteId,
                    fromGroup: fromGroup,
                    toGroup: toGroup,
                    db: transaction
                )
                return try await AIActionStore.record(
                    accountId: accountId,
                    kind: .classifyOverride,
                    payload: [
                        "remoteId": remoteId,
                        "fromGroup": fromGroup.rawValue,
                        "toGroup": toGroup.rawValue,
                    ],
                    db: transaction
                )
            }
        } catch {
            return errorResponse(.internalServerError, "internal-error", logger: logger, error: error)
        }
        return RouteJSON.response(ClassifyResponse(
            ok: true,
            actionId: action.id,
            fromGroup: fromGroup.rawValue,
            toGroup: toGroup.rawValue
        ))
    }

    // MARK: - List actions

    private static func listActionsHandler(
        request: Request, context: BasicRequestContext, db: PostgresConnection, logger: Logger
    ) async -> Response {
        guard let accountId = RouteParams.accountId(from: request) else {
            return RouteJSON.error(.badRequest, "malformed-accountId")
        }
        let since: Date? = {
            guard let raw = request.uri.queryParameters["since"].map(String.init), !raw.isEmpty
            else { return nil }
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
        }()
        do {
            let actions = try await AIActionStore.recent(
                accountId: accountId, since: since, limit: 100, db: db
            )
            return RouteJSON.response(AIActionListResponse(actions: actions))
        } catch {
            return errorResponse(.internalServerError, "internal-error", logger: logger, error: error)
        }
    }

    // MARK: - Undo action

    private static func undoActionHandler(
        request: Request, context: BasicRequestContext, db: PostgresConnection,
        makeProvider: MailProviderFactory.Builder, logger: Logger
    ) async -> Response {
        guard let accountId = RouteParams.accountId(from: request) else {
            return RouteJSON.error(.badRequest, "malformed-accountId")
        }
        let rawId = context.parameters.get("id") ?? ""
        guard let actionId = Int64(rawId), actionId > 0 else {
            return RouteJSON.error(.badRequest, "malformed-action-id")
        }
        let account: Account
        do {
            guard let found = try await AccountStore.find(byId: accountId, db: db) else {
                return RouteJSON.error(.notFound, "unknown-account")
            }
            account = found
        } catch {
            return errorResponse(.internalServerError, "internal-error", logger: logger, error: error)
        }
        let action: AIAction
        do {
            guard let found = try await AIActionStore.find(id: actionId, db: db),
                  found.accountId == accountId else {
                return RouteJSON.error(.notFound, "unknown-action")
            }
            if let expiresAt = found.expiresAt, expiresAt <= Date() {
                return RouteJSON.error(.gone, "action-expired")
            }
            action = found
        } catch {
            return errorResponse(.internalServerError, "internal-error", logger: logger, error: error)
        }

        // Reverse each action type. Archive/read restore the remote state first;
        // pin/unpin flip locally; classify-override inserts a counter-override;
        // unsubscribe, send, drafting and undo itself are terminal.
        do {
            try await reverse(
                action: action, account: account,
                makeProvider: makeProvider, db: db, logger: logger
            )
            do {
                let _ = try await AIActionStore.record(
                    accountId: accountId,
                    kind: .undo,
                    payload: ["undoOf": "\(actionId)"],
                    db: db
                )
            } catch {
                // The inverse already completed; failing the response would make
                // the user retry a successful undo.
                logger.warning("undo.auditFailed", metadata: [
                    "actionId": .string("\(actionId)"),
                    "err": .string("\(error)"),
                ])
            }
        } catch let error as NotUndoable {
            logger.info("actions.notUndoable", metadata: [
                "kind": .string(error.kind.rawValue),
                "actionId": .string("\(actionId)"),
            ])
            return RouteJSON.error(.badRequest, "not-undoable")
        } catch {
            return errorResponse(.internalServerError, "undo-failed", logger: logger, error: error)
        }
        return RouteJSON.response(UndoResponse(ok: true, undone: actionId))
    }

    private static func reverse(
        action: AIAction, account: Account,
        makeProvider: MailProviderFactory.Builder,
        db: PostgresConnection, logger: Logger
    ) async throws {
        let remoteId = action.payload["remoteId"] ?? ""
        switch action.kind {
        case .archive:
            // Remote first: a local success must not hide a failed remote undo.
            if action.payload["remoteWrite"] == "true", let provider = makeProvider(account) {
                try await provider.unarchive(remoteId: remoteId)
            } else if action.payload["remoteWrite"] == "true" {
                throw MailError.notConfigured("provider missing during undo")
            }
            try await db.query(
                "UPDATE message_headers SET is_archived = FALSE WHERE remote_id = $1 AND account_id = $2",
                [PostgresData(string: remoteId), PostgresData(uuid: account.id)]
            ).get()
        case .markRead:
            guard let provider = makeProvider(account) else {
                throw MailError.notConfigured("provider missing during undo")
            }
            try await provider.setRead(remoteId: remoteId, isRead: false)
            try await db.query(
                "UPDATE message_headers SET is_read = FALSE WHERE remote_id = $1 AND account_id = $2",
                [PostgresData(string: remoteId), PostgresData(uuid: account.id)]
            ).get()
        case .pin:
            try await MessageStore.setPinned(false, remoteId: remoteId, accountId: account.id, db: db)
        case .unpin:
            try await MessageStore.setPinned(true, remoteId: remoteId, accountId: account.id, db: db)
        case .classifyOverride:
            // Counter-override: flip back to the original group.
            guard let from = action.payload["fromGroup"].flatMap(BriefingGroup.init(rawValue:)),
                  let to = action.payload["toGroup"].flatMap(BriefingGroup.init(rawValue:))
            else {
                throw MailError.protocolError("classification undo payload missing")
            }
            try await AIActionStore.insertOverride(
                accountId: account.id, remoteId: remoteId,
                fromGroup: to, toGroup: from, db: db
            )
        case .unsubscribe, .draftCreate, .send, .undo:
            // Terminal: we can't take back an unsubscribe, an undraft, or a
            // reply that has already left the building. Tell the user why.
            throw NotUndoable(kind: action.kind)
        }
    }

    // MARK: - Helpers

    private static func errorResponse(
        _ status: HTTPResponse.Status, _ code: String, logger: Logger, error: Error
    ) -> Response {
        logger.error("actions.error", metadata: ["code": .string(code), "err": .string("\(error)")])
        return RouteJSON.error(status, code)
    }

    private static func collectBody(_ request: Request) async throws -> Data {
        var bytes: [UInt8] = []
        for try await chunk in request.body {
            bytes.append(contentsOf: Array(buffer: chunk))
        }
        return Data(bytes)
    }

    /// Pulls the first usable URL out of a `List-Unsubscribe` header. The header
    /// can contain `<mailto:…>`, `<https://…>`, or bare URLs. We prefer https.
    private static func firstUnsubscribeURL(_ header: String) -> URL? {
        if let url = extractURLWithRegex(header, pattern: #"<(https?://[^>]+)>"#) {
            return url
        }
        return extractURLWithRegex(header, pattern: #"<(mailto:[^>]+)>"#)
    }

    private static func extractURLWithRegex(_ header: String, pattern: String) -> URL? {
        guard let range = header.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        let match = header[range].dropFirst().dropLast()
        return URL(string: String(match))
    }

    /// Extracts a publisher name like "<https://example.com/unsubscribe?id=…>".
    private static func extractPublisher(_ header: String) -> String? {
        guard let url = firstUnsubscribeURL(header) else { return nil }
        return url.host
    }

    /// Best-effort POST or GET to the unsubscribe endpoint. Many publishers use
    /// a tracking pixel (GET); some use a form (POST). We try POST first.
    private static func hitUnsubscribe(url: URL) async throws -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("Lagoon/1.0", forHTTPHeaderField: "User-Agent")
        let (_, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) {
            return true
        }
        var getRequest = URLRequest(url: url)
        getRequest.httpMethod = "GET"
        getRequest.timeoutInterval = 15
        let (_, getResponse) = try await URLSession.shared.data(for: getRequest)
        if let http = getResponse as? HTTPURLResponse, (200..<400).contains(http.statusCode) {
            return true
        }
        return false
    }
}
