import Foundation

enum AsyncTimeout {
    static func sleep(for duration: Duration) async throws {
        let components = duration.components
        let seconds = max(components.seconds, 0)
        let attoseconds = max(components.attoseconds, 0)
        let nanoseconds =
            UInt64(seconds) * 1_000_000_000
            + UInt64(attoseconds / 1_000_000_000)
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}
