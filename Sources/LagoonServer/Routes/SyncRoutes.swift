import Foundation
import Hummingbird
import PostgresNIO
import NIOCore
import LagoonKit

public enum SyncRoutes {
    public static func register(on router: Router<BasicRequestContext>, db: PostgresConnection) {
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
            let limit = min(Int(req.uri.queryParameters["limit"] ?? "50") ?? 50, 200)
            let msgs = try await MessageStore.recent(forAccount: uuid, limit: limit, db: db)
            let unread = msgs.filter { !$0.isRead }.count
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
    }
}