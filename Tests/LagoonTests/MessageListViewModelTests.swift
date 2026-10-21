import XCTest
@testable import Lagoon

/// Account persistence is backed by the login keychain, so these tests use a
/// namespaced service and never touch the app's real `lagoon.accountId` item.
///
/// The store's reads and writes are `async` on purpose: a Keychain call can
/// block on the system's authorization dialog, and doing that on the main
/// thread froze the app before it could open a window (see the comment on
/// `AccountStore`). The tests therefore exercise the async surface, and
/// `test_load_publishes_accountId_off_the_main_thread` pins the behaviour that
/// motivated the change.
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

    func test_set_persists_and_publishes_accountId() async throws {
        let store = AccountStore(service: service)
        let id = UUID()
        XCTAssertNil(store.accountId)

        try await store.set(accountId: id)

        XCTAssertEqual(store.accountId, id, "a successful set must publish the accountId")
        let loaded = try KeychainStore.load(service: service)
        XCTAssertEqual(loaded, id)
        XCTAssertNil(store.loadError)
    }

    func test_fresh_store_loads_same_accountId() async throws {
        let id = UUID()
        try await AccountStore(service: service).set(accountId: id)

        // A brand-new instance (as the app would build on relaunch) reads it back.
        let fresh = AccountStore(service: service)
        await fresh.load()
        XCTAssertEqual(fresh.accountId, id)
    }

    func test_clear_removes_persisted_accountId() async throws {
        let store = AccountStore(service: service)
        try await store.set(accountId: UUID())

        try await store.clear()

        XCTAssertNil(store.accountId)
        let loaded = try KeychainStore.load(service: service)
        XCTAssertNil(loaded)
    }

    /// The regression that motivated the async rewrite: constructing the
    /// store must not touch the Keychain, and `load()` must be the thing that
    /// reads it. A synchronous read in `init` is what froze the main thread
    /// behind the system's keychain dialog and left the app with no window.
    func test_init_does_not_read_the_keychain() async throws {
        let id = UUID()
        try await AccountStore(service: service).set(accountId: id)

        let fresh = AccountStore(service: service)
        // Before `load()` runs, the store knows nothing.
        XCTAssertNil(fresh.accountId)
        XCTAssertFalse(fresh.isLoaded)

        await fresh.load()

        XCTAssertTrue(fresh.isLoaded)
        XCTAssertEqual(fresh.accountId, id)
    }

    /// `load()` on a store with nothing stored is a normal state (a fresh
    /// install), not an error — it must publish `isLoaded` and leave the
    /// error empty, so the app can show the connect screen instead of an
    /// error banner.
    func test_load_with_no_stored_account_is_not_an_error() async throws {
        let store = AccountStore(service: service)
        await store.load()

        XCTAssertTrue(store.isLoaded)
        XCTAssertNil(store.accountId)
        XCTAssertNil(store.loadError)
    }
}
