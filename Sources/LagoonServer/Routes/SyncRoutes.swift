import Foundation
import Hummingbird
import GRDB
import Logging
import LagoonKit

public enum SyncRoutes {
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
            let limit = max(1, min(Int(req.uri.queryParameters["limit"] ?? "50") ?? 50, 200))
            // Optional 发件人归集 filter: exact from_address, bound as a
            // parameter in the store (spec §6.6 rule 1/2).
            let sender = req.uri.queryParameters["sender"].map(String.init)
                .flatMap { $0.isEmpty ? nil : $0 }
            // 档案柜: ?archived=true lists what is_archived holds. 聚合:
            // ?stackId=<uuid> narrows to one user-defined rule.
            let archived = req.uri.queryParameters["archived"] == "true"
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
                    archived: archived, stackMatch: stackMatch, db: db
                )
                let unread = try await MessageStore.unreadCount(forAccount: uuid, db: db)
                let total = try await MessageStore.count(
                    forAccount: uuid, sender: sender,
                    archived: archived, stackMatch: stackMatch, db: db
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
