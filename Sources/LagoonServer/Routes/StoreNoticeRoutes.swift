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
                try await Self.raiseBodyKeyNoticeIfNeeded(db: db, logger: logger)
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

    /// Raises the "the body key is gone" notice when the store is in that
    /// state.
    ///
    /// ## Why the store raises it, and why here
    ///
    /// The condition is a fact about the store and the keychain together:
    /// the store holds sealed values, and the key that could open them is
    /// not the one this process has. The store is the only side that can see
    /// both halves — the app knows about the keychain, but it does not hold
    /// the database.
    ///
    /// The check is deliberately cheap in the healthy case: a store with a
    /// key is never in this state, and the sealed-value query is the
    /// expensive one. `BodyCipher.hasKey` is a closure call, so the common
    /// path costs nothing measurable.
    ///
    /// ## Why it is raised on a read
    ///
    /// The app cannot know the keychain has answered until the app's own
    /// Keychain read comes back, and the server is already serving by then.
    /// Waiting for a "the app is done" signal would mean a new route for a
    /// condition that the store can see for itself. The client polls this
    /// route anyway, so the notice is raised the first time somebody asks.
    private static func raiseBodyKeyNoticeIfNeeded(
        db: LagoonDB,
        logger: Logger
    ) async throws {
        guard !BodyCipher.hasKey else { return }
        guard try await BodyStore.hasSealedValues(db: db) else { return }
        let count = (try? await BodyStore.bodyCount(db: db)) ?? 0
        try await StoreNoticeStore.record(
            id: StoreNotice.bodyKeyLostID,
            detail: String(count),
            db: db
        )
        logger.error("body key unavailable: the store holds sealed values that cannot be opened")
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
