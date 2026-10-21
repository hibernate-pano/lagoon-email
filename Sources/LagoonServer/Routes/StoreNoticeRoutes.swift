import Foundation
import Hummingbird
import Logging
import GRDB
import LagoonKit

/// The notices the store has for the user.
///
/// - `GET  /api/store-notices` → every notice the store has
/// - `POST /api/store-notices/:id/ack` → the user has seen it; drop it
///
/// ## Why this file exists
///
/// A migration that had to **delete** rows — because they could not be
/// encrypted — did something to the user's data that the user did not ask
/// for and cannot undo. The `lagoon-v6` body migration could do the same
/// thing to the body cache, and it was allowed to be silent: a body is
/// re-fetched by the next sync, so nothing is lost and there is nothing to
/// report.
///
/// A draft is regenerable too, but the user still asked for it, and
/// "your drafts are gone" is a sentence they are entitled to read. This
/// route is how that sentence reaches them.
///
/// It reads and writes only the `store_notices` table. It cannot touch the
/// mailbox — there is no write here that reaches a mail.
public enum StoreNoticeRoutes {
    public static func register(
        on router: Router<BasicRequestContext>,
        db: LagoonDB,
        logger: Logger
    ) {
        router.get("api/store-notices") { _, _ -> Response in
            do {
                let notices = try await StoreNoticeStore.list(db: db)
                return RouteJSON.response(StoreNoticeListResponse(notices: notices))
            } catch {
                return RouteJSON.failure(
                    .internalServerError, "internal-error",
                    label: "store-notices", logger: logger, failure: error
                )
            }
        }

        router.post("api/store-notices/:id/ack") { _, context -> Response in
            let rawId = context.parameters.get("id") ?? ""
            guard !rawId.isEmpty else {
                return RouteJSON.error(.badRequest, "malformed-noticeId")
            }
            do {
                try await StoreNoticeStore.acknowledge(id: rawId, db: db)
                return RouteJSON.response(StoreNoticeAckResponse(ok: true, id: rawId))
            } catch {
                return RouteJSON.failure(
                    .internalServerError, "internal-error",
                    label: "store-notices", logger: logger, failure: error
                )
            }
        }
    }
}

/// `POST /api/store-notices/{id}/ack` response.
public struct StoreNoticeAckResponse: Codable, Sendable, Equatable {
    public let ok: Bool
    public let id: String

    public init(ok: Bool, id: String) {
        self.ok = ok
        self.id = id
    }
}
