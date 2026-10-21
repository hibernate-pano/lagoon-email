import Foundation
import GRDB
import LagoonKit

/// Storage for the reminders the user set for themselves.
///
/// Every query is parameterized, and every one of them filters on the
/// account — a reminder is a private note about a private mail, and a
/// missing account filter would be the kind of bug that shows one user's
/// notes in another user's list.
public enum ReminderStore {

    /// The reminders still waiting to fire, soonest first.
    ///
    /// ## Why a trashed mail's reminder is not waiting
    ///
    /// The join is an **inner** one, and it filters on `is_deleted`. A
    /// reminder about a mail the user threw away is a reminder about
    /// something they deliberately got rid of — firing it would nag about
    /// mail that is sitting in the Trash.
    ///
    /// But the *row* stays. Moving a mail to the Trash is a soft delete:
    /// the header row survives, so the reminder row survives with it, and
    /// restoring the mail brings the reminder back. The user does not lose
    /// a reminder by tidying up their inbox, and does not keep getting
    /// reminded about what they discarded.
    ///
    /// A **hard** delete (彻底删除) is different: the header row is
    /// actually removed, the foreign key fires, and the reminder row goes
    /// with it. That is the one irreversible operation in the product, and
    /// it is the one place a reminder really is destroyed.
    public static func pending(
        forAccount accountId: UUID,
        limit: Int = 200,
        db: LagoonDB
    ) async throws -> [Reminder] {
        let sql = """
            SELECT r.id, r.account_id, r.remote_id, r.due_at, r.note,
                   r.created_at, r.dismissed_at, m.subject
            FROM reminders r
            JOIN message_headers m
              ON m.account_id = r.account_id AND m.remote_id = r.remote_id
            WHERE r.account_id = ? AND r.dismissed_at IS NULL
              AND m.is_deleted = FALSE
            ORDER BY r.due_at ASC
            LIMIT ?
            """
        return try db.read { db in
            try Row.fetchAll(db, sql: sql, arguments: [accountId, limit])
                .map { try Self.decode($0) }
        }
    }

    /// Every reminder for the account, dismissed ones included.
    ///
    /// The dismissed ones are kept, not deleted: "I dismissed this" is
    /// information, and a user who dismissed a reminder by accident needs
    /// to be able to find it again.
    ///
    /// The same trashed-mail rule applies here, for the same reason: a
    /// reminder on a mail in the Trash is not a thing the user can act on
    /// from this list, so showing it would be a row that does nothing.
    public static func all(
        forAccount accountId: UUID,
        limit: Int = 500,
        db: LagoonDB
    ) async throws -> [Reminder] {
        let sql = """
            SELECT r.id, r.account_id, r.remote_id, r.due_at, r.note,
                   r.created_at, r.dismissed_at, m.subject
            FROM reminders r
            JOIN message_headers m
              ON m.account_id = r.account_id AND m.remote_id = r.remote_id
            WHERE r.account_id = ? AND m.is_deleted = FALSE
            ORDER BY r.dismissed_at IS NOT NULL, r.due_at ASC
            LIMIT ?
            """
        return try db.read { db in
            try Row.fetchAll(db, sql: sql, arguments: [accountId, limit])
                .map { try Self.decode($0) }
        }
    }

    /// Sets a reminder on a message.
    ///
    /// One reminder per message: setting a second one replaces the first.
    /// Two reminders on the same mail would mean two notifications for one
    /// thing, and the user would have to work out which one was the real
    /// one.
    @discardableResult
    public static func set(
        accountId: UUID,
        remoteId: String,
        dueAt: Date,
        note: String?,
        db: LagoonDB
    ) async throws -> Reminder? {
        // The reminder hangs off the message by foreign key, so a message
        // that is gone means there is nothing to remind about. Checked
        // explicitly rather than inferred from a caught violation.
        let sql = """
            INSERT INTO reminders (account_id, remote_id, due_at, note)
            VALUES (?, ?, ?, ?)
            ON CONFLICT (account_id, remote_id) DO UPDATE SET
                due_at       = excluded.due_at,
                note         = excluded.note,
                dismissed_at = NULL
            RETURNING id, account_id, remote_id, due_at, note, created_at, dismissed_at
            """
        return try db.write { db in
            // A reminder about a mail in the Trash is a reminder the user
            // cannot act on: the list hides it (see `pending`), so setting
            // one would store a row the user can never see or clear. The
            // row is not destroyed when the mail is trashed — it comes
            // back with the mail if the user restores it — but a *new*
            // reminder on a trashed mail is refused.
            guard try Bool.fetchOne(
                db,
                sql: "SELECT 1 FROM message_headers WHERE account_id = ? AND remote_id = ? AND is_deleted = FALSE",
                arguments: [accountId, remoteId]
            ) == true else {
                return nil
            }
            guard let row = try Row.fetchOne(
                db,
                sql: sql,
                arguments: [accountId, remoteId, Self.timestamp(dueAt), note]
            ) else {
                return nil
            }
            var reminder = try Self.decode(row)
            reminder = reminder.withSubject(try Self.subject(remoteId: remoteId, accountId: accountId, db: db))
            return reminder
        }
    }

