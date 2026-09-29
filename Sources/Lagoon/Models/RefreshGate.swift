/// The bookkeeping a list view's refresh loop shares: which response is
/// allowed to commit, and whether a caller was turned away while one was
/// already running.
///
/// Both invariants used to be comments next to a bare `Int` and two
/// booleans, written in one place and relied on in four others. The
/// archive/delete callbacks forgot to retire the in-flight poll, and a
/// refresh raised mid-poll was dropped on the floor — both because "call
/// `invalidatePendingRefresh()`" was an unwritten convention rather than
/// something the type could enforce. Making it a value means the two
/// states cannot drift apart and the sequence is testable.
struct RefreshGate {
    /// Stamped on every started refresh. A response may only commit if the
    /// gate is still on its generation, so a poll that captured the list
    /// before a local mutation cannot write the stale snapshot back.
    private(set) var generation = 0
    private(set) var isRunning = false
    /// A caller arrived while `isRunning` was true.
    private var isPending = false

    /// Take the right to run. `nil` means another call holds it; the
    /// request is remembered rather than dropped, and `finish()` reports it.
    mutating func claim() -> Int? {
        guard !isRunning else {
            isPending = true
            return nil
        }
        isRunning = true
        generation += 1
        return generation
    }

    /// Retire whatever is in flight: a local mutation of the list means
    /// the running call's payload predates it.
    mutating func invalidate() {
        generation += 1
    }

    /// Release the claim. True when a caller was turned away and is owed a
    /// run — the caller is expected to start one.
    mutating func finish() -> Bool {
        isRunning = false
        defer { isPending = false }
        return isPending
    }
}
