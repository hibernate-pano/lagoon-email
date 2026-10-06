import Foundation
import Logging
import Hummingbird
import GRDB
import LagoonKit

/// `GET /api/senders?accountId=[&limit=][&q=]` — who actually writes to this
/// mailbox, ranked.
///
/// ## The question this answers
///
/// Inbox Zero's most-used feature is not a classifier at all — it is the answer
/// to "who sends me the most mail", because that is the list you act on. A
/// triage tool that can say "this sender wrote 340 times and you have never
/// opened one" has found something no amount of per-message judgement would.
///
/// Lagoon already holds the two halves this needs and was throwing them away:
/// `SenderSheet` can pull every message from one address (so the data is there),
/// and 聚合规则 can file a sender automatically (so the remedy exists). What was
/// missing was the ranking that connects them.
///
/// ## Read-only
///
/// Every number comes from `message_headers`. Nothing here writes, nothing here
/// reaches the mailbox, and nothing here files anything. Turning a row into a
/// rule happens through the ordinary `POST /api/stacks` route, from a user
/// gesture — this endpoint only makes the rows findable.
public enum SenderRoutes {
    /// Cap on rows. Generous enough to cover a mailbox that has absorbed a few
    /// newsletters, small enough that the client renders the whole ranking on
    /// one screen: a report the user has to scroll is a report they skip.
    static let maxLimit = 300
    static let defaultLimit = 60

    public static func register(
        on router: Router<BasicRequestContext>,
        db: LagoonDB,
        logger: Logger
    ) {
        router.get("api/senders") { request, _ -> Response in
            guard let accountId = RouteParams.accountId(from: request) else {
                return RouteJSON.error(.badRequest, "malformed-accountId")
            }
            let limit = max(
                1, min(Int(request.uri.queryParameters["limit"] ?? "\(defaultLimit)")
                    ?? defaultLimit, maxLimit)
            )
            // Free-text narrowing over sender name/address. Substring, same as
            // the search endpoint — this is a filter on a list the user is
            // already looking at, not a query language.
            let rawQuery = request.uri.queryParameters["q"]?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let query = rawQuery.isEmpty ? nil : rawQuery

            do {
                guard try await AccountStore.find(byId: accountId, db: db) != nil else {
                    return RouteJSON.error(.notFound, "unknown-account")
                }
                let senders = try await MessageStore.senderRanking(
                    forAccount: accountId, limit: limit, query: query, db: db
                )
                return RouteJSON.response(SenderListResponse(senders: senders))
            } catch {
                return RouteJSON.failure(
                    .internalServerError, "internal-error",
                    label: "senders", logger: logger, failure: error
                )
            }
        }
    }
}
