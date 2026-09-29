import Foundation
import GRDB

/// The storage seam every store, route and loop speaks: a `DatabasePool`
/// (the normal case) or an existing `Database` handle when the caller owns a
/// transaction (`LagoonDB(transaction:)` inside `pool.write { db in ... }`).
///
/// The Postgres build threaded raw `PostgresConnection`s around and needed
/// one-connection-per-loop because a wire connection serves one query at a
/// time. WAL SQLite has no such constraint: one pool is shared by every loop
/// and route, writes serialize on the writer queue, reads pool concurrently.
///
/// The blocking GRDB APIs are used deliberately: queries here are
/// millisecond-scale and the app is single-user; the cooperative-friendly
/// async variants would force `Sendable` on every row type and forbid the
/// transaction-joining pattern the action routes rely on.
public struct LagoonDB {
    private let pool: DatabasePool?
    private let existing: Database?

    public init(_ pool: DatabasePool) {
        self.pool = pool
        self.existing = nil
    }

    /// Joins a transaction owned by the caller. The handle is valid only for
    /// the duration of that closure — do not store it.
    public init(transaction: Database) {
        self.pool = nil
        self.existing = transaction
    }

    /// Runs `body` with a database handle, joining the caller's transaction
    /// when there is one. On a pool this participates in GRDB's implicit
    /// write transaction; nested via `transaction:` it is plain SQL on the
    /// outer transaction.
    public func write<T>(_ body: (Database) throws -> T) throws -> T {
        if let existing { return try body(existing) }
        return try pool!.write(body)
    }

    /// Runs `body` with a read-only view. On a pool this borrows a reader
    /// from the pool; via `transaction:` it reads through the outer handle.
    public func read<T>(_ body: (Database) throws -> T) throws -> T {
        if let existing { return try body(existing) }
        return try pool!.read(body)
    }
}
