import Foundation
import GRDB
import LagoonKit

/// The notices the store has for the user.
///
/// ## Why the store raises them instead of logging them
///
/// A log line is invisible to the person whose data it is about. A notice
/// row sits in the database until the client picks it up, so "your drafts
/// were deleted because the store could not be encrypted" reaches the user
/// whenever they next open the app — which may be the next day.
///
/// The notice carries only a **count** and a machine-readable id. It never
/// carries the content of what was lost: a notice is not a place to put
/// mail.
public enum StoreNoticeStore {
    /// Every notice the store has, oldest first.
    public static func list(db: LagoonDB) async throws -> [StoreNotice] {
        try db.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT id, detail, created_at FROM store_notices ORDER BY created_at ASC"
            ).map { try Self.decode($0) }
        }
    }

    /// The notices the store has, by id.
    public static func find(id: String, db: LagoonDB) async throws -> StoreNotice? {
        try db.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT id, detail, created_at FROM store_notices WHERE id = ?",
                arguments: [id]
            ).map { try Self.decode($0) }
        }
    }

    /// Records a notice.
    ///
    /// `INSERT OR IGNORE` because the id is the identity: the same
    /// condition raised twice is the same notice, and the user should be
    /// told once.
    public static func record(
        id: String,
        detail: String? = nil,
        db: LagoonDB
    ) async throws {
        try db.write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO store_notices (id, detail) VALUES (?, ?)",
                arguments: [id, detail]
            )
        }
    }

    /// Removes a notice the user has been shown.
    ///
    /// The client calls this after it has displayed the notice, so the same
    /// message does not greet the user on every launch.
    public static func acknowledge(id: String, db: LagoonDB) async throws {
        try db.write { db in
            try db.execute(
                sql: "DELETE FROM store_notices WHERE id = ?",
                arguments: [id]
            )
        }
    }

    private static func decode(_ row: Row) throws -> StoreNotice {
        StoreNotice(
            id: row["id"],
            createdAt: StoredDate.date(from: row["created_at"] as String?) ?? Date(),
            detail: row["detail"]
        )
    }
}
