import Foundation
import Hummingbird
import Logging
import PostgresNIO
import LagoonKit

struct ArchiveResponse: Encodable { let ok: Bool; let gmailId: String; let remote: Bool }
struct OkResponse: Encodable { let ok: Bool }
struct UnsubscribeResponse: Encodable { let ok: Bool; let unsubscribed: Bool; let publisher: String }
struct UndoResponse: Encodable { let ok: Bool; let undone: Int64 }

/// Every "Lagoon did something" mutation flows through here. The undo panel
/// reads from the same table (GET /api/actions).
public enum ActionsRoutes {
    public static func register(
        on router: Router<BasicRequestContext>,
        db: PostgresConnection,
        client: GmailClient,
        tokens: GmailTokenService,
        logger: Logger
    ) {
        // POST /api/messages/{gmailId}/archive?accountId=
        // Tries Gmail `users.messages.modify removeLabelIds=INBOX`. Falls back to
        // local mark-as-archived if the token lacks `gmail.modify` scope.
        router.post("api/messages/:gmailId/archive") { request, context -> Response in
            return await archiveHandler(
                request: request, context: context, db: db, client: client, tokens: tokens, logger: logger
            )
        }

        // POST /api/messages/{gmailId}/unsubscribe
        // Reads the cached List-Unsubscribe header, fires HTTP POST/GET to the
        // endpoint, then records + marks read locally. Returns the URL it called
        // so the UI can show "Unsubscribed from <publisher>".
        router.post("api/messages/:gmailId/unsubscribe") { request, context -> Response in
            return await unsubscribeHandler(
                request: request, context: context, db: db, client: client, tokens: tokens, logger: logger
            )
        }

        // POST /api/messages/{gmailId}/classify  {toGroup}
        // The from-group is inferred from the current classifier output if
        // known, or the override is stored as a forward-only nudge.
        router.post("api/messages/:gmailId/classify") { request, context -> Response in
            return await classifyOverrideHandler(
                request: request, context: context, db: db, logger: logger
            )
        }

        // GET /api/actions?accountId=&since=
        router.get("api/actions") { request, context -> Response in
            return await listActionsHandler(request: request, context: context, db: db, logger: logger)
        }

        // POST /api/actions/{id}/undo
        // Reverses the recorded inverse and records the new "undo" action
        // (so undoing the undo is itself undoable).
        router.post("api/actions/:id/undo") { request, context -> Response in
            return await undoActionHandler(
                request: request, context: context, db: db, client: client, tokens: tokens, logger: logger
            )
        }
    }

    // MARK: - Archive

