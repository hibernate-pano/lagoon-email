import Foundation
import Hummingbird
import PostgresNIO
import NIOCore
import LagoonKit

public enum SyncRoutes {
    public static func register(
        on router: Router<BasicRequestContext>,
        db: PostgresConnection,
        sync: SyncEngine? = nil
    ) {
        router.get("api/messages") { req, _ -> Response in
            // accountId is untrusted input; validated by UUID parsing (spec §6.6 rule 2).
            guard let raw = req.uri.queryParameters["accountId"].map(String.init),
                  let uuid = UUID(uuidString: raw)
            else {
                return Response(
                    status: .badRequest,
                    body: .init(byteBuffer: ByteBuffer(string: "accountId missing or malformed"))
                )
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
                    return Response(status: .notFound, body: .init(byteBuffer: ByteBuffer(string: "unknown-stack")))
                }
                stackMatch = rule.kind == .sender ? .sender(rule.value) : .keyword(rule.value)
            } else {
                stackMatch = nil
            }
            let msgs = try await MessageStore.recent(
                forAccount: uuid, limit: limit, sender: sender,
                archived: archived, stackMatch: stackMatch, db: db
            )
            let unread = try await MessageStore.unreadCount(forAccount: uuid, db: db)
            let cursor = SyncCursor(accountId: uuid, lastFetchedAt: Date(), totalUnread: unread)
            let payload = SyncResponse(cursor: cursor, messages: msgs)
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            let data = try enc.encode(payload)
            return Response(
                status: .ok,
                headers: [.contentType: "application/json; charset=utf-8"],
                body: .init(byteBuffer: ByteBuffer(data: data))
            )
        }

        router.post("api/sync") { _, _ -> Response in
            await sync?.requestImmediateSync()
            return Response(status: .noContent)
        }
    }
}
