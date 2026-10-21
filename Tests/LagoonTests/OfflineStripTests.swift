import XCTest
@testable import Lagoon

/// The offline state.
///
/// The app keeps the last synced mail in a local database, so when the
/// network drops the window still shows every message the user has already
/// seen. The only thing that changes is that new mail cannot arrive — and
/// the app used to say nothing about it, so the first sign of trouble was
/// a red "sync failed" banner that reads like the app is broken when the
/// truth is that the network is gone and the mail on screen is fine.
///
/// These pin the two halves of that promise: the app knows when it is
/// offline, and it says so without dressing the state up as an error.
@MainActor
final class OfflineStripTests: XCTestCase {
    /// Before the path monitor has reported, the app cannot claim to be
    /// online — and must not claim to be offline either.
    func test_nothingIsClaimedBeforeTheFirstReport() {
        let monitor = NetworkMonitor(monitoring: false)
        XCTAssertFalse(monitor.hasReported)
        XCTAssertTrue(monitor.isOnline, "the optimistic default is 'online', not 'broken'")
    }

    /// Losing the network is a state, and the app must report it.
    func test_goingOfflineIsReported() {
        let monitor = NetworkMonitor(monitoring: false)
        monitor.apply(online: false, expensive: false)
        XCTAssertTrue(monitor.hasReported)
        XCTAssertFalse(monitor.isOnline)
    }

    /// Coming back must clear it — a strip that stays after the network
    /// returns is a strip the user learns to ignore.
    func test_comingBackOnlineIsReported() {
        let monitor = NetworkMonitor(monitoring: false)
        monitor.apply(online: false, expensive: false)
        monitor.apply(online: true, expensive: false)
        XCTAssertTrue(monitor.isOnline)
        XCTAssertTrue(monitor.hasReported)
    }

    /// A metered path is not a broken path. The app can still work over
    /// one; it just should not quietly pull a hundred megabytes of mail
    /// down someone's data plan.
    func test_aMeteredPathIsStillOnline() {
        let monitor = NetworkMonitor(monitoring: false)
        monitor.apply(online: true, expensive: true)
        XCTAssertTrue(monitor.isOnline, "a cellular connection is a connection")
        XCTAssertTrue(monitor.isExpensive)
    }

    /// The copy has to say the mail on screen is real but stale, and it has
    /// to be there at all — the strip is the whole point.
    func test_theOfflineCopyNamesTheState() {
        let l10n = L10n(language: .zhHans)
        XCTAssertFalse(l10n.offlineNotice.isEmpty)
        XCTAssertTrue(
            l10n.offlineNotice.contains("离线"),
            "the copy should name the state the user is in"
        )
    }
}
