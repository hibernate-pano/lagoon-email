import Foundation
import Hummingbird
import Logging
import GRDB
import LagoonKit

struct ArchiveResponse: Encodable { let ok: Bool; let remoteId: String; let remote: Bool; let actionId: Int64 }

/// 彻底删除 response.
///
/// No `actionId`, and that absence is deliberate: the client shows no undo
/// toast for a purge because there is nothing to undo, and returning an id here
/// would invite a ⌘Z that the undo route would (correctly) reject. `purged` is
/// the count of local rows removed — 1 for the single-message route, N for
/// 清空废纸篓, 0 for a trash that was already empty.
struct PurgeResponse: Encodable { let ok: Bool; let remoteId: String; let purged: Int }
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

        // POST /api/messages/{remoteId}/unarchive?accountId=
        // 取消归档：把邮件从档案柜移回收件箱。
        //
        // Why this route exists when `unarchive` was already reachable through
        // undo: undo is an 8-second toast. Archive is not a 8-second decision —
        // a user files a newsletter away in March and wants it back in
        // September. Without this route, archiving is a one-way door and the
        // 档案柜 is a place mail goes to be forgotten, which is the opposite of
        // what an archive is for.
        //
        // Audited and undoable like every other verb, so moving a message back
        // is itself reversible (⌘Z re-archives it).
        router.post("api/messages/:remoteId/unarchive") { request, context -> Response in
            return await unarchiveHandler(
                request: request, context: context, db: db,
                makeProvider: makeProvider, logger: logger
            )
        }

        // POST /api/messages/{remoteId}/restore?accountId=
        // 从废纸篓恢复。同上：undo 的 8 秒窗口不等于"可恢复"。
        router.post("api/messages/:remoteId/restore") { request, context -> Response in
            return await restoreHandler(
                request: request, context: context, db: db,
                makeProvider: makeProvider, logger: logger
            )
        }

        // POST /api/messages/{remoteId}/purge?accountId=
        // 彻底删除：把邮件从服务器 Trash 永久抹掉。**不可撤销。**
        //
        // 规则约束按用户 2026-10-05 的决定放宽：早先的宪法 §2 要求所有变更
        // 可撤销，而这一条天然违反。放宽后仍然保留三道闸门，因为「不可撤销」
        // 说的是**没有撤销路径**，不是**可以随便触发**：
        //
        //   1. 必须先在废纸篓里（软删除是本路由的前置条件）
        //   2. 只能由用户显式点击触发，绝无自动路径
        //   3. 远端 UID EXPUNGE 成功后才删本地行，失败则本地完全不动
        //
        // 第 3 条是唯一真正防止数据损失的那道：先动远端、后删本地，中途失败
        // 只会留下一条孤儿记录（可重试），反过来则会永久丢失且无法恢复。
        router.post("api/messages/:remoteId/purge") { request, context -> Response in
            return await purgeHandler(
                request: request, context: context, db: db,
                makeProvider: makeProvider, logger: logger
            )
        }

        // POST /api/trash/empty?accountId=
        // 清空废纸篓。逐封本地硬删除，远端一次 UID EXPUNGE 批量。
        router.post("api/trash/empty") { request, _ -> Response in
            return await emptyTrashHandler(
                request: request, db: db, makeProvider: makeProvider, logger: logger
            )
        }

        // POST /api/delete-bulk?accountId=  {remoteIds: [...]} | {allMatching: true, lens}
        // 批量删除：the counterpart to `/api/archive-bulk`. Its absence was the
        // reason deleting 50 messages meant firing 50 single-message requests.
        //
        // `allMatching` is what makes Gmail's two-stage select-all possible from
        // the client side: the list is a window, so "everything" is a *query*,
        // not a list of ids the client never received. The server resolves it
        // against the same filter the list uses, so the two cannot disagree.
        router.post("api/delete-bulk") { request, _ -> Response in
            return await deleteBulkHandler(
                request: request, db: db, makeProvider: makeProvider, logger: logger
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

        // POST /api/actions/undo-bulk?accountId=  {actionIds: [...]}
        // One ⌘Z for a bulk operation. "Mark all as read" records one audit
        // row per message; undoing only the newest would leave the rest in
        // place and read to the user as "undo did nothing". Per-item results,
        // partial success reported honestly — same shape as archive-bulk.
        router.post("api/actions/undo-bulk") { request, _ -> Response in
            return await undoBulkHandler(
                request: request, db: db,
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

    // MARK: - Unarchive / Restore
    //
    // These two are the mirror images of `archiveHandler` / `deleteHandler`,
    // and deliberately so: same capability gate, same remote-then-local order,
    // same compensation on local failure, same audit row. Writing them as a
    // separate shape would be how a restore ends up "mostly working" — remote
    // move but no local flag, or a local flag with no audit row so ⌘Z silently
    // does nothing.

    /// 取消归档：远端移回收件箱，本地翻 `is_archived = FALSE`。
    private static func unarchiveHandler(
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
        // Same gate as archive, and for the same reason: if the provider cannot
        // find an archive folder there is nothing to move out of, and a 409
        // leaves both sides untouched.
        guard account.capabilities.archiveFolder else {
            return RouteJSON.error(.conflict, "archive-unavailable")
        }
        guard let provider = makeProvider(account) else {
            return RouteJSON.error(.serviceUnavailable, "provider-not-configured")
        }
        do {
            try await provider.unarchive(remoteId: remoteId)
        } catch let error as MailError {
            return MessageRoutes.providerError(error, logger: logger, remoteId: remoteId)
        } catch {
            logger.warning("unarchive.remoteFailed", metadata: [
                "remoteId": .string(remoteId),
                "label": .string(MessageRoutes.providerLabel(error)),
            ])
            return RouteJSON.error(.badGateway, "provider-unreachable")
        }

        let action: AIAction
        do {
            action = try db.write { raw in
                try MessageStore.setArchivedSync(
                    false, remoteId: remoteId, accountId: accountId, db: raw
                )
                return try AIActionStore.recordSync(
                    accountId: accountId,
                    kind: .archive,
                    payload: [
                        "remoteId": remoteId,
                        "remoteWrite": "true",
                        // The inverse of this action is "archive again", which
                        // is the same kind with the opposite local flag. Without
                        // the marker, undo would restore the flag to whatever the
                        // default is rather than to the state this action
                        // replaced.
                        "restoreTo": "archived",
                    ],
                    db: raw
                )
            }
        } catch {
            // Compensation: the remote MOVE already happened. Put it back
            // rather than leaving the message archived in the server and live
            // in the list — the exact split-brain the archive path guards.
            do {
                try await provider.archive(remoteId: remoteId)
            } catch {
                logger.error("unarchive.compensationFailed", metadata: [
                    "remoteId": .string(remoteId),
                    "err": .string("\(error)"),
                ])
            }
            logger.error("unarchive.localUpdateFailed", metadata: [
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

    /// 从废纸篓恢复：远端移回收件箱，本地翻 `is_deleted = FALSE`。
    ///
    /// Deliberately *not* recorded as an undoable action in the same way delete
    /// is: the toast from the original delete already covers the "I deleted
    /// this by accident" case, and this route exists for the case it does not
    /// cover — "I deleted this a week ago and need it back". The audit row is
    /// still written, so the action history stays a complete record of what
    /// Lagoon did to the mailbox (constitution §3).
    private static func restoreHandler(
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
            try await provider.restoreFromTrash(remoteId: remoteId)
        } catch let error as MailError {
            return MessageRoutes.providerError(error, logger: logger, remoteId: remoteId)
        } catch {
            logger.warning("restore.remoteFailed", metadata: [
                "remoteId": .string(remoteId),
                "label": .string(MessageRoutes.providerLabel(error)),
            ])
            return RouteJSON.error(.badGateway, "provider-unreachable")
        }

        let action: AIAction
        do {
            action = try db.write { raw in
                try MessageStore.setDeletedSync(
                    remoteId: remoteId, accountId: accountId, deleted: false, db: raw
                )
                return try AIActionStore.recordSync(
                    accountId: accountId,
                    kind: .delete,
                    payload: [
                        "remoteId": remoteId,
                        "remoteWrite": "true",
                        "restoreTo": "live",
                    ],
                    db: raw
                )
            }
        } catch {
            // Compensation: the message is already back in the inbox remotely.
            // Re-trash it so the server and the local flag still agree.
            do {
                try await provider.trash(remoteId: remoteId)
            } catch {
                logger.error("restore.compensationFailed", metadata: [
                    "remoteId": .string(remoteId),
                    "err": .string("\(error)"),
                ])
            }
            logger.error("restore.localUpdateFailed", metadata: [
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

    // MARK: - 彻底删除

    /// 彻底删除 one message. 远端先 UID EXPUNGE，本地再抹掉全部痕迹。
    ///
    /// ## 为什么远端先、且失败时不删本地
    ///
    /// 顺序反过来会永久丢数据：先删本地再动远端，远端失败时本地已经没有了，
    /// 用户既看不到邮件也无法重试。反过来最坏情况是留下一条孤儿本地行，
    /// 可以重试、可以在下一次同步被reconcile 清掉——**可恢复的错比不可恢复
    /// 的错好得多**。
    ///
    /// ## 为什么需要审计行
    ///
    /// 邮件本身没了，但"Lagoon 在何时彻底删除了它"必须留下。这是宪法 §3 对
    /// 这个产品最硬的要求：可以什么都不做，但做过的事必须说得清。
    private static func purgeHandler(
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

        // Gate: the message must already be in the Trash.
        //
        // This is what keeps 彻底删除 from becoming a second, quieter delete.
        // Without it, a single API call would permanently remove a message the
        // user still has in their inbox and could still restore from the undo
        // toast — the irreversibility would arrive before the intent.
        let isTrashed: Bool
        do {
            isTrashed = try db.read { raw in
                let row = try Row.fetchOne(
                    raw,
                    sql: """
                        SELECT is_deleted FROM message_headers
                        WHERE account_id = ? AND remote_id = ?
                        """,
                    arguments: [accountId, remoteId]
                )
                return row.map { ($0["is_deleted"] as Bool?) ?? false } ?? false
            }
        } catch {
            return errorResponse(.internalServerError, "internal-error", logger: logger, error: error)
        }
        guard isTrashed else {
            // 409, not 404: the message exists, the request just does not make
            // sense yet. A 404 would tell the user it is gone when it is not.
            return RouteJSON.error(.conflict, "not-in-trash")
        }

        do {
            try await provider.permanentlyDelete(remoteId: remoteId)
        } catch let error as MailError {
            return MessageRoutes.providerError(error, logger: logger, remoteId: remoteId)
        } catch {
            logger.warning("purge.remoteFailed", metadata: [
                "remoteId": .string(remoteId),
                "label": .string(MessageRoutes.providerLabel(error)),
            ])
            return RouteJSON.error(.badGateway, "provider-unreachable")
        }

        // Remote is gone; now the local trace. Deliberately no undo toast on
        // the client — an action id here would invite a ⌘Z that cannot work.
        do {
            try db.write { raw in
                try MessageStore.hardDeleteSync(
                    remoteId: remoteId, accountId: accountId, db: raw
                )
                // Discarded on purpose: a purge audit row exists to record
                // that the app did this, not to be undone — there is no ⌘Z
                // for an irreversible act (see the handler's own note above).
                _ = try AIActionStore.recordSync(
                    accountId: accountId,
                    kind: .purge,
                    // remoteId is kept in the audit row even though the message
                    // it refers to no longer exists — that is the point of an
                    // audit row, and nothing reads it as a live foreign key.
                    payload: ["remoteId": remoteId, "permanent": "true"],
                    db: raw
                )
            }
        } catch {
            // The remote deletion already happened. Log loudly rather than
            // pretending to compensate: there is nothing to compensate *to*.
            // The leftover local row is inert (nothing lists it) and the next
            // sync's reconcile will not find it on the server.
            logger.error("purge.localCleanupFailed", metadata: [
                "remoteId": .string(remoteId),
                "err": .string("\(error)"),
            ])
            return RouteJSON.error(.internalServerError, "internal-error")
        }
        return RouteJSON.response(PurgeResponse(ok: true, remoteId: remoteId, purged: 1))
    }

    /// 清空废纸篓。
    ///
    /// The count reported is the number of **local** rows that were removed and
    /// the remote expunge is a single call, so "deleted 12" is a claim about
    /// this app's records rather than a count the server returned. That
    /// asymmetry is stated here because it is the one place the number the user
    /// sees is not a number the provider confirmed.
    private static func emptyTrashHandler(
        request: Request, db: LagoonDB,
        makeProvider: MailProviderFactory.Builder, logger: Logger
    ) async -> Response {
        guard let accountId = RouteParams.accountId(from: request) else {
            return RouteJSON.error(.badRequest, "malformed-accountId")
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

        let remoteIds: [String]
        do {
            remoteIds = try await MessageStore.trashedRemoteIds(
                forAccount: accountId, db: db
            )
        } catch {
            return errorResponse(.internalServerError, "internal-error", logger: logger, error: error)
        }
        // Empty is a success, not an error: the user asked for the trash to be
        // empty and it is. A 409 here would train people to click through
        // warnings for a no-op.
        guard !remoteIds.isEmpty else {
            return RouteJSON.response(PurgeResponse(ok: true, remoteId: "", purged: 0))
        }

        do {
            try await provider.emptyTrash()
        } catch let error as MailError {
            return MessageRoutes.providerError(error, logger: logger, remoteId: "")
        } catch {
            logger.warning("emptyTrash.remoteFailed", metadata: [
                "label": .string(MessageRoutes.providerLabel(error)),
            ])
            return RouteJSON.error(.badGateway, "provider-unreachable")
        }

        do {
            try db.write { raw in
                for remoteId in remoteIds {
                    try MessageStore.hardDeleteSync(
                        remoteId: remoteId, accountId: accountId, db: raw
                    )
                }
                // One audit row for the whole sweep; see the single-message
                // purge handler for why its id is deliberately discarded.
                _ = try AIActionStore.recordSync(
                    accountId: accountId,
                    kind: .purge,
                    payload: [
                        "permanent": "true",
                        "count": String(remoteIds.count),
                        "scope": "trash",
                    ],
                    db: raw
                )
            }
        } catch {
            logger.error("emptyTrash.localCleanupFailed", metadata: [
                "count": .stringConvertible(remoteIds.count),
                "err": .string("\(error)"),
            ])
            return RouteJSON.error(.internalServerError, "internal-error")
        }
        return RouteJSON.response(PurgeResponse(
            ok: true, remoteId: "", purged: remoteIds.count
        ))
    }

    // MARK: - Delete

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
    // MARK: - 批量删除

    /// 批量删除：逐封移入服务器废纸篓，每封一条审计行，逐项回报。
    ///
    /// ## `allMatching` 为什么必须由服务端解析
    ///
    /// 客户端的列表是一扇**窗**：它只加载了前 N 封。当用户说「全选」时，他们
    /// 指的是筛选条件下的**全部**，而客户端根本拿不到那些 id。所以
    /// `allMatching: true` 把「全部」表达成一个**查询**，由服务端用与列表
    /// 完全相同的 filter 解析——两处若各写一套筛选，出现「批量删了 800 封但
    /// 列表里还有 3 封没删」这种事时，就无法判断是 bug 还是用户的预期。
    ///
    /// 这也是 Gmail 两段式全选的实现基础：第一步选已加载的（客户端做），
    /// 第二步选服务器上的全部（服务端做）。
    private static func deleteBulkHandler(
        request: Request, db: LagoonDB,
        makeProvider: MailProviderFactory.Builder, logger: Logger
    ) async -> Response {
        guard let accountId = RouteParams.accountId(from: request) else {
            return RouteJSON.error(.badRequest, "malformed-accountId")
        }
        let body: Data
        do { body = try await RouteParams.collectBody(request) } catch {
            return RouteJSON.error(.badRequest, "missing-body")
        }
        struct Req: Decodable {
            let remoteIds: [String]?
            /// 选服务器上的全部。`lens` 限定在哪个视图内。
            let allMatching: Bool?
            let archived: Bool?
            let deleted: Bool?
            /// 已发送 is the third axis (R1), and it must be decoded here for
            /// the same reason `archived`/`deleted` are: this is a **second,
            /// hand-written** copy of the filter vocabulary, and the shared
            /// `filterSQL` only sees what this struct forwards.
            ///
            /// It was missing, and `MessageStore` defaults `sent` to false —
            /// so "select every 已发送 message and delete" resolved to the
            /// **inbox** and trashed up to 500 inbox rows instead. The client's
            /// `DeleteBulkRequest` has carried `sent` since R1; only the server
            /// was cutting it. `DeleteBulkTests` and
            /// `TwoStageSelectTests.test_lensScope_coversEverySidebarDestination`
            /// now both cover the sent scope.
            let sent: Bool?
            let stackId: UUID?
        }
        let req: Req
        do { req = try JSONDecoder().decode(Req.self, from: body) } catch {
            return RouteJSON.error(.badRequest, "invalid-body")
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

        // Cap first, then resolve. The cap is on *remote round trips*, which is
        // the real cost, so it must bound whichever path produced the ids.
        let cap = 500
        var ids: [String] = []
        var truncated = 0
        if req.allMatching == true {
            var stackMatch: MessageStore.StackMatch?
            if let stackId = req.stackId {
                let rule: StackRule?
                do {
                    rule = try await StackStore.listStackRule(
                        id: stackId, accountId: accountId, db: db
                    )
                } catch {
                    return errorResponse(
                        .internalServerError, "internal-error", logger: logger, error: error
                    )
                }
                guard let rule else {
                    return RouteJSON.error(.notFound, "unknown-stack")
                }
                stackMatch = rule.kind == .sender ? .sender(rule.value) : .keyword(rule.value)
            }
            let all: [String]
            var liveTotal: Int
            do {
                // Two queries, and the second one is the point. Fetching only
                // `cap + 1` ids can prove "there is more than 500" but can never
                // say *how much* more — so `truncatedCount` would always read 1
                // whether 5 messages or 5,000 were left behind. A bulk delete
                // that reports "moved 500, 1 more skipped" for a 5,000-message
                // mailbox is the "looks complete while part is missing" failure
                // this field exists to prevent, so the real total is counted.
                all = try await MessageStore.remoteIds(
                    forAccount: accountId,
                    sender: nil,
                    archived: req.archived ?? false,
                    deleted: req.deleted ?? false,
                    sent: req.sent ?? false,
                    stackMatch: stackMatch,
                    limit: cap + 1,
                    db: db
                )
                liveTotal = try await MessageStore.count(
                    forAccount: accountId,
                    sender: nil,
                    archived: req.archived ?? false,
                    deleted: req.deleted ?? false,
                    sent: req.sent ?? false,
                    stackMatch: stackMatch,
                    db: db
                )
            } catch {
                return errorResponse(
                    .internalServerError, "internal-error", logger: logger, error: error
                )
            }
            // The *true* number of messages the filter matches, minus the ones
            // this call actually handled. Using `liveTotal` (not
            // `all.count - cap`) is what lets the user be told "3,000 more" as
            // opposed to a meaningless "1 more".
            ids = Array(all.prefix(cap))
            truncated = max(0, liveTotal - ids.count)
        } else {
            let requested = req.remoteIds ?? []
            truncated = max(0, requested.count - cap)
            ids = Array(requested.prefix(cap))
        }
        guard !ids.isEmpty else {
            return RouteJSON.error(.badRequest, "empty-remoteIds")
        }

        var items: [ArchiveBulkItem] = []
        for remoteId in ids {
            do {
                // Local flag first, remote second — the same ordering
                // `archiveBulkHandler` uses, for the same reconcile reason: the
                // flag is the claim `reconcileInbox` respects, so it has to be
                // committed before the await that lets reconcile run.
                let claimed = try db.write { raw -> Bool in
                    let wasDeleted = try Bool.fetchOne(
                        raw,
                        sql: "SELECT is_deleted FROM message_headers WHERE account_id = ? AND remote_id = ?",
                        arguments: [accountId, remoteId]
                    ) ?? false
                    try MessageStore.setDeletedSync(
                        remoteId: remoteId, accountId: accountId, deleted: true, db: raw
                    )
                    return !wasDeleted
                }
                do {
                    try await provider.trash(remoteId: remoteId)
                } catch {
                    if claimed {
                        try? db.write {
                            try MessageStore.setDeletedSync(
                                remoteId: remoteId, accountId: accountId, deleted: false, db: $0
                            )
                        }
                    }
                    throw error
                }
                let action = try db.write { raw in
                    try MessageStore.setDeletedSync(
                        remoteId: remoteId, accountId: accountId, deleted: true, db: raw
                    )
                    return try AIActionStore.recordSync(
                        accountId: accountId,
                        kind: .delete,
                        payload: ["remoteId": remoteId, "remoteWrite": "true"],
                        db: raw
                    )
                }
                items.append(ArchiveBulkItem(remoteId: remoteId, ok: true, actionId: action.id))
            } catch {
                // Per-item, honestly: a partial success is reported, never
                // thrown away. A bulk bar that says "done" while 30 of 200
                // failed is the failure mode this shape exists to prevent.
                items.append(ArchiveBulkItem(
                    remoteId: remoteId, ok: false,
                    errorCode: MessageRoutes.providerLabel(error)
                ))
            }
        }
        // `truncatedCount` is non-nil only when truncation actually happened,
        // matching `archiveBulkHandler`. The client must either page through the
        // remainder or tell the user — a partial bulk delete reported as
        // complete is the exact failure this field was added for.
        return RouteJSON.response(ArchiveBulkResponse(
            items: items,
            truncatedCount: truncated > 0 ? truncated : nil
        ))
    }

    private static func archiveBulkHandler(
        request: Request, db: LagoonDB,
        makeProvider: MailProviderFactory.Builder, logger: Logger
    ) async -> Response {
        guard let accountId = RouteParams.accountId(from: request) else {
            return RouteJSON.error(.badRequest, "malformed-accountId")
        }
        let body: Data
        do { body = try await RouteParams.collectBody(request) } catch {
            return RouteJSON.error(.badRequest, "missing-body")
        }
        struct Req: Decodable { let remoteIds: [String] }
        let req: Req
        do { req = try JSONDecoder().decode(Req.self, from: body) } catch {
            return RouteJSON.error(.badRequest, "invalid-body")
        }
        // The cap protects one remote round trip per message from becoming an
        // unbounded request. The overflow is now *reported* rather than
        // silently dropped: a caller archiving 800 messages used to get 500
        // successes and no way to know the rest were never attempted.
        let cap = 500
        let ids = Array(req.remoteIds.prefix(cap))
        let truncated = max(0, req.remoteIds.count - ids.count)
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
        return RouteJSON.response(
            ArchiveBulkResponse(items: items, truncatedCount: truncated > 0 ? truncated : nil)
        )
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

        let outcome: UnsubscribeEndpoint.Hit
        do {
            // RFC 8058 §3: the one-click POST is defined against the https
            // URL named in `List-Unsubscribe`, so it requires both the header
            // flag and a target that actually came from that header.
            let mayOneClick = oneClickHeader
                && targetFromHeader
                && unsubscribeURL.scheme?.lowercased() == "https"
            outcome = try await UnsubscribeEndpoint.hitUnsubscribe(url: unsubscribeURL, oneClick: mayOneClick)
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
        do { body = try await RouteParams.collectBody(request) } catch {
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

        switch await undoOne(
            actionId: actionId, accountId: accountId, account: account,
            makeProvider: makeProvider, db: db, logger: logger
        ) {
        case .undone:
            return RouteJSON.response(UndoResponse(ok: true, undone: actionId))
        case .notUndoable:
            return RouteJSON.error(.badRequest, "not-undoable")
        case .rejected(let rejection):
            return rejection.response
        case .failed(let error):
            return errorResponse(.internalServerError, "undo-failed", logger: logger, error: error)
        }
    }

    private static func undoBulkHandler(
        request: Request, db: LagoonDB,
        makeProvider: MailProviderFactory.Builder, logger: Logger
    ) async -> Response {
        guard let accountId = RouteParams.accountId(from: request) else {
            return RouteJSON.error(.badRequest, "malformed-accountId")
        }
        let body: Data
        do { body = try await RouteParams.collectBody(request) } catch {
            return RouteJSON.error(.badRequest, "missing-body")
        }
        let req: UndoBulkRequest
        do { req = try JSONDecoder().decode(UndoBulkRequest.self, from: body) } catch {
            return RouteJSON.error(.badRequest, "invalid-body")
        }
        // Same ceiling as archive-bulk: one ⌘Z should not be able to make the
        // server issue unbounded remote calls.
        let ids = Array(Set(req.actionIds)).prefix(500)
        guard !ids.isEmpty else {
            return RouteJSON.error(.badRequest, "empty-actionIds")
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

        var items: [UndoBulkItem] = []
        var undone = 0
        // Sequential, not a task group: each inverse may perform a remote IMAP
        // write, and the provider holds ONE connection per account by design
        // (QQ caps concurrent sessions). Racing N inverses over it would
        // interleave commands on a session that is strictly serial.
        for actionId in ids {
            switch await undoOne(
                actionId: actionId, accountId: accountId, account: account,
                makeProvider: makeProvider, db: db, logger: logger
            ) {
            case .undone:
                undone += 1
                items.append(UndoBulkItem(actionId: actionId, ok: true))
            case .notUndoable:
                // Expected for a terminal kind that slipped into the list.
                items.append(UndoBulkItem(actionId: actionId, ok: false, errorCode: "not-undoable"))
            case .rejected(let rejection):
                items.append(UndoBulkItem(
                    actionId: actionId, ok: false, errorCode: rejection.code
                ))
            case .failed(let error):
                logger.error("undoBulk.itemFailed", metadata: [
                    "actionId": .string("\(actionId)"),
                    "err": .string("\(error)"),
                ])
                items.append(UndoBulkItem(actionId: actionId, ok: false, errorCode: "undo-failed"))
            }
        }
        return RouteJSON.response(UndoBulkResponse(items: items, undone: undone))
    }

    /// Outcome of one inverse, so a bulk undo can report per item instead of
    /// collapsing N results into one status code.
    private enum UndoOutcome {
        case undone
        case notUndoable
        case failed(Error)
        case rejected(UndoRejection)
    }

    /// Claims and runs the inverse for one action.
    ///
    /// Extracted from `undoActionHandler` so the bulk route runs the *same*
    /// code path — a second implementation of claim-then-reverse would drift,
    /// and the single-use claim is the one part of undo that must not have two
    /// versions.
    private static func undoOne(
        actionId: Int64, accountId: UUID, account: Account,
        makeProvider: MailProviderFactory.Builder, db: LagoonDB, logger: Logger
    ) async -> UndoOutcome {
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
            return .rejected(rejection)
        } catch {
            return .failed(error)
        }

        do {
            try await reverse(
                action: claim.action, account: account,
                makeProvider: makeProvider, db: db
            )
        } catch let error as NotUndoable {
            await releaseClaim(claim, actionId: actionId, db: db, logger: logger)
            logger.info("actions.notUndoable", metadata: [
                "kind": .string(error.kind.rawValue),
                "actionId": .string("\(actionId)"),
            ])
            return .notUndoable
        } catch {
            await releaseClaim(claim, actionId: actionId, db: db, logger: logger)
            return .failed(error)
        }
        return .undone
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
            RouteJSON.error(status, code)
        }

        /// The same code in bulk form, so `undo-bulk` can report per item
        /// instead of collapsing N rejections into one status line.
        var code: String {
            switch self {
            case .unknownAction: return "unknown-action"
            case .expired: return "action-expired"
            case .alreadyUndone: return "already-undone"
            }
        }

        private var status: HTTPResponse.Status {
            switch self {
            case .unknownAction: return .notFound
            case .expired: return .gone
            case .alreadyUndone: return .conflict
            }
        }
    }

    private static func reverse(
        action: AIAction, account: Account,
        makeProvider: MailProviderFactory.Builder,
        db: LagoonDB
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
        case .markRead:
            // Restore the value this action *replaced*, not a hardcoded
            // `false`. Marking a read mail as unread is a first-class action
            // here, and its inverse is "read again" — always writing false
            // made undoing an unmark-read a no-op that silently reported
            // success. The previous value is carried in the payload the read
            // route records. Absent (rows written before this field existed,
            // or a hand-made row) falls back to the old behaviour: undoing a
            // mark-read returns the mail to unread.
            let previousIsRead = action.payload["previousIsRead"]
            let restoreTo: Bool = previousIsRead.map { $0 == "true" } ?? false
            guard let provider = makeProvider(account) else {
                throw MailError.notConfigured("provider missing during undo")
            }
            // Remote first, so a failed remote write cannot be hidden behind a
            // local success — same ordering as the archive and delete inverses.
            try await provider.setRead(remoteId: remoteId, isRead: restoreTo)
            try await MessageStore.setRead(
                remoteId: remoteId, accountId: account.id, isRead: restoreTo, db: db
            )
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
        case .purge:
            // 彻底删除 is the one branch with no inverse at all: the message is
            // gone from the server and from every local table, so there is
            // nothing left to restore. It is recorded in the audit stream
            // precisely so that this is a *known* irreversible action rather
            // than a silent gap in the history.
            throw NotUndoable(kind: action.kind)
        case .unsubscribe, .draftCreate, .send, .undo:
            // Terminal: we can't take back an unsubscribe, an undraft, or a
            // reply that has already left the building. Tell the user why.
            throw NotUndoable(kind: action.kind)
        }
    }

    // MARK: - Helpers

    /// Delegates to `RouteJSON.failure`; the label is what makes a 500 say
    /// which domain produced it.
    private static func errorResponse(
        _ status: HTTPResponse.Status, _ code: String, logger: Logger, error: Error
    ) -> Response {
        RouteJSON.failure(status, code, label: "actions", logger: logger, failure: error)
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

}
