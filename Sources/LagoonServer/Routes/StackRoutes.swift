import Foundation
import Hummingbird
import NIOCore
import PostgresNIO
import LagoonKit

/// 用户自定义聚合（归集规则）的 CRUD。规则求值发生在 GET /api/messages 的
/// `stackId` 臂；这个文件只管理规则本身和面板计数。
public enum StackRoutes {
    public static func register(
        on router: Router<BasicRequestContext>,
        db: PostgresConnection,
        logger: Logger
    ) {
        // GET /api/stacks?accountId= → {stacks: [{rule, count}]}
        router.get("api/stacks") { request, _ -> Response in
            guard let raw = request.uri.queryParameters["accountId"].map(String.init),
                  let accountId = UUID(uuidString: raw)
            else {
                return Self.error(.badRequest, "malformed-accountId")
            }
            do {
                let rules = try await StackStore.list(accountId: accountId, db: db)
                var summaries: [StackSummary] = []
                for rule in rules {
                    let count = try await StackStore.messageCount(rule: rule, db: db)
                    summaries.append(StackSummary(rule: rule, count: count))
                }
                return try Self.json(StackRuleListResponse(stacks: summaries))
            } catch {
                logger.error("stacks.listFailed", metadata: ["err": .string("\(error)")])
                return Self.error(.internalServerError, "internal-error")
            }
        }

        // POST /api/stacks?accountId= {name, kind, value} → 201 {stack}
        router.post("api/stacks") { request, _ -> Response in
            guard let raw = request.uri.queryParameters["accountId"].map(String.init),
                  let accountId = UUID(uuidString: raw)
            else {
                return Self.error(.badRequest, "malformed-accountId")
            }
            let body: Data
            do { body = try await collectBody(request) } catch {
                return Self.error(.badRequest, "missing-body")
            }
            struct Req: Decodable {
                let name: String
                let kind: String
                let value: String
            }
            let req: Req
            do { req = try JSONDecoder().decode(Req.self, from: body) } catch {
                return Self.error(.badRequest, "invalid-body")
            }
            let name = req.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = req.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 80 else {
                return Self.error(.badRequest, "invalid-name")
            }
            guard !value.isEmpty, value.count <= 200 else {
                return Self.error(.badRequest, "invalid-value")
            }
            guard let kind = StackRule.Kind(rawValue: req.kind) else {
                return Self.error(.badRequest, "invalid-kind")
            }
            do {
                let rule = try await StackStore.create(
                    accountId: accountId, name: name, kind: kind, value: value, db: db
                )
                let count = try await StackStore.messageCount(rule: rule, db: db)
                return try Self.json(StackCreateResponse(stack: StackSummary(rule: rule, count: count)), status: .created)
            } catch {
                logger.error("stacks.createFailed", metadata: ["err": .string("\(error)")])
                return Self.error(.internalServerError, "internal-error")
            }
        }

        // DELETE /api/stacks/:id?accountId= → {ok} / 404
        router.delete("api/stacks/:id") { request, context -> Response in
            guard let raw = request.uri.queryParameters["accountId"].map(String.init),
                  let accountId = UUID(uuidString: raw)
            else {
                return Self.error(.badRequest, "malformed-accountId")
            }
            guard let id = UUID(uuidString: context.parameters.get("id") ?? "") else {
                return Self.error(.badRequest, "malformed-stackId")
            }
            do {
                let deleted = try await StackStore.delete(id: id, accountId: accountId, db: db)
                return deleted
                    ? try Self.json(StackDeleteResponse(ok: true))
                    : Self.error(.notFound, "unknown-stack")
            } catch {
                return Self.error(.internalServerError, "internal-error")
            }
        }
    }

    private static func collectBody(_ request: Request) async throws -> Data {
        let buffer = try await request.body.collect(upTo: 1 << 20)
        return Data(buffer: buffer)
    }

    private static func json(_ payload: some Encodable, status: HTTPResponse.Status = .ok) throws -> Response {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(payload)
        return Response(
            status: status,
            headers: [.contentType: "application/json; charset=utf-8"],
            body: .init(byteBuffer: ByteBuffer(data: data))
        )
    }

    private static func error(_ status: HTTPResponse.Status, _ code: String) -> Response {
        let body = "{\"error\":\"\(code)\"}"
        return Response(
            status: status,
            headers: [.contentType: "application/json; charset=utf-8"],
            body: .init(byteBuffer: ByteBuffer(string: body))
        )
    }
}
