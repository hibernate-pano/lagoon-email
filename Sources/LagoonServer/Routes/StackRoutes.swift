import Foundation
import Hummingbird
import GRDB
import Logging
import LagoonKit

/// 用户自定义聚合（归集规则）的 CRUD。规则求值发生在 GET /api/messages 的
/// `stackId` 臂；这个文件只管理规则本身和面板计数。
public enum StackRoutes {
    public static func register(
        on router: Router<BasicRequestContext>,
        db: LagoonDB,
        logger: Logger
    ) {
        // GET /api/stacks?accountId= → {stacks: [{rule, count}]}
        router.get("api/stacks") { request, _ -> Response in
            guard let accountId = RouteParams.accountId(from: request) else {
                return RouteJSON.error(.badRequest, "malformed-accountId")
            }
            do {
                let rules = try await StackStore.list(accountId: accountId, db: db)
                var summaries: [StackSummary] = []
                for rule in rules {
                    let count = try await StackStore.messageCount(rule: rule, db: db)
                    summaries.append(StackSummary(rule: rule, count: count))
                }
                return RouteJSON.response(StackRuleListResponse(stacks: summaries))
            } catch {
                logger.error("stacks.listFailed", metadata: ["err": .string("\(error)")])
                return RouteJSON.error(.internalServerError, "internal-error")
            }
        }

        // POST /api/stacks?accountId= {name, kind, value} → 201 {stack}
        router.post("api/stacks") { request, _ -> Response in
            guard let accountId = RouteParams.accountId(from: request) else {
                return RouteJSON.error(.badRequest, "malformed-accountId")
            }
            let body: Data
            do { body = try await RouteParams.collectBody(request) } catch {
                return RouteJSON.error(.badRequest, "missing-body")
            }
            struct Req: Decodable {
                let name: String
                let kind: String
                let value: String
            }
            let req: Req
            do { req = try JSONDecoder().decode(Req.self, from: body) } catch {
                return RouteJSON.error(.badRequest, "invalid-body")
            }
            let name = req.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = req.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 80 else {
                return RouteJSON.error(.badRequest, "invalid-name")
            }
            guard !value.isEmpty, value.count <= 200 else {
                return RouteJSON.error(.badRequest, "invalid-value")
            }
            guard let kind = StackRule.Kind(rawValue: req.kind) else {
                return RouteJSON.error(.badRequest, "invalid-kind")
            }
            do {
                let rule = try await StackStore.create(
                    accountId: accountId, name: name, kind: kind, value: value, db: db
                )
                let count = try await StackStore.messageCount(rule: rule, db: db)
                return RouteJSON.response(StackCreateResponse(stack: StackSummary(rule: rule, count: count)), status: .created)
            } catch {
                logger.error("stacks.createFailed", metadata: ["err": .string("\(error)")])
                return RouteJSON.error(.internalServerError, "internal-error")
            }
        }

        // DELETE /api/stacks/:id?accountId= → {ok} / 404
        router.delete("api/stacks/:id") { request, context -> Response in
            guard let accountId = RouteParams.accountId(from: request) else {
                return RouteJSON.error(.badRequest, "malformed-accountId")
            }
            guard let id = UUID(uuidString: context.parameters.get("id") ?? "") else {
                return RouteJSON.error(.badRequest, "malformed-stackId")
            }
            do {
                let deleted = try await StackStore.delete(id: id, accountId: accountId, db: db)
                return deleted
                    ? RouteJSON.response(StackDeleteResponse(ok: true))
                    : RouteJSON.error(.notFound, "unknown-stack")
            } catch {
                // The other two handlers log before answering 500; this one
                // did not, so a delete that failed for a real reason left no
                // trace anywhere. The `silent-catch` lint only scans
                // Sources/Lagoon/Views/, so nothing on the server side caught
                // this either.
                logger.error("stacks.deleteFailed", metadata: ["err": .string("\(error)")])
                return RouteJSON.error(.internalServerError, "internal-error")
            }
        }
    }
}
