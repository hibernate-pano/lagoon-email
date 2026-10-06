import Foundation

/// The one date format Lagoon writes to SQLite and reads back.
///
/// ## Why this exists
///
/// `received_at` is a TEXT column, which is the right choice for SQLite: the
/// format below sorts lexicographically in the same order it sorts
/// chronologically, so `ORDER BY received_at DESC` is a correct "newest first"
/// without an index on a numeric column, and `MAX(received_at)` is a correct
/// "latest" inside a GROUP BY.
///
/// The cost is that a TEXT column is not self-describing: GRDB decodes a `Date`
/// only when it knows the column's declared type, so anything that reads the
/// column through an *expression* — `MAX(received_at)`, a `CASE` branch, a
/// `COALESCE` — gets a `String` and fails to decode. This formatter is what
/// those call sites use.
///
/// Fixed ` Locale(identifier: "en_US_POSIX")` and UTC, both deliberate:
/// a locale-sensitive formatter would write "2026/10/05" on one machine and
/// "10/05/2026" on another, and neither sorts correctly against the other; a
/// local-time formatter would make the stored value shift with the machine's
/// timezone, so a row synced in Shanghai and read in Berlin would be wrong by
/// hours.
public enum StoredDate {
    public static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    /// Renders a date in the stored form. Returns nil for a nil input rather
    /// than a placeholder string, so a caller cannot accidentally persist "nil".
    public static func string(from date: Date?) -> String? {
        guard let date else { return nil }
        return formatter.string(from: date)
    }

    /// Parses the stored form, returning nil for anything unrecognisable.
    ///
    /// Total by design: a malformed date in one row must not take down the query
    /// that reads it. Callers decide what a missing date means.
    public static func date(from raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        if let parsed = formatter.date(from: raw) { return parsed }
        return ISO8601DateFormatter().date(from: raw)
    }
}