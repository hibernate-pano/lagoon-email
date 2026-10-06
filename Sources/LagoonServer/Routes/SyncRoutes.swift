import Foundation
import Hummingbird
import GRDB
import Logging
import LagoonKit

public enum SyncRoutes {
    /// Rows one `GET /api/messages` may return.
    ///
    /// A generous ceiling rather than a page size, on purpose: this list is
    /// grouped by conversation and by date bucket, and grouping a partial list
    /// splits one thread into two rows — a wrong answer the user cannot
    /// distinguish from a duplicate. Covering the whole store in one response
    /// keeps the grouping honest; a mailbox beyond this ceiling is reported as
    /// truncated (see `totalCount`) rather than silently cut.
    public static let maxListRows = 1000

    public static func register(
        on router: Router<BasicRequestContext>,
        db: LagoonDB,
        logger: Logger,
        sync: SyncEngine? = nil
    ) {
        router.get("api/messages") { req, _ -> Response in
            // accountId is untrusted input; validated by UUID parsing (spec §6.6 rule 2).
            guard let uuid = RouteParams.accountId(from: req) else {
                return RouteJSON.error(.badRequest, "malformed-accountId")
            }
            // The server owns the window and the ceiling, and it reports what
            // it withheld: `totalCount` in the response ignores LIMIT, so a
            // client that got fewer rows than exist can say so instead of
            // rendering a truncated list that looks complete. That silent
            // truncation — not the number itself — is what made the surface
            // look like it had stopped loading.
            //
            // The client sends no `limit` on the hot path (see
            // `APIClient.fetchMessages`), so this default is the policy.
            let limit = max(1, min(
                Int(req.uri.queryParameters["limit"] ?? "500") ?? 500,
                Self.maxListRows
            ))
            // Optional 发件人归集 filter: exact from_address, bound as a
            // parameter in the store (spec §6.6 rule 1/2).
            let sender = req.uri.queryParameters["sender"].map(String.init)
                .flatMap { $0.isEmpty ? nil : $0 }
            // 档案柜: ?archived=true lists what is_archived holds. 聚合:
            // ?stackId=<uuid> narrows to one user-defined rule.
            let archived = req.uri.queryParameters["archived"] == "true"
            // 废纸篓: ?deleted=true lists trashed mail. Mutually exclusive with
            // `archived` in practice — a message deleted *from* the archive
            // belongs to the trash, and the trash listing passes archived=false
            // so one row never appears in two places.
            let deleted = req.uri.queryParameters["deleted"] == "true"
            let stackMatch: MessageStore.StackMatch?
            if let raw = req.uri.queryParameters["stackId"].map(String.init), let ruleId = UUID(uuidString: raw) {
                guard let rule = try await StackStore.listStackRule(id: ruleId, accountId: uuid, db: db) else {
                    return RouteJSON.error(.notFound, "unknown-stack")
                }
                stackMatch = rule.kind == .sender ? .sender(rule.value) : .keyword(rule.value)
            } else {
                stackMatch = nil
            }
            // Every store call below can throw, and Hummingbird's default
            // error handler answers an escaping throw with an *empty* 500 —
            // not the `{"error":…}` envelope the client decodes. Wrapping
            // keeps one error shape across every route.
            do {
                let msgs = try await MessageStore.recent(
                    forAccount: uuid, limit: limit, sender: sender,
                    archived: archived, deleted: deleted,
                    stackMatch: stackMatch, db: db
                )
                let unread = try await MessageStore.unreadCount(forAccount: uuid, db: db)
                let total = try await MessageStore.count(
                    forAccount: uuid, sender: sender,
                    archived: archived, deleted: deleted,
                    stackMatch: stackMatch, db: db
                )
                let cursor = SyncCursor(accountId: uuid, lastFetchedAt: Date(), totalUnread: unread)
                let payload = SyncResponse(cursor: cursor, messages: msgs, totalCount: total)
                return RouteJSON.response(payload)
            } catch {
                // This is the client's hottest path: the list view polls it
                // every 30s. Without this line a 500 here was completely
                // invisible — the client showed a generic error and the server
                // recorded nothing, so there was no way to tell a store failure
                // from a client bug.
                logger.error("messages.listFailed", metadata: [
                    "accountId": .string(uuid.uuidString),
                    "err": .string("\(error)"),
                ])
                return RouteJSON.error(.internalServerError, "internal-error")
            }
        }

        router.post("api/sync") { _, _ -> Response in
            await sync?.requestImmediateSync()
            return Response(status: .noContent)
        }
    }
}
