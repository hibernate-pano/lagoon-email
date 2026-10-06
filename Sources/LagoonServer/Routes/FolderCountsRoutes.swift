import Foundation
import Logging
import Hummingbird
import GRDB
import LagoonKit

/// `GET /api/folder-counts?accountId=` — how much mail sits in each place the
/// sidebar can navigate to.
///
/// ## Why a route at all
///
/// The sidebar has to show a count next to every entry, or it is decoration:
/// the user cannot tell "订阅噪音 has 4" from "订阅噪音 has 400", and those two
/// call for opposite decisions. The client *could* add the numbers up from the
/// lists it already fetched, but it cannot — the Briefing feed is grouped and
/// windowed, the raw list is capped at 500, and neither knows the archived or
/// deleted totals. Deriving them would mean counting a truncated list and
/// calling the result a total, which is the same class of quiet wrong number
/// that `totalCount` was introduced to stop.
///
/// ## Read-only
///
/// Every figure comes from `MessageStore.count` / `StackStore.messageCount`,
/// which read `message_headers`. Nothing here writes, and nothing here reaches
/// the mailbox — the counts describe the local cache, so they answer "what has
/// Lagoon seen", not "what is on the server". A message still syncing is
/// missing from them, which is why the counts refresh on the same cadence as
/// the poll rather than being presented as authoritative.
public enum FolderCountsRoutes {
    public static func register(
        on router: Router<BasicRequestContext>,
        db: LagoonDB,
        logger: Logger
    ) {
        router.get("api/folder-counts") { request, _ -> Response in
            guard let accountId = RouteParams.accountId(from: request) else {
                return RouteJSON.error(.badRequest, "malformed-accountId")
            }
            do {
                guard try await AccountStore.find(byId: accountId, db: db) != nil else {
                    return RouteJSON.error(.notFound, "unknown-account")
                }
                let counts = try await counts(accountId: accountId, db: db)
                return RouteJSON.response(FolderCountsResponse(counts: counts))
            } catch {
                return RouteJSON.failure(
                    .internalServerError, "internal-error",
                    label: "folder-counts", logger: logger, failure: error
                )
            }
        }
    }

    /// Counts for every sidebar destination, in one round trip.
    ///
    /// Deliberately excludes the user's 聚合规则 counts: `/api/stacks` already
    /// returns `StackSummary(rule:count:)`, so folding them in here would mean
    /// two endpoints answering the same question and drifting. This route owns
    /// only the buckets that have no other source.
    ///
    /// Deliberately absent too: a "订阅噪音" total. That group is a
    /// *classifier* verdict (List-Unsubscribe header, no-reply sender, AI
    /// judgement), not a stored column, so the only honest way to count it is
    /// to re-run the classifier over the window — a second full pass over
    /// every message, on every sidebar refresh, to produce one decorative
    /// number. The Briefing feed already carries that grouping per row, so the
    /// sidebar links to the feed instead of restating it. Same call
    /// `omittedCount` makes: count what is cheap and exact, link to the rest.
    private static func counts(
        accountId: UUID,
        db: LagoonDB
    ) async throws -> FolderCounts {
        // The inbox total is the "all live mail" figure, which is exactly the
        // `archived: false, no other filter` query — the same one the All
        // Messages surface lists, so the number and the list cannot disagree.
        async let live = MessageStore.count(forAccount: accountId, archived: false, db: db)
        async let unread = MessageStore.unreadCount(forAccount: accountId, db: db)
        async let archived = MessageStore.count(forAccount: accountId, archived: true, db: db)
        async let pinned = MessageStore.pinnedCount(forAccount: accountId, db: db)
        async let deleted = MessageStore.deletedCount(forAccount: accountId, db: db)
        async let sent = MessageStore.sentCount(forAccount: accountId, db: db)

        return try await FolderCounts(
            live: live, unread: unread, archived: archived, pinned: pinned,
            deleted: deleted, sent: sent
        )
    }
}
