import Foundation
import Logging
import Hummingbird
import PostgresNIO
import LagoonKit

/// GET /api/briefing — the Briefing Feed (spec §7.1).
///
/// Grouping always starts from the deterministic heuristic classifier. When an
/// AI classifier is supplied its answers override the heuristic for the ids it
/// returns; if it throws, the heuristics stand and the briefing still returns
/// 200 (a classifier outage must never 500 the whole feed).
public enum BriefingRoutes {
    public static func register(
        on router: Router<BasicRequestContext>,
        db: PostgresConnection,
        logger: Logger,
        classifier: (any BriefingClassifying)? = nil
    ) {
        router.get("api/briefing") { request, _ -> Response in
            guard let accountId = RouteParams.accountId(from: request) else {
                return RouteJSON.error(.badRequest, "malformed-accountId")
            }
            let requested = Int(request.uri.queryParameters["limit"] ?? "100") ?? 100
            let limit = max(1, min(requested, 500))

            let account: Account
            do {
                guard let found = try await AccountStore.find(byId: accountId, db: db) else {
                    return RouteJSON.error(.notFound, "unknown-account")
                }
                account = found
            } catch {
                logger.error("account lookup failed", metadata: [
                    "accountId": .string(accountId.uuidString),
                    "err": .string("\(error)")
                ])
                return RouteJSON.error(.internalServerError, "internal-error")
            }

            let messages: [MessageHeader]
            let pinned: Set<String>
            let listUnsubscribe: Set<String>
            do {
                messages = try await MessageStore.recent(forAccount: accountId, limit: limit, db: db)
                pinned = try await MessageStore.pinnedIds(forAccount: accountId, db: db)
                listUnsubscribe = try await MessageStore.listUnsubscribeIds(forAccount: accountId, db: db)
            } catch {
                logger.error("briefing query failed", metadata: [
                    "accountId": .string(accountId.uuidString),
                    "err": .string("\(error)")
                ])
                return RouteJSON.error(.internalServerError, "internal-error")
            }

            let heuristics = HeuristicBriefingClassifier(
                signals: .init(
                    pinnedGmailIds: pinned,
                    listUnsubscribeGmailIds: listUnsubscribe
                )
            )
            var classified = heuristics.classifyWithReasons(
                messages,
                accountEmail: account.email
            )

            if let classifier {
                do {
                    let overrides = try await classifier.classify(
                        messages,
                        accountEmail: account.email
                    )
                    for (gmailId, group) in overrides where classified[gmailId] != nil {
                        classified[gmailId] = (group, "AI classification")
                    }
                } catch {
                    // Fail open: heuristic grouping is still useful.
                    logger.warning("briefing classifier failed; using heuristics", metadata: [
                        "accountId": .string(accountId.uuidString),
                        "err": .string("\(error)")
                    ])
                }
            }

            let items = messages.map { message -> BriefingItem in
                let result = classified[message.gmailId] ?? (.needsReply, "Unclassified")
                return BriefingItem(message: message, group: result.group, reason: result.reason)
            }
            return RouteJSON.response(BriefingResponse(items: items))
        }
    }
}
