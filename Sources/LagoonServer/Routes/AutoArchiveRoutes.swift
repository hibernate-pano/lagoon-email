import Foundation
import Hummingbird
import PostgresNIO
import NIOCore
import LagoonKit

/// Whitelist autopilot rules API (spec 2026-09-19 §3).
///
/// - `GET  /api/auto-archive?accountId=` → rule list
/// - `POST /api/auto-archive?accountId=` `{senderAddress}` → created (or
///   existing) rule; idempotent on (account, sender)
/// - `DELETE /api/auto-archive/{id}?accountId=` → 204
///
/// Rules only take effect on *future* syncs (the sync loop matches new
/// arrivals); the Briefing row menu pairs rule creation with archiving the
/// message in front of the user, so the visible effect is immediate.
public enum AutoArchiveRoutes {
    public static func register(
        on router: Router<BasicRequestContext>,
        db: PostgresConnection,
        logger: Logger
    ) {
        router.get("api/auto-archive") { request, _ -> Response in
            guard let accountId = RouteParams.accountId(from: request) else {
                return RouteJSON.error(.badRequest, "malformed-accountId")
            }
            do {
                let rules = try await AutoArchiveStore.list(accountId: accountId, db: db)
                return RouteJSON.response(AutoArchiveRuleListResponse(rules: rules))
            } catch {
                logger.error("auto-archive.listFailed", metadata: [
                    "accountId": .string(accountId.uuidString),
                    "err": .string("\(error)"),
                ])
                return RouteJSON.error(.internalServerError, "internal-error")
            }
        }

        // GET /api/auto-archive/suggestions?accountId= → archive-history-driven
        // whitelist proposals (senders the user keeps archiving by hand).
        router.get("api/auto-archive/suggestions") { request, _ -> Response in
            guard let accountId = RouteParams.accountId(from: request) else {
                return RouteJSON.error(.badRequest, "malformed-accountId")
            }
            do {
                let suggestions = try await AutoArchiveStore.suggestions(
                    accountId: accountId, db: db
                )
                return RouteJSON.response(AutoArchiveSuggestionsResponse(suggestions: suggestions))
            } catch {
                logger.error("auto-archive.suggestionsFailed", metadata: [
                    "accountId": .string(accountId.uuidString),
                    "err": .string("\(error)"),
                ])
                return RouteJSON.error(.internalServerError, "internal-error")
            }
        }

        router.post("api/auto-archive") { request, _ -> Response in
            guard let accountId = RouteParams.accountId(from: request) else {
                return RouteJSON.error(.badRequest, "malformed-accountId")
            }
            let body: AutoArchiveRuleCreateRequest
            do {
                // Capped like every other body read so a hostile client
                // cannot make the server buffer without bound.
                let buffer = try await request.body.collect(upTo: 1 << 20)
                body = try JSONDecoder().decode(AutoArchiveRuleCreateRequest.self, from: Data(buffer: buffer))
            } catch {
                return RouteJSON.error(.badRequest, "malformed-body")
            }
            guard AutoArchiveStore.isValidSenderAddress(body.senderAddress) else {
                return RouteJSON.error(.badRequest, "invalid-sender-address")
            }
            do {
                let rule = try await AutoArchiveStore.create(
                    accountId: accountId,
                    senderAddress: body.senderAddress,
                    db: db
                )
                return RouteJSON.response(rule, status: .created)
            } catch {
                logger.error("auto-archive.createFailed", metadata: [
                    "accountId": .string(accountId.uuidString),
                    "err": .string("\(error)"),
                ])
                return RouteJSON.error(.internalServerError, "internal-error")
            }
        }

        router.delete("api/auto-archive/:id") { request, context -> Response in
            guard let accountId = RouteParams.accountId(from: request) else {
                return RouteJSON.error(.badRequest, "malformed-accountId")
            }
            guard let raw = context.parameters.get("id"), let ruleId = Int64(raw) else {
                return RouteJSON.error(.badRequest, "malformed-ruleId")
            }
            do {
                // Row-scoped delete keyed by both id and account: a stale list
                // from another account can never remove this one's rule.
                try await AutoArchiveStore.delete(id: ruleId, accountId: accountId, db: db)
                return Response(status: .noContent)
            } catch {
                logger.error("auto-archive.deleteFailed", metadata: [
                    "accountId": .string(accountId.uuidString),
                    "ruleId": .string("\(ruleId)"),
                    "err": .string("\(error)"),
                ])
                return RouteJSON.error(.internalServerError, "internal-error")
            }
        }
    }
}
