import Foundation

/// Serializes an async operation that spans suspension points.
///
/// Swift actors are reentrant: while one actor method awaits I/O, another
/// method can enter and start a second command on the same non-pipelined
/// connection. IMAP requires one complete tagged command at a time, so the
/// provider holds this lock across the whole command sequence.
actor AsyncMutex {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func lock() async {
        if !isLocked {
            isLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func unlock() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
