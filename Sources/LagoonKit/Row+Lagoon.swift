import Foundation
import GRDB

/// Shared row-decoding helpers for the SQLite storage layer. They keep the
/// ported `decode(_:)` functions as small as the Postgres ones were: NOT NULL
/// columns read through GRDB's generic subscript (`row["id"]`), optional and
/// `NULLIF`-style columns through these.
extension Row {
    /// '' reads as nil, matching the Postgres `NULLIF(x, '')` projections.
    public func optionalText(_ column: String) -> String? {
        let value: String? = self[column]
        return value.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Decode a TEXT column holding JSON. nil when the column is NULL or the
    /// bytes do not parse — the lenient fallback the Postgres `.jsonb`
    /// accessors had, kept because every call site pairs it with a default.
    public func decodedJSON<T: Decodable>(
        _ column: String,
        as type: T.Type,
        decoder: JSONDecoder
    ) -> T? {
        guard let text: String = self[column], let data = text.data(using: .utf8) else {
            return nil
        }
        return try? decoder.decode(type, from: data)
    }
}
