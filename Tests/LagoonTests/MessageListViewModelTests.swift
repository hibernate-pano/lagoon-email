import XCTest
@testable import Lagoon

/// Account persistence is backed by the login keychain, so these tests use a
/// namespaced service and never touch the app's real `lagoon.accountId` item.
@MainActor
final class MessageListViewModelTests: XCTestCase {
    private let service = "lagoon.accountId.test"

    override func setUp() {
        super.setUp()
        // Start from a clean slate even if a previous run crashed mid-test.
        try? KeychainStore.clear(service: "lagoon.accountId.test")
    }

    nonisolated override func tearDown() {
        // Tolerates a missing item: clear() is a no-op for errSecItemNotFound.
        try? KeychainStore.clear(service: "lagoon.accountId.test")
        super.tearDown()
    }

    func test_set_persists_and_publishes_accountId() throws {
        let store = AccountStore(service: service)
        let id = UUID()
        XCTAssertNil(store.accountId)

        try store.set(accountId: id)

        XCTAssertEqual(store.accountId, id, "a successful set must publish the accountId")
        let loaded = try KeychainStore.load(service: service)
        XCTAssertEqual(loaded, id)
        XCTAssertNil(store.loadError)
    }

    func test_fresh_store_loads_same_accountId() throws {
        let id = UUID()
        try AccountStore(service: service).set(accountId: id)

        // A brand-new instance (as the app would build on relaunch) reads it back.
        let fresh = AccountStore(service: service)
        XCTAssertEqual(fresh.accountId, id)
    }

    func test_clear_removes_persisted_accountId() throws {
        let store = AccountStore(service: service)
        try store.set(accountId: UUID())

        try store.clear()

        XCTAssertNil(store.accountId)
        let loaded = try KeychainStore.load(service: service)
        XCTAssertNil(loaded)
    }
}
