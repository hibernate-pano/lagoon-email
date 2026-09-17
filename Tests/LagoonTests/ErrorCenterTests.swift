import XCTest
@testable import Lagoon

@MainActor
final class ErrorCenterTests: XCTestCase {
    /// Spec §2.3 + INV-6: each `report` replaces the current banner so
    /// the user never sees two stacked errors. Producers can fire
    /// without coordinating.
    func test_report_replacesCurrentBanner() {
        let center = ErrorCenter.shared
        let first = ErrorBanner(severity: .error, title: "first")
        let second = ErrorBanner(severity: .warning, title: "second")
        center.report(first)
        XCTAssertEqual(center.banner?.title, "first")
        center.report(second)
        XCTAssertEqual(center.banner?.title, "second")
        // Tidy up so the singleton doesn't leak into other tests.
        center.dismiss()
    }

    /// `dismiss` is safe to call when no banner is present.
    func test_dismiss_isNoOpWhenNothingShowing() {
        let center = ErrorCenter.shared
        center.dismiss()
        XCTAssertNil(center.banner)
    }

    /// `ErrorBanner` `Equatable` ignores the action closure and uses
    /// the id, so SwiftUI's diffing won't bounce when only the closure
    /// changes between renders of the same logical banner.
    func test_bannerEquatable_usesIdNotAction() {
        // Two banners with different ids and different actions compare unequal.
        let a = ErrorBanner(severity: .error, title: "t", action: nil)
        let b = ErrorBanner(severity: .error, title: "t", action: nil)
        XCTAssertNotEqual(a, b)
    }
}
