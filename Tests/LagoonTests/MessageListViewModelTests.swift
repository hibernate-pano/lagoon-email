import XCTest
@testable import Lagoon

@MainActor
final class MessageListViewModelTests: XCTestCase {
    func test_set_account_persists_uuid() {
        let store = AccountStore()
        let id = UUID()
        store.set(accountId: id)
        XCTAssertEqual(KeychainStore.load(), id)
        store.clear()
        XCTAssertNil(KeychainStore.load())
        XCTAssertNil(store.accountId)
    }
}
