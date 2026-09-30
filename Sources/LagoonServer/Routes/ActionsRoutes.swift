import Foundation
import Hummingbird
import Logging
import GRDB
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
        db: LagoonDB,
        logger: Logger,
        makeProvider: MailProviderFactory.Builder? = nil
    ) {
        let makeProvider = makeProvider
            ?? MailProviderFactory.factory(db: db, logger: logger).builder

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

        // POST /api/messages/{remoteId}/delete?accountId=
        // 删除 = 移入服务器废纸篓（provider.trash），绝不硬抹除。本地只翻
        // `is_deleted` 旗标：邮件离开所有列表/未读数/搜索，撤销即 restore。
        router.post("api/messages/:remoteId/delete") { request, context -> Response in
            return await deleteHandler(
                request: request, context: context, db: db,
                makeProvider: makeProvider, logger: logger
            )
        }

        // POST /api/archive-bulk?accountId=  {remoteIds: [...]}
        // 清扫（Sweep）: local flag claimed first so the sync loop's reconcile
        // cannot delete a row whose remote MOVE is still in flight, then one
        // audit row per id so undo stays per-message. Per-item results —
        // partial success is reported honestly, never thrown away.
        router.post("api/archive-bulk") { request, _ -> Response in
            return await archiveBulkHandler(
                request: request, db: db, makeProvider: makeProvider, logger: logger
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
        request: Request, context: BasicRequestContext, db: LagoonDB,
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
            action = try db.write { raw in
                try MessageStore.setArchivedSync(
                    true, remoteId: remoteId, accountId: accountId, db: raw
                )
                return try AIActionStore.recordSync(
                    accountId: accountId,
                    kind: .archive,
                    payload: ["remoteId": remoteId, "remoteWrite": "true"],
                    db: raw
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

    /// 删除：远端先移入废纸篓，本地再翻旗标。与归档同一套审计/撤销。
    private static func deleteHandler(
        request: Request, context: BasicRequestContext, db: LagoonDB,
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
        guard let provider = makeProvider(account) else {
            return RouteJSON.error(.serviceUnavailable, "provider-not-configured")
        }
        do {
            try await provider.trash(remoteId: remoteId)
        } catch let error as MailError {
            return MessageRoutes.providerError(error, logger: logger, remoteId: remoteId)
        } catch {
            logger.warning("delete.remoteFailed", metadata: [
                "remoteId": .string(remoteId),
                "label": .string(MessageRoutes.providerLabel(error)),
            ])
            return RouteJSON.error(.badGateway, "provider-unreachable")
        }
        let action: AIAction
        do {
            action = try db.write { raw in
                try MessageStore.setDeletedSync(
                    remoteId: remoteId, accountId: accountId, deleted: true, db: raw
                )
                return try AIActionStore.recordSync(
                    accountId: accountId,
                    kind: .delete,
                    payload: [
                        "remoteId": remoteId,
                        "remoteWrite": "true",
                    ],
                    db: raw
                )
            }
        } catch {
            // A local failure must not leave a remote-only move behind.
            do { try await provider.restoreFromTrash(remoteId: remoteId) } catch {
                logger.error("delete.compensationFailed", metadata: [
                    "remoteId": .string(remoteId),
                    "err": .string("\(error)"),
                ])
            }
            return errorResponse(.internalServerError, "internal-error", logger: logger, error: error)
        }
        return RouteJSON.response(ArchiveResponse(
            ok: true,
            remoteId: remoteId,
            remote: true,
            actionId: action.id
        ))
    }

    /// 清扫: claim the local flag, archive every requested id, record one
    /// audit row each so undo stays per-message. Cap 500 so a runaway client
    /// cannot one-shot the provider's rate budget; per-item errors are
    /// reported, not thrown — a sweep that half-succeeded must say so.
    private static func archiveBulkHandler(
        request: Request, db: LagoonDB,
        makeProvider: MailProviderFactory.Builder, logger: Logger
    ) async -> Response {
        guard let accountId = RouteParams.accountId(from: request) else {
            return RouteJSON.error(.badRequest, "malformed-accountId")
        }
        let body: Data
        do { body = try await collectBody(request) } catch {
            return RouteJSON.error(.badRequest, "missing-body")
        }
        struct Req: Decodable { let remoteIds: [String] }
        let req: Req
        do { req = try JSONDecoder().decode(Req.self, from: body) } catch {
            return RouteJSON.error(.badRequest, "invalid-body")
        }
        let ids = Array(req.remoteIds.prefix(500))
        guard !ids.isEmpty else {
            return RouteJSON.error(.badRequest, "empty-remoteIds")
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
        guard let provider = makeProvider(account) else {
            return RouteJSON.error(.serviceUnavailable, "provider-not-configured")
        }
        guard account.capabilities.archiveFolder else {
            return RouteJSON.error(.conflict, "archive-unavailable")
        }

        var items: [ArchiveBulkItem] = []
        for remoteId in ids {
            do {
                // Local placeholder first, remote move second. reconcileInbox
                // deletes every `is_archived = FALSE` row the provider no longer
                // lists, and the remote MOVE is exactly what makes it stop
                // listing it — so a sweep that moved first and flagged second
                // left a window in which the sync loop deleted the row and its
                // body (ON DELETE CASCADE) for a mail the user had just swept.
                // The flag is the claim reconcile respects; commit it before
                // the await that lets reconcile run.
                let claimed = try db.write { raw -> Bool in
                    let wasArchived = try Bool.fetchOne(
                        raw,
                        sql: "SELECT is_archived FROM message_headers WHERE account_id = ? AND remote_id = ?",
                        arguments: [accountId, remoteId]
                    ) ?? false
                    try MessageStore.setArchivedSync(
                        true, remoteId: remoteId, accountId: accountId, db: raw
                    )
                    return !wasArchived
                }
                do {
                    try await provider.archive(remoteId: remoteId)
                } catch {
                    // The remote never moved, so the placeholder must not
                    // outlive it — otherwise the mail disappears from the inbox
                    // view for a move that never happened.
                    if claimed {
                        try? db.write {
                            try MessageStore.setArchivedSync(
                                false, remoteId: remoteId, accountId: accountId, db: $0
                            )
                        }
                    }
                    throw error
                }
                // The placeholder is already committed; this only re-asserts it
                // so the audit row and the flag it describes land together,
                // as they do in the single-message route.
                let action = try db.write { raw in
                    try MessageStore.setArchivedSync(
                        true, remoteId: remoteId, accountId: accountId, db: raw
                    )
                    return try AIActionStore.recordSync(
                        accountId: accountId,
                        kind: .archive,
                        payload: ["remoteId": remoteId, "remoteWrite": "true"],
                        db: raw
                    )
                }
                items.append(ArchiveBulkItem(remoteId: remoteId, ok: true, actionId: action.id))
            } catch let error as MailError {
                // Same label the per-message route would return; logged there,
                // reported here — a sweep that half-succeeded says so.
                logger.warning("provider.requestFailed", metadata: [
                    "remoteId": .string(remoteId),
                    "label": .string(error.logLabel),
                ])
                items.append(ArchiveBulkItem(
                    remoteId: remoteId, ok: false, errorCode: error.logLabel
                ))
            } catch {
                // The item is reported as failed either way: the flag claim
                // could not be written, the provider failed in a way Lagoon
                // does not model, or the mail is archived on both sides with
                // no undo entry. None of them can promise a per-message undo.
                logger.error("archiveBulk.itemFailed", metadata: [
                    "remoteId": .string(remoteId),
                    "err": .string("\(error)"),
                ])
                items.append(ArchiveBulkItem(remoteId: remoteId, ok: false, errorCode: "internal-error"))
            }
        }
        return RouteJSON.response(ArchiveBulkResponse(items: items))
    }

    // MARK: - Unsubscribe

    private static func unsubscribeHandler(
        request: Request, context: BasicRequestContext, db: LagoonDB,
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

        // Resolution order for 一键退订:
        //   1. live List-Unsubscribe header (parsed by the same scanner as
        //      the body, so bare unbracketed URLs work too). A companion
        //      List-Unsubscribe-Post header (RFC 8058) upgrades the hit to
        //      a true one-click POST: no page, no click at all.
        //   2. links harvested earlier (sync-time header + first-open body)
        //   3. the HTML body, fetched and scanned on the spot
        // A failed header read no longer aborts the chain: stored links may
        // still resolve offline; the error is only returned when nothing
        // resolves (a 422 would falsely claim "no link" when we could not
        // check at all). Healthy read + nothing found → 422
        // unsubscribe-unavailable → the UI shows "未检测到退订链接".
        // Every fetched URL — including every redirect hop — passes the SSRF guard.
        // 4. nothing automatable anywhere, but some stage offered a
        //    mailto: → 422 unsubscribe-manual-required (only after ALL
        //    three stages ran: a mailto in the header must not short-
        //    circuit an https link in the stored list or the body)
        var target: (url: URL, publisher: String)?
        var headerFailureResponse: Response?
        var bodyFailureResponse: Response?
        var oneClickHeader = false
        /// Whether the chosen target is the URL the sender named in
        /// `List-Unsubscribe`. RFC 8058 §3 defines the one-click POST against
        /// exactly that URL; the flag is meaningless for a link scraped out of
        /// the body, and firing it there would hand an attacker a POST
        /// primitive aimed wherever the message body points.
        var targetFromHeader = false
        /// A mailto: was offered by some stage. Accumulated, NOT acted on
        /// immediately: headerLinks/bodyLinks admit the mailto scheme and the
        /// sync-time writers persist it, so bailing out per stage meant a
        /// mailto-only header 422'd a message whose body had a real link.
        var sawMailto = false
        do {
            let headers = try await provider.fetchRawHeaderValues(remoteId: remoteId)
            if let post = headers.first(where: { $0.key.lowercased() == "list-unsubscribe-post" })?.value {
                oneClickHeader = post.lowercased().contains("one-click")
            }
            if let raw = headers.first(where: { $0.key.lowercased() == "list-unsubscribe" })?.value {
                switch await pickUnsubTarget(links: UnsubscribeScanner.headerLinks(raw)) {
                case .http(let url, let pub):
                    // Publisher = the host we actually chose, not the first
                    // URL in the header (they can differ, and the first URL
                    // may be the one we skipped as unsafe).
                    target = (url, pub)
                    targetFromHeader = true
                case .manual:
                    sawMailto = true
                case nil:
                    break
                }
            }
        } catch let error as MailError {
            headerFailureResponse = MessageRoutes.providerError(error, logger: logger, remoteId: remoteId)
        } catch {
            logger.warning("unsubscribe.fetchFailed", metadata: [
                "remoteId": .string(remoteId),
                "label": .string(MessageRoutes.providerLabel(error)),
            ])
            headerFailureResponse = RouteJSON.error(.badGateway, "provider-unreachable")
        }

        if target == nil {
            switch await pickUnsubTarget(links: storedUnsubscribeLinks(
                remoteId: remoteId, accountId: accountId, db: db
            )) {
            case .http(let url, let pub):
                target = (url, pub)
            case .manual:
                sawMailto = true
            case nil:
                break
            }
        }

        if target == nil {
            // A body-fetch failure must NOT be swallowed into a 422: we did
            // not find "no link", we could not look. It is kept in its own
            // slot and preferred over the 422 (the invariant the header stage
            // already implements).
            do {
                let body = try await MessageRoutes.fetchBody(
                    account: account, remoteId: remoteId, provider: provider, db: db, logger: logger
                )
                let links = UnsubscribeScanner.bodyLinks(in: body.html ?? body.text)
                if !links.isEmpty {
                    // Persist the discovery for next time (best-effort).
                    try? await MessageStore.mergeUnsubscribeLinks(
                        remoteId: remoteId, accountId: accountId, links: links, db: db
                    )
                    switch await pickUnsubTarget(links: links) {
                    case .http(let url, let pub):
                        target = (url, pub)
                    case .manual:
                        sawMailto = true
                    case nil:
                        break
                    }
                }
            } catch let error as MailError {
                bodyFailureResponse = MessageRoutes.providerError(
                    error, logger: logger, remoteId: remoteId
                )
            } catch {
                logger.warning("unsubscribe.bodyFetchFailed", metadata: [
                    "remoteId": .string(remoteId),
                    "label": .string(MessageRoutes.providerLabel(error)),
                ])
                bodyFailureResponse = RouteJSON.error(.badGateway, "provider-unreachable")
            }
        }

        guard let target else {
            // Could-not-check (provider error) is not the same as no-link.
            if let headerFailureResponse { return headerFailureResponse }
            if let bodyFailureResponse { return bodyFailureResponse }
            if sawMailto {
                return RouteJSON.error(.unprocessableContent, "unsubscribe-manual-required")
            }
            return RouteJSON.error(.unprocessableContent, "unsubscribe-unavailable")
        }
        let publisher = target.publisher
        let unsubscribeURL = target.url

        let outcome: UnsubHit
        do {
            // RFC 8058 §3: the one-click POST is defined against the https
            // URL named in `List-Unsubscribe`, so it requires both the header
            // flag and a target that actually came from that header.
            let mayOneClick = oneClickHeader
                && targetFromHeader
                && unsubscribeURL.scheme?.lowercased() == "https"
            outcome = try await hitUnsubscribe(url: unsubscribeURL, oneClick: mayOneClick)
        } catch {
            logger.warning("unsubscribe.requestFailed", metadata: [
                "remoteId": .string(remoteId),
                "label": .string(MessageRoutes.providerLabel(error)),
            ])
            return RouteJSON.error(.badGateway, "unsubscribe-failed")
        }
        switch outcome {
        case .completed:
            break
        case .landingPage:
            // 2xx, but the final page still offers an unsubscribe entry —
            // a tracking redirect landed on an instructions page, not a
            // completed unsubscribe. Recording success here would archive
            // the mail and lie to the user.
            return RouteJSON.error(.unprocessableContent, "unsubscribe-page-required")
        case .failed:
            return RouteJSON.error(.badGateway, "unsubscribe-failed")
        }

        let action: AIAction
        do {
            action = try db.write { raw in
                try raw.execute(
                    sql: "UPDATE message_headers SET is_archived = TRUE, is_read = TRUE WHERE remote_id = ? AND account_id = ?",
                    arguments: [remoteId, accountId]
                )
                return try AIActionStore.recordSync(
                    accountId: accountId,
                    kind: .unsubscribe,
                    payload: [
                        "remoteId": remoteId,
                        "publisher": publisher,
                        "remote": "true",
                    ],
                    db: raw
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
        request: Request, context: BasicRequestContext, db: LagoonDB, logger: Logger
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
                        pinnedRemoteIds: pinned,
                        listUnsubscribeRemoteIds: unsubscribed
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
            action = try db.write { raw in
                try AIActionStore.insertOverrideSync(
                    accountId: accountId,
                    remoteId: remoteId,
                    fromGroup: fromGroup,
                    toGroup: toGroup,
                    db: raw
                )
                return try AIActionStore.recordSync(
                    accountId: accountId,
                    kind: .classifyOverride,
                    payload: [
                        "remoteId": remoteId,
                        "fromGroup": fromGroup.rawValue,
                        "toGroup": toGroup.rawValue,
                    ],
                    db: raw
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
        request: Request, context: BasicRequestContext, db: LagoonDB, logger: Logger
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
        request: Request, context: BasicRequestContext, db: LagoonDB,
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

        // Single-use, and the claim is taken before the inverse runs. The
        // inverse is not idempotent — replaying an archive-undo moves a
        // message out of a folder it has already left — and the read that
        // answers "already undone?" used to live in its own read transaction
        // with a whole IMAP round trip before the undo row was inserted, so
        // two concurrent undos (⌘Z has no in-flight guard) both passed the
        // check and both ran the inverse. One write transaction closes that.
        let claim: UndoClaim
        do {
            claim = try db.write { raw in
                guard let action = try AIActionStore.findSync(id: actionId, db: raw),
                      action.accountId == accountId
                else { throw UndoRejection.unknownAction }
                if let expiresAt = action.expiresAt, expiresAt <= Date() {
                    throw UndoRejection.expired
                }
                if try AIActionStore.isUndoneSync(id: actionId, accountId: accountId, db: raw) {
                    throw UndoRejection.alreadyUndone
                }
                let row = try AIActionStore.recordSync(
                    accountId: accountId,
                    kind: .undo,
                    payload: ["undoOf": "\(actionId)"],
                    db: raw
                )
                return UndoClaim(action: action, rowId: row.id)
            }
        } catch let rejection as UndoRejection {
            return rejection.response
        } catch {
            return errorResponse(.internalServerError, "internal-error", logger: logger, error: error)
        }

        // Reverse each action type. Archive/read restore the remote state first;
        // pin/unpin flip locally; classify-override inserts a counter-override;
        // unsubscribe, send, drafting and undo itself are terminal.
        do {
            try await reverse(
                action: claim.action, account: account,
                makeProvider: makeProvider, db: db, logger: logger
            )
        } catch let error as NotUndoable {
            await releaseClaim(claim, actionId: actionId, db: db, logger: logger)
            logger.info("actions.notUndoable", metadata: [
                "kind": .string(error.kind.rawValue),
                "actionId": .string("\(actionId)"),
            ])
            return RouteJSON.error(.badRequest, "not-undoable")
        } catch {
            await releaseClaim(claim, actionId: actionId, db: db, logger: logger)
            return errorResponse(.internalServerError, "undo-failed", logger: logger, error: error)
        }
        return RouteJSON.response(UndoResponse(ok: true, undone: actionId))
    }

    /// The action being undone plus the id of the undo row that claims it.
    private struct UndoClaim {
        let action: AIAction
        let rowId: Int64
    }

    /// The inverse threw, so the claim has to go back: an action that still
    /// reads as "undone" after a failed undo is the one state single-use
    /// undo must never leave behind. Best-effort — the next attempt hits the
    /// same stale claim and is refused, which is the safe direction.
    private static func releaseClaim(
        _ claim: UndoClaim, actionId: Int64, db: LagoonDB, logger: Logger
    ) async {
        do {
            try await AIActionStore.deleteUndo(id: claim.rowId, db: db)
        } catch {
            logger.error("undo.claimReleaseFailed", metadata: [
                "actionId": .string("\(actionId)"),
                "err": .string("\(error)"),
            ])
        }
    }

    /// Why the claim was refused, with the status each answer already had.
    private enum UndoRejection: Error {
        case unknownAction
        case expired
        case alreadyUndone

        var response: Response {
            switch self {
            case .unknownAction: return RouteJSON.error(.notFound, "unknown-action")
            case .expired: return RouteJSON.error(.gone, "action-expired")
            case .alreadyUndone: return RouteJSON.error(.conflict, "already-undone")
            }
        }
    }

    private static func reverse(
        action: AIAction, account: Account,
        makeProvider: MailProviderFactory.Builder,
        db: LagoonDB, logger: Logger
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
            try db.write {
                try $0.execute(
                    sql: "UPDATE message_headers SET is_archived = FALSE WHERE remote_id = ? AND account_id = ?",
                    arguments: [remoteId, account.id]
                )
            }
            // Undoing an auto-archive retires its rule (V2 C2): otherwise the
            // next sync round re-archives the same sender and the undo was a
            // lie. Sender prefers the action payload and falls back to the
            // stored header for rows recorded before the payload carried it.
            if action.payload["autoRule"] == "true" {
                var sender = action.payload["sender"]
                if sender == nil {
                    sender = try? await MessageStore.find(
                        remoteId: remoteId, accountId: account.id, db: db
                    )?.fromAddress
                }
                if let sender {
                    // Best-effort: the message already came back, so a rule
                    // cleanup failure must not fail the undo.
                    do {
                        try await AutoArchiveStore.deleteSender(sender, accountId: account.id, db: db)
                    } catch {
                        logger.warning("undo.autoRuleCleanupFailed", metadata: [
                            "actionId": .string("\(action.id)"),
                            "err": .string("\(error)"),
                        ])
                    }
                }
            }
        case .markRead:
            guard let provider = makeProvider(account) else {
                throw MailError.notConfigured("provider missing during undo")
            }
            try await provider.setRead(remoteId: remoteId, isRead: false)
            try await MessageStore.setRead(remoteId: remoteId, accountId: account.id, isRead: false, db: db)
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
        case .delete:
            // 从废纸篓移回 INBOX——远端先动，再翻回本地旗标。
            guard let provider = makeProvider(account) else {
                throw MailError.notConfigured("provider missing during undo")
            }
            if action.payload["remoteWrite"] == "true" {
                try await provider.restoreFromTrash(remoteId: remoteId)
            }
            try await MessageStore.setDeleted(
                remoteId: remoteId, accountId: account.id, deleted: false, db: db
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
        try await RouteParams.collectBody(request)
    }

    /// Pulls the first usable URL out of a `List-Unsubscribe` header. The header
    /// can contain `<mailto:…>`, `<https://…>`, or bare URLs. We prefer https.
    private enum UnsubTarget {
        case http(URL, String)
        case manual
    }

    /// First usable candidate: any safe http(s) URL wins (一键优先); a
    /// mailto: only reports "manual required" when nothing automatable
    /// exists. Unsafe candidates are skipped.
    ///
    /// Among the safe candidates https beats http. The unsubscribe URL *is*
    /// the capability — anyone who sees the request can replay it — so
    /// sending it in cleartext hands the unsubscribe to every network
    /// observer. Senders do advertise both schemes for the same path.
    ///
    /// The caller ACCUMULATES `.manual` across stages instead of returning it
    /// on sight — see the handler.
    private static func pickUnsubTarget(links: [String]) async -> UnsubTarget? {
        var manual = false
        var insecureFallback: (URL, String)?
        for candidate in links {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: trimmed),
                  let scheme = url.scheme?.lowercased()
            else { continue }
            if scheme == "mailto" {
                manual = true
                continue
            }
            guard scheme == "http" || scheme == "https" else { continue }
            guard await UnsubscribeScanner.isSafe(url: url) else { continue }
            if scheme == "https" { return .http(url, url.host ?? "") }
            if insecureFallback == nil { insecureFallback = (url, url.host ?? "") }
        }
        if let insecureFallback { return .http(insecureFallback.0, insecureFallback.1) }
        return manual ? .manual : nil
    }

    /// Harvested candidates from the header row; empty on any read failure
    /// (the caller falls through to the live body scan).
    private static func storedUnsubscribeLinks(
        remoteId: String, accountId: UUID, db: LagoonDB
    ) async -> [String] {
        (try? await MessageStore.unsubscribeLinks(
            remoteId: remoteId, accountId: accountId, db: db
        )) ?? []
    }

    /// Outcome of hitting an unsubscribe endpoint — 2xx alone is NOT success:
    /// a tracking link can 302 to a "how to leave" page that merely *offers*
    /// an unsubscribe entry, and recording that as done would archive the
    /// mail and leave the user subscribed.
    enum UnsubHit {
        case completed
        case landingPage
        case failed
    }

    /// Best-effort unsubscribe against the chosen endpoint. When the sender
    /// advertised RFC 8058 one-click support, a POST with the standard body
    /// *is* the unsubscribe — no page, no extra click. Otherwise a single GET
    /// (the tokenized tracking-link unsubscribe, by far the most common).
    ///
    /// The old blind POST-before-GET is gone: POSTing a GET-shaped link
    /// usually returned a 200 landing page whose "manage preferences" footer
    /// then made `classifyHit` report "needs manual" — and the GET, the one
    /// request that would actually have unsubscribed, never ran.
    ///
    /// Redirects go through the session's delegate: EVERY hop is re-checked
    /// against the SSRF guard, because a public URL that 302s to loopback or
    /// 169.254.169.254 would otherwise defeat `isSafe`. An unsafe hop cancels
    /// the task (fail closed).
    ///
    /// ponytail: ceiling — one wall-clock budget for ALL attempts
    /// (`unsubscribeTimeout`), a streaming body cap (`maxUnsubscribeBodyBytes`)
    /// and a per-attempt timeout. The budget is enforced by cancelling the
    /// task group, so the hard floor is "whatever URLSession still owes us":
    /// if the transport ignored cancellation the worst case degrades to
    /// per-attempt timeouts, not to an unbounded hang.
    static func hitUnsubscribe(
        url: URL, oneClick: Bool = false, session: URLSession = guardedSession
    ) async throws -> UnsubHit {
        #if DEBUG
        // ponytail: seam for offline route tests — absent from release builds.
        if let probe = hitUnsubscribeProbe { return try await probe(url) }
        #endif
        return try await withThrowingTaskGroup(of: UnsubHit.self) { group in
            group.addTask { try await Self.attemptUnsubscribe(url: url, oneClick: oneClick, session: session) }
            group.addTask {
                try await Task.sleep(for: Self.unsubscribeTimeout)
                throw URLError(.timedOut)
            }
            let first = try await group.next() ?? .failed
            group.cancelAll()
            return first
        }
    }

    /// RFC 8058 one-click POST when the sender advertised it (the POST body
    /// is mandated by the RFC), then one GET. 2xx only is a candidate for
    /// success; anything else is not. In particular a 3xx must NEVER be
    /// classified: with the redirect guard in place a 3xx that reaches us is
    /// either a hop the guard refused or a chain the server cut short —
    /// recording that as completed would archive the mail and tell the user
    /// they unsubscribed.
    private static func attemptUnsubscribe(
        url: URL, oneClick: Bool, session: URLSession
    ) async throws -> UnsubHit {
        if oneClick {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 10
            request.setValue("Lagoon/1.0", forHTTPHeaderField: "User-Agent")
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("List-Unsubscribe=One-Click".utf8)
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch let error as URLError where error.code == .cancelled {
                // A refused redirect hop or a body past the streaming cap:
                // a deliberate stop, not a transport fault.
                return .failed
            }
            if let http = response as? HTTPURLResponse {
                if (200..<300).contains(http.statusCode) {
                    return await classifyAndConfirm(data: data, session: session)
                }
                if (300..<400).contains(http.statusCode) { return .failed }
                // 4xx/5xx: the endpoint rejected the POST (405-style). Fall
                // through to the GET rather than reporting failure — some
                // senders advertise the header but only serve the link.
            }
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Lagoon/1.0", forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            return .failed
        }
        guard let http = response as? HTTPURLResponse else { return .failed }
        if (200..<300).contains(http.statusCode) {
            return await classifyAndConfirm(data: data, session: session)
        }
        if (300..<400).contains(http.statusCode) { return .failed }
        return .failed
    }

    /// ponytail: a 2xx body is "completed" unless it re-offers unsubscribe
    /// links (same scanner as the email body) — a confirmation page with a
    /// preferences-center footer must not auto-complete as a false success.
    /// Success phrases are checked FIRST: the typical confirmation page ends
    /// with "you have been unsubscribed" while still linking to a preferences
    /// centre, and the old link-only rule read that as "needs manual" — the
    /// single largest source of "明明退订了却提示失败".
    static func classifyHit(data: Data) -> UnsubHit {
        guard let body = String(data: data, encoding: .utf8) else { return .completed }
        if containsSuccessSignal(body) { return .completed }
        if UnsubscribeScanner.bodyLinks(in: body).isEmpty { return .completed }
        return .landingPage
    }

    /// English phrases are worded so a confirmation *ask* ("you are about to
    /// be unsubscribed") does not match — it lacks the completed tense.
    private static let successSignals = [
        "successfully unsubscribed", "have been unsubscribed",
        "has been unsubscribed", "you've been unsubscribed",
        "you are unsubscribed", "you're unsubscribed", "you're now unsubscribed",
        "no longer subscribed", "removed from our mailing list",
        "removed from our list", "removed you from",
        "退订成功", "已退订", "已为您退订", "已成功退订", "已取消订阅", "取消订阅成功",
    ]

    static func containsSuccessSignal(_ body: String) -> Bool {
        let lower = body.lowercased()
        return successSignals.contains { lower.contains($0) }
    }

    /// 2xx but judged a landing page → follow the page's own confirm entry
    /// ONCE and judge that response by the same rules. This is the click the
    /// user used to have to make by hand ("链接点进去还需要再点一次"); now the
    /// server makes it. Depth is capped at one: a page that is still ambiguous
    /// after the follow-up is honestly manual, never a guessed success.
    static func classifyAndConfirm(data: Data, session: URLSession) async -> UnsubHit {
        let first = classifyHit(data: data)
        guard first == .landingPage else { return first }
        guard let body = String(data: data, encoding: .utf8),
              let candidate = UnsubscribeScanner.confirmLink(in: body),
              let url = URL(string: candidate),
              await UnsubscribeScanner.isSafe(url: url)
        else { return .landingPage }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Lagoon/1.0", forHTTPHeaderField: "User-Agent")
        let data2: Data
        let response2: URLResponse
        do {
            (data2, response2) = try await session.data(for: request)
        } catch {
            return .landingPage
        }
        guard let http = response2 as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else { return .landingPage }
        return classifyHit(data: data2)
    }

    /// Streaming cap on the unsubscribe response: `data(for:)` would buffer
    /// an attacker-chosen body whole before we ever regex it. Past the cap the
    /// task is failed, which the attempt loop reports as `.failed`.
    static let maxUnsubscribeBodyBytes = 256 * 1024
    /// Wall-clock budget covering both the POST and the GET attempt.
    static let unsubscribeTimeout: Duration = .seconds(30)

    #if DEBUG
    /// ponytail: seam for offline route tests; absent from release builds, so
    /// the production binary cannot be talked into skipping the SSRF-guarded
    /// session.
    static var hitUnsubscribeProbe: (@Sendable (URL) async throws -> UnsubHit)?
    #endif

    private static let guardedSession: URLSession = makeProbeSession()

    /// The one session the unsubscribe probe uses: SSRF-checked redirects and
    /// a streaming body cap in one delegate. Internal so tests can build the
    /// same session over a stub `URLProtocol`.
    static func makeProbeSession(maxBodyBytes: Int = maxUnsubscribeBodyBytes) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        return URLSession(
            configuration: config,
            delegate: RedirectGuard(maxBodyBytes: maxBodyBytes),
            delegateQueue: nil
        )
    }

    /// Re-validates each redirect hop against the SSRF guard — the P0 fix
    /// for "public URL redirects to an internal target" — and caps how much of
    /// the response we are willing to buffer.
    final class RedirectGuard: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate {
        private let maxBodyBytes: Int
        private let lock = NSLock()
        private var received: [Int: Int] = [:]

        init(maxBodyBytes: Int) {
            self.maxBodyBytes = maxBodyBytes
            super.init()
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            guard let url = request.url else {
                task.cancel()
                completionHandler(nil)
                return
            }
            Task {
                if await UnsubscribeScanner.isSafe(url: url) {
                    completionHandler(request)
                } else {
                    task.cancel()
                    completionHandler(nil)
                }
            }
        }

        /// This must match `URLSessionDataDelegate`'s requirement exactly.
        /// There is no `completionHandler:` variant of this method in the
        /// protocol: a signature that merely *resembles* it compiles with a
        /// "nearly matches optional requirement" warning and is then never
        /// called by URLSession at all, which silently disables the cap.
        func urlSession(
            _ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data
        ) {
            lock.lock()
            let total = (received[dataTask.taskIdentifier] ?? 0) + data.count
            received[dataTask.taskIdentifier] = total
            lock.unlock()
            if total > maxBodyBytes {
                // Cancelling is the only way to stop a `data(for:)` read: the
                // call then throws `.cancelled`, which the attempt loop
                // reports as `.failed`.
                dataTask.cancel()
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.lock()
            received[task.taskIdentifier] = nil
            lock.unlock()
        }
    }
}
