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

    /// Re-authentication reuses the account id, so replacing an entry drops a
    /// provider that may still hold a live IMAP session. QQ caps concurrent
    /// sessions per account, so the replaced one has to be closed, not dropped.
    func test_replacedProviderIsShutDownNotJustDropped() async {
        let pool = MailProviderPool()
        let id = UUID()
        func account(blob: String) -> Account {
            Account(
                id: id,
                provider: .qq,
                oauthUser: "pool@qq.com",
                email: "pool@qq.com",
                credentials: Data(blob.utf8)
            )
        }
        let first = StubMailProvider()
        let second = StubMailProvider()

        _ = await pool.provider(for: account(blob: "v1")) { _ in first }
        _ = await pool.provider(for: account(blob: "v2")) { _ in second }

        let firstClosed = await first.shutdownCount
        let secondClosed = await second.shutdownCount
        XCTAssertEqual(firstClosed, 1, "the replaced provider's session must be released")
        XCTAssertEqual(secondClosed, 0, "the live provider is not shut down")
    }

    /// A deleted account is never asked for again, so its pooled provider and
    /// session must go when the row does.
    func test_releaseDropsTheEntryAndShutsItDown() async {
        let pool = MailProviderPool()
        let id = UUID()
        let account = Account(
            id: id,
            provider: .qq,
            oauthUser: "pool@qq.com",
            email: "pool@qq.com",
            credentials: Data("v1".utf8)
        )
        let held = StubMailProvider()
        _ = await pool.provider(for: account) { _ in held }

        await pool.release(id)

        let heldClosed = await held.shutdownCount
        XCTAssertEqual(heldClosed, 1)
        // And the next caller must get a fresh provider, not the released one.
        let rebuilt = StubMailProvider()
        let next = await pool.provider(for: account) { _ in rebuilt }
        XCTAssertTrue((next as? StubMailProvider) === rebuilt)
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
