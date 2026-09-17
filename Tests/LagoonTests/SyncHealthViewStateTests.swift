import XCTest
@testable import LagoonKit

/// Spec §4.6 — covers the 5-case projection from `SyncHealth` to
/// `SyncHealthViewState`. The `lastSyncAt == nil` branch is the one
/// that catches "account exists, never completed a round" vs. "account
/// exists, last round was fine".
final class SyncHealthViewStateTests: XCTestCase {
    func test_okWithNoLastSync_mapsToSyncing() {
        let health = SyncHealth(status: .ok, lastSyncAt: nil)
        XCTAssertEqual(SyncHealthViewState.from(health), .syncing)
    }

    func test_okWithLastSync_mapsToOk() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let health = SyncHealth(status: .ok, lastSyncAt: now)
        XCTAssertEqual(SyncHealthViewState.from(health), .ok)
    }

    func test_degraded_carriesReason() {
        let health = SyncHealth(status: .degraded, lastError: "imap slow")
        XCTAssertEqual(SyncHealthViewState.from(health), .degraded(reason: "imap slow"))
    }

    func test_degradedWithoutReason_usesPlaceholder() {
        let health = SyncHealth(status: .degraded, lastError: nil)
        XCTAssertEqual(SyncHealthViewState.from(health), .degraded(reason: "—"))
    }

    func test_error_carriesReason() {
        let health = SyncHealth(status: .error, lastError: "connection refused")
        XCTAssertEqual(SyncHealthViewState.from(health), .error(reason: "connection refused"))
    }

    func test_needsReconnect_carriesReason() {
        let health = SyncHealth(status: .needsReconnect, lastError: "auth expired")
        XCTAssertEqual(SyncHealthViewState.from(health), .needsReconnect(reason: "auth expired"))
    }
}