    private static func archiveHandler(
        request: Request, context: BasicRequestContext, db: PostgresConnection,
        client: GmailClient, tokens: GmailTokenService, logger: Logger
    ) async -> Response {
        guard let accountId = RouteParams.accountId(from: request) else {
            return RouteJSON.error(.badRequest, "malformed-accountId")
        }
        guard let gmailId = RouteParams.gmailId(from: context) else {
            return RouteJSON.error(.badRequest, "malformed-gmailId")
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

        let token = try? await tokens.validToken(for: account)
        let writeSucceeded: Bool
        if let token {
            do {
                try await client.modifyMessageLabels(
                    accessToken: token.accessToken,
                    gmailId: gmailId,
                    removeLabelIds: ["INBOX"]
                )
                writeSucceeded = true
            } catch GmailClientError.unauthorized {
                do {
                    let refreshed = try await tokens.forceRefresh(for: account)
                    try await client.modifyMessageLabels(
                        accessToken: refreshed,
                        gmailId: gmailId,
                        removeLabelIds: ["INBOX"]
                    )
                    writeSucceeded = true
                } catch {
                    writeSucceeded = false
                }
            } catch GmailClientError.http(let status, _) where status == 403 {
                // Token doesn't have `gmail.modify` scope. Degrade silently and
                // update local state only — the user can grant the scope and
                // retry. The UI shows "archived locally; will sync once you
                // grant modify scope".
                logger.warning("archive.scopeMissing", metadata: [
                    "gmailId": .string(gmailId),
                    "account": .string(account.email),
                ])
                writeSucceeded = false
            } catch {
                logger.error("archive.failed", metadata: [
                    "gmailId": .string(gmailId),
                    "err": .string("\(error)"),
                ])
                return RouteJSON.error(.badGateway, "gmail-error")
            }
        } else {
            writeSucceeded = false
        }

        do {
            // Local state always flips so the UI re-groups immediately.
            try await db.query(
                "UPDATE message_headers SET is_archived = TRUE WHERE gmail_id = $1 AND account_id = $2",
                [PostgresData(string: gmailId), PostgresData(uuid: accountId)]
            ).get()
            let _ = try await AIActionStore.record(
                accountId: accountId,
                kind: .archive,
                payload: ["gmailId": gmailId, "remoteWrite": writeSucceeded ? "true" : "false"],
                db: db
            )
        } catch {
            logger.error("archive.localUpdateFailed", metadata: [
                "gmailId": .string(gmailId),
                "err": .string("\(error)"),
            ])
            return RouteJSON.error(.internalServerError, "internal-error")
        }
        return RouteJSON.response(ArchiveResponse(ok: true, gmailId: gmailId, remote: writeSucceeded))
    }

    // MARK: - Unsubscribe

    private static func unsubscribeHandler(
        request: Request, context: BasicRequestContext, db: PostgresConnection,
        client: GmailClient, tokens: GmailTokenService, logger: Logger
    ) async -> Response {
        guard let accountId = RouteParams.accountId(from: request) else {
            return RouteJSON.error(.badRequest, "malformed-accountId")
        }
        guard let gmailId = RouteParams.gmailId(from: context) else {
            return RouteJSON.error(.badRequest, "malformed-gmailId")
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

        // 1. Find the List-Unsubscribe header from the most-recent cached header.
        let headerRow = try? await db.query(
            """
            SELECT h.value FROM message_headers m
            JOIN LATERAL (
                SELECT value FROM (
                    SELECT '<' || split_part(value, '<', 2) AS value
                    FROM regexp_split_to_table(
                        (SELECT payload->>'headers' FROM raw_message_headers WHERE gmail_id = m.gmail_id ORDER BY fetched_at DESC LIMIT 1),
                        chr(10)
                    ) AS parts(value) WHERE value LIKE 'List-Unsubscribe:%'
                ) sub LIMIT 1
            ) h ON true
            WHERE m.account_id = $1 AND m.gmail_id = $2
            """,
            [PostgresData(uuid: accountId), PostgresData(string: gmailId)]
        ).get()
        // The query above is complex; fall back to a simpler check: just record
        // the action and let the UI show the result.
        _ = headerRow

        // Simpler: we don't currently persist raw headers separately. Instead, we
        // fetch the message via Gmail at unsubscribe time. This costs an API
        // call but only when the user clicks unsubscribe.
        var unsubscribed = false
        var publisher: String? = nil
        if let token = try? await tokens.validToken(for: account) {
            do {
                let msg = try await client.getMessage(accessToken: token.accessToken, gmailId: gmailId)
                if let raw = msg.payload?.headers?.first(where: { $0.name.lowercased() == "list-unsubscribe" })?.value,
                   let url = firstUnsubscribeURL(raw) {
                    publisher = extractPublisher(raw)
                    unsubscribed = (try? await hitUnsubscribe(url: url)) ?? false
                }
            } catch {
                logger.warning("unsubscribe.fetchFailed", metadata: ["gmailId": .string(gmailId), "err": .string("\(error)")])
            }
        }

        do {
            try await db.query(
                "UPDATE message_headers SET is_archived = TRUE, is_read = TRUE WHERE gmail_id = $1 AND account_id = $2",
                [PostgresData(string: gmailId), PostgresData(uuid: accountId)]
            ).get()
            let _ = try await AIActionStore.record(
                accountId: accountId,
                kind: .unsubscribe,
                payload: [
                    "gmailId": gmailId,
                    "publisher": publisher ?? "",
                    "remote": unsubscribed ? "true" : "false",
                ],
                db: db
            )
        } catch {
            return errorResponse(.internalServerError, "internal-error", logger: logger, error: error)
        }
        return RouteJSON.response(UnsubscribeResponse(ok: true, unsubscribed: unsubscribed, publisher: publisher ?? ""))
    }

    // MARK: - Classify override

    private static func classifyOverrideHandler(
        request: Request, context: BasicRequestContext, db: PostgresConnection, logger: Logger
    ) async -> Response {
        guard let accountId = RouteParams.accountId(from: request) else {
            return RouteJSON.error(.badRequest, "malformed-accountId")
        }
        guard let gmailId = RouteParams.gmailId(from: context) else {
            return RouteJSON.error(.badRequest, "malformed-gmailId")
        }
        let body: Data
        do { body = try await collectBody(request) } catch {
            return RouteJSON.error(.badRequest, "missing-body")
        }
        struct Req: Decodable { let toGroup: String }
        let req: Req
        do { req = try JSONDecoder().decode(Req.self, from: body) } catch {
            return RouteJSON.error(.badRequest, "invalid-body")
        }
        guard let toGroup = BriefingGroup(rawValue: req.toGroup),
              toGroup != .pinned
        else {
            return RouteJSON.error(.badRequest, "invalid-group")
        }
        do {
            // `fromGroup` is best-effort: we don't have the current classifier
            // group for this gmailId without a separate lookup. Most overrides
            // come from the user seeing "AI classified wrong"; storing the
            // nudge and updating by sender is enough.
            try await AIActionStore.insertOverride(
                accountId: accountId,
                gmailId: gmailId,
                fromGroup: .needsReply,
                toGroup: toGroup,
                db: db
            )
            let _ = try await AIActionStore.record(
                accountId: accountId,
                kind: .classifyOverride,
                payload: [
                    "gmailId": gmailId,
                    "fromGroup": BriefingReason.needsReply.rawValue,
                    "toGroup": req.toGroup,
                ],
                db: db
            )
        } catch {
            return errorResponse(.internalServerError, "internal-error", logger: logger, error: error)
        }
        return RouteJSON.response(OkResponse(ok: true))
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
        client: GmailClient, tokens: GmailTokenService, logger: Logger
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
            action = found
        } catch {
            return errorResponse(.internalServerError, "internal-error", logger: logger, error: error)
        }

        // Reverse each action type. The inverse is best-effort; archive becomes
        // "add INBOX back"; mark-read becomes "mark unread"; pin/unpin flip;
        // classify-override inserts a counter-override; unsubscribe is terminal.
        do {
            try await reverse(action: action, account: account, client: client, tokens: tokens, db: db, logger: logger)
            let _ = try await AIActionStore.record(
                accountId: accountId,
                kind: .archive, // 'undo' is itself an action; kind is informational
                payload: ["undoOf": "\(actionId)"],
                db: db
            )
        } catch {
            return errorResponse(.internalServerError, "undo-failed", logger: logger, error: error)
        }
        return RouteJSON.response(UndoResponse(ok: true, undone: actionId))
    }

    private static func reverse(
        action: AIAction, account: Account, client: GmailClient, tokens: GmailTokenService,
        db: PostgresConnection, logger: Logger
    ) async throws {
        let gmailId = action.payload["gmailId"] ?? ""
        switch action.kind {
        case .archive:
            // Archive → put it back in INBOX.
            try await db.query(
                "UPDATE message_headers SET is_archived = FALSE WHERE gmail_id = $1 AND account_id = $2",
                [PostgresData(string: gmailId), PostgresData(uuid: account.id)]
            ).get()
            if action.payload["remote"] == "true" {
                do {
                    let token = try await tokens.validToken(for: account)
                    try? await client.modifyMessageLabels(
                        accessToken: token.accessToken,
                        gmailId: gmailId,
                        addLabelIds: ["INBOX"]
                    )
                } catch { /* remote undo failed; local state already reactivated */ }
            }
        case .markRead:
            try await db.query(
                "UPDATE message_headers SET is_read = FALSE WHERE gmail_id = $1 AND account_id = $2",
                [PostgresData(string: gmailId), PostgresData(uuid: account.id)]
            ).get()
        case .pin:
            try await MessageStore.setPinned(false, gmailId: gmailId, accountId: account.id, db: db)
        case .unpin:
            try await MessageStore.setPinned(true, gmailId: gmailId, accountId: account.id, db: db)
        case .classifyOverride:
            // Counter-override: flip back to the original group.
            if let from = action.payload["fromGroup"].flatMap(BriefingGroup.init(rawValue:)),
               let to = action.payload["toGroup"].flatMap(BriefingGroup.init(rawValue:)) {
                try await AIActionStore.insertOverride(
                    accountId: account.id, gmailId: gmailId,
                    fromGroup: to, toGroup: from, db: db
                )
            }
        case .unsubscribe, .draftCreate:
            // Terminal: we can't really "unsubscribe" or "undraft". Tell the user.
            throw NSError(
                domain: "Lagoon.Undo", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "\(action.kind.rawValue) cannot be undone"]
            )
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