    /// Dismisses a reminder, or brings it back.
    ///
    /// A dismissal is not a delete: the row stays so the user can undo it,
    /// and so the "reminders" list can show what was set and dropped.
    public static func setDismissed(
        reminderId: Int64,
        accountId: UUID,
        dismissed: Bool,
        db: LagoonDB
    ) async throws -> Reminder? {
        let sql = """
            UPDATE reminders
            SET dismissed_at = ?
            WHERE id = ? AND account_id = ?
            RETURNING id, account_id, remote_id, due_at, note, created_at, dismissed_at
            """
        return try db.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: sql,
                arguments: [dismissed ? Self.timestamp(Date()) : nil, reminderId, accountId]
            ) else {
                return nil
            }
            var reminder = try Self.decode(row)
            reminder = reminder.withSubject(
                try Self.subject(remoteId: reminder.remoteId, accountId: accountId, db: db)
            )
            return reminder
        }
    }

    /// Removes a reminder outright.
    public static func delete(
        reminderId: Int64,
        accountId: UUID,
        db: LagoonDB
    ) async throws {
        try db.write { db in
            try db.execute(
                sql: "DELETE FROM reminders WHERE id = ? AND account_id = ?",
                arguments: [reminderId, accountId]
            )
        }
    }

    // MARK: - Encoding

    /// The timestamp format the store writes.
    ///
    /// The same format the rest of the schema uses: SQLite's
    /// `strftime('%Y-%m-%d %H:%M:%f','now')`, which is a UTC ISO-8601
    /// string with a fractional part. `Date` has no GRDB representation
    /// for this exact shape, so it is written and read by hand.
    private static func timestamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond],
            from: date
        )
        let nanosecond = parts.nanosecond ?? 0
        let millisecond = nanosecond / 1_000_000
        return String(
            format: "%04d-%02d-%02d %02d:%02d:%02d.%03d",
            parts.year ?? 1970,
            parts.month ?? 1,
            parts.day ?? 1,
            parts.hour ?? 0,
            parts.minute ?? 0,
            parts.second ?? 0,
            millisecond
        )
    }

    /// Reads a timestamp written by `timestamp(_:)`.
    private static func date(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter.date(from: raw)
    }

    private static func decode(_ row: Row) throws -> Reminder {
        guard let accountId: UUID = row["account_id"],
              let dueAt = date(row["due_at"] as String?),
              let createdAt = date(row["created_at"] as String?)
        else {
            throw StoreError.insertFailed
        }
        return Reminder(
            id: row["id"],
            accountId: accountId,
            remoteId: row["remote_id"],
            dueAt: dueAt,
            note: row["note"] as String?,
            createdAt: createdAt,
            dismissedAt: date(row["dismissed_at"] as String?),
            subject: row["subject"] as String?
        )
    }

    /// The subject of the mail a reminder points at.
    ///
    /// A separate read because the two write paths (`set`, `setDismissed`)
    /// use `RETURNING`, which cannot join. The list paths join in the same
    /// query, so the extra read only happens on the two paths that return
    /// one row.
    private static func subject(
        remoteId: String,
        accountId: UUID,
        db: Database
    ) throws -> String? {
        try String.fetchOne(
            db,
            sql: "SELECT subject FROM message_headers WHERE account_id = ? AND remote_id = ?",
            arguments: [accountId, remoteId]
        )
    }
}
