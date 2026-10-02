import Foundation
import Hummingbird
import Logging
import GRDB
import LagoonKit

/// Read-only advice API (constitution §3).
///
/// - `GET  /api/advice?accountId=[&decision=pending]` → suggestion queue
/// - `POST /api/advice/{id}/decision?accountId=` `{decision}` → record the
///   user's verdict on one suggestion
///
/// **This file cannot touch the mailbox.** It reads and writes only the
/// `advice` table. Every route in `ActionsRoutes` / `MessageRoutes` that
/// archives, deletes, unsubscribes or sends is reachable from a user gesture
/// and from nowhere else — see constitution §2 rules 3 and 5. The only write
/// here is a verdict on a suggestion, which changes no mail.
public enum AdviceRoutes {
    public static func register(
        on router: Router<BasicRequestContext>,
        db: LagoonDB,
        logger: Logger
    ) {
        router.get("api/advice") { request, _ -> Response in
            guard let accountId = RouteParams.accountId(from: request) else {
                return RouteJSON.error(.badRequest, "malformed-accountId")
            }
            // Default to the decision queue: that is what the client opens.
            // `decision=` absent or blank means pending; `decision=none` is not
            // a thing, so "all states" is spelled `decision=any`.
            let rawDecision = request.uri.queryParameters["decision"].map(String.init)
            let filter: AdviceDecisionQuery
            switch rawDecision {
            case .none, .some(""):
                filter = .pending
            case .some("any"):
                filter = .all
            default:
                guard let raw = rawDecision, let parsed = AdviceDecision(rawValue: raw) else {
                    return RouteJSON.error(.badRequest, "malformed-decision")
                }
                filter = .exactly(parsed)
            }
            let limit = max(1, min(Int(request.uri.queryParameters["limit"] ?? "200") ?? 200, 500))

            do {
                guard try await AccountStore.find(byId: accountId, db: db) != nil else {
                    return RouteJSON.error(.notFound, "unknown-account")
                }
                let rows = try await AdviceStore.list(
                    accountId: accountId, filter: filter, limit: limit, db: db
                )
                return RouteJSON.response(AdviceListResponse(advice: rows))
            } catch {
                return RouteJSON.failure(
                    .internalServerError, "internal-error",
                    label: "advice", logger: logger, failure: error
                )
            }
        }

        router.post("api/advice/:id/decision") { request, context -> Response in
            guard let accountId = RouteParams.accountId(from: request) else {
                return RouteJSON.error(.badRequest, "malformed-accountId")
            }
            guard let rawId = context.parameters.get("id"), let adviceId = Int64(rawId), adviceId > 0 else {
                return RouteJSON.error(.badRequest, "malformed-adviceId")
            }
            let body: DecisionRequest
            do {
                body = try JSONDecoder().decode(
                    DecisionRequest.self, from: try await RouteParams.collectBody(request)
                )
            } catch {
                return RouteJSON.error(.badRequest, "malformed-body")
            }
            guard let decision = AdviceDecision(rawValue: body.decision) else {
                return RouteJSON.error(.badRequest, "malformed-decision")
            }
            do {
                let updated = try await AdviceStore.setDecision(
                    id: adviceId, accountId: accountId, decision: decision, db: db
                )
                guard updated else {
                    // Either the id does not exist or it belongs to another
                    // mailbox. Both are 404: confirming which would leak
                    // another account's advice ids.
                    return RouteJSON.error(.notFound, "unknown-advice")
                }
                return RouteJSON.response(AdviceDecisionResponse(id: adviceId, decision: decision))
            } catch {
                return RouteJSON.failure(
                    .internalServerError, "internal-error",
                    label: "advice", logger: logger, failure: error
                )
            }
        }
    }

    /// `POST /api/advice/{id}/decision` body.
    private struct DecisionRequest: Decodable {
        let decision: String
    }

    /// `POST /api/advice/{id}/decision` response.
    public struct AdviceDecisionResponse: Codable, Sendable, Equatable {
        public let id: Int64
        public let decision: AdviceDecision
        public init(id: Int64, decision: AdviceDecision) {
            self.id = id
            self.decision = decision
        }
    }
}
