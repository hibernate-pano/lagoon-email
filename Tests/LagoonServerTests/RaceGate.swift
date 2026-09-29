import Foundation

/// One-way rendezvous for race tests. The code under test parks inside
/// `hold()`, the test learns it got there (`waitForArrival()`) and decides
/// when to let it out (`release()`). Parking is unbounded on purpose: the
/// test always releases, and a code path that never parks simply leaves
/// nobody waiting.
actor RaceGate {
    private var arrived = false
    private var isOpen = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var holdWaiters: [CheckedContinuation<Void, Never>] = []

    /// Park here until the test releases the gate.
    func hold() async {
        arrived = true
        for waiter in arrivalWaiters { waiter.resume() }
        arrivalWaiters.removeAll()
        if isOpen { return }
        await withCheckedContinuation { holdWaiters.append($0) }
    }

    /// Suspend until some code path has called `hold()`.
    func waitForArrival() async {
        if arrived { return }
        await withCheckedContinuation { arrivalWaiters.append($0) }
    }

    /// Let the parked caller — and every later one — through.
    func release() {
        isOpen = true
        for waiter in holdWaiters { waiter.resume() }
        holdWaiters.removeAll()
    }
}
