import Foundation
import XCTest
@testable import LagoonServer

final class AsyncMutexTests: XCTestCase {
    func test_serializesConcurrentAsyncSections() async {
        let mutex = AsyncMutex()
        let probe = ConcurrencyProbe()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    await mutex.lock()
                    await probe.enter()
                    try? await Task.sleep(for: .milliseconds(2))
                    await probe.leave()
                    await mutex.unlock()
                }
            }
        }

        let maximum = await probe.maximum
        XCTAssertEqual(maximum, 1)
    }
}

private actor ConcurrencyProbe {
    private var active = 0
    private(set) var maximum = 0

    func enter() {
        active += 1
        maximum = max(maximum, active)
    }

    func leave() {
        active -= 1
    }
}
