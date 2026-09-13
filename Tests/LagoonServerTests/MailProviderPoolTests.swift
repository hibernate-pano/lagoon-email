import Foundation
import LagoonKit
import XCTest
@testable import LagoonServer

final class MailProviderPoolTests: XCTestCase {
    func test_reusesProviderForSameAccountIdentity() async {
        let counter = BuildCounter()
        let pool = MailProviderPool()
        let account = Account(
            id: UUID(),
            provider: .qq,
            oauthUser: "pool@qq.com",
            email: "pool@qq.com",
            credentials: Data("credential-v1".utf8)
        )

        let first = await pool.provider(for: account) { account in
            _ = counter.increment()
            return StubMailProvider(kind: account.provider)
        }
        let second = await pool.provider(for: account) { account in
            _ = counter.increment()
            return StubMailProvider(kind: account.provider)
        }

        XCTAssertTrue((first as? StubMailProvider) === (second as? StubMailProvider))
        XCTAssertEqual(counter.value, 1)
    }

    func test_rebuildsProviderWhenCredentialsChange() async {
        let counter = BuildCounter()
        let pool = MailProviderPool()
        let id = UUID()
        let firstAccount = Account(
            id: id,
            provider: .qq,
            oauthUser: "pool@qq.com",
            email: "pool@qq.com",
            credentials: Data("credential-v1".utf8)
        )
        let secondAccount = Account(
            id: id,
            provider: .qq,
            oauthUser: "pool@qq.com",
            email: "pool@qq.com",
            credentials: Data("credential-v2".utf8)
        )

        let first = await pool.provider(for: firstAccount) { account in
            _ = counter.increment()
            return StubMailProvider(kind: account.provider)
        }
        let second = await pool.provider(for: secondAccount) { account in
            _ = counter.increment()
            return StubMailProvider(kind: account.provider)
        }

        XCTAssertFalse((first as? StubMailProvider) === (second as? StubMailProvider))
        XCTAssertEqual(counter.value, 2)
    }
}

private final class BuildCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
