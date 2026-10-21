import Foundation
import Logging
import Hummingbird
import GRDB
import LagoonKit

/// `GET /api/export/index?accountId=<uuid>` — every message the local store
/// knows about, in the order an export needs them.
///
/// ## Why this route exists
///
/// The `.mbox` export walks the mailbox message by message. The list route
/// cannot feed it: `GET /api/messages` is capped at `maxListRows` (1000) on
/// purpose — it feeds a grouped list where a partial page is a wrong answer —
/// and it has no cursor, so a caller cannot page past the cap. Exporting
/// "everything" off a 3,000-message mailbox through it would silently write
/// 1,000 messages and call the result complete, which is the quiet wrong
/// answer this product keeps refusing to give.
///
/// So the export gets its own index: ids and dates only, no bodies, no
/// snippets. The bodies come from the existing `raw.eml` route, one at a
/// time, which is also what keeps this route cheap enough to answer for an
/// arbitrarily large mailbox.
///
/// ## Read-only
///
/// One `SELECT` over `message_headers`. It does not touch the mailbox, does
/// not write a row, and cannot change a message. It deliberately includes
/// every folder — archived, sent and trashed mail is part of "all my mail"
/// when the user is about to move to another client — and reports the counts
/// per folder so the UI can say what the file will contain.
public enum BackupRoutes {
    /// Response: the ids, oldest first, plus per-folder tallies.
    ///
    /// Oldest first because that is the order every mail client writes its
    /// own mbox in, and an import lands in the order the file presents.
    struct ExportIndexResponse: Encodable {
        let messages: [MessageHeader]
        let totalCount: Int
        /// Rows in the Trash. Exported too, but worth saying out loud.
        let deletedCount: Int
        /// Rows that live on the server's Sent folder.
        let sentCount: Int
    }

    public static func register(
        on router: Router<BasicRequestContext>,
        db: LagoonDB,
        logger: Logger
    ) {
        router.get("api/export/index") { request, _ -> Response in
            // Untrusted input: validated as a UUID before anything else.
            guard let accountId = RouteParams.accountId(from: request) else {
                return RouteJSON.error(.badRequest, "malformed-accountId")
            }
            do {
                guard try await AccountStore.find(byId: accountId, db: db) != nil else {
                    return RouteJSON.error(.notFound, "unknown-account")
                }
                let headers = try await index(forAccount: accountId, db: db)
                let counts = try await folderCounts(forAccount: accountId, db: db)
                return RouteJSON.response(ExportIndexResponse(
                    messages: headers,
                    totalCount: headers.count,
                    deletedCount: counts.deleted,
                    sentCount: counts.sent
                ))
            } catch {
                return RouteJSON.failure(
                    .internalServerError, "internal-error",
                    label: "export-index", logger: logger, failure: error
                )
            }
        }
    }

    /// Every header for the account, oldest first.
    ///
    /// `MessageStore.decode` is reused rather than a second hand-written row
    /// decoder: the export writes the same `MessageHeader` the rest of the
    /// app reads, so a column added there cannot be silently missing here.
    static func index(forAccount accountId: UUID, db: LagoonDB) async throws -> [MessageHeader] {
        // No interpolation anywhere: one bound parameter, one static query.
        let sql = """
            SELECT id, account_id, remote_id, thread_id, from_address,
                   NULLIF(from_name, '') AS from_name,
                   NULLIF(subject, '') AS subject,
                   NULLIF(snippet_cipher, '') AS snippet_cipher,
                   received_at, is_read, is_archived, is_deleted, is_sent,
                   message_id_header, in_reply_to, references_header
            FROM message_headers
            WHERE account_id = ?
            ORDER BY received_at ASC
        """
        return try db.read { db in
            try Row.fetchAll(db, sql: sql, arguments: [accountId])
                .map { try MessageStore.decode($0) }
        }
    }

    /// How many rows sit in each folder, so the export can describe itself.
    ///
    /// One query with conditional sums rather than three round trips: the
    /// three numbers describe the same table and reading them separately
    /// would let the page change between the reads.
    static func folderCounts(
        forAccount accountId: UUID, db: LagoonDB
    ) async throws -> (deleted: Int, sent: Int) {
        let sql = """
            SELECT
                SUM(CASE WHEN is_deleted THEN 1 ELSE 0 END) AS deleted,
                SUM(CASE WHEN is_sent THEN 1 ELSE 0 END) AS sent
            FROM message_headers
            WHERE account_id = ?
        """
        return try db.read { db in
            guard let row = try Row.fetchOne(db, sql: sql, arguments: [accountId]) else {
                return (0, 0)
            }
            let deleted: Int? = row["deleted"]
            let sent: Int? = row["sent"]
            return (deleted ?? 0, sent ?? 0)
        }
    }
}
