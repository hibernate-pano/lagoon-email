import XCTest
@testable import Lagoon

/// ConnectView's server-error → user-copy mapping. The view no longer has a
/// provider switch or an OAuth poll, so this is its only remaining unit-testable
/// surface: what the user is told when the connect route refuses.
final class ConnectViewErrorCopyTests: XCTestCase {
    // MARK: - Error copy mapping (pure, view-independent)

    /// Pins the runtime language so both sides of the comparison come from the
    /// same `L10n` value regardless of test ordering.
    private func withChinese(_ body: () -> Void) {
        UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: LanguagePreference.defaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: LanguagePreference.defaultsKey) }
        body()
    }

    func test_failureCopy_mapsKnownServerCodes() {
        withChinese {
            let l10n = L10n(language: .zhHans)
            XCTAssertEqual(
                ConnectView.failureCopy(code: "imap-auth-failed", status: 401),
                l10n.qqAuthFailed
            )
            XCTAssertEqual(
                ConnectView.failureCopy(code: "imap-unreachable", status: 502),
                l10n.qqUnreachable
            )
            XCTAssertEqual(
                ConnectView.failureCopy(code: "provider-not-configured", status: 503),
                l10n.qqProviderNotConfigured
            )
            XCTAssertEqual(
                ConnectView.failureCopy(code: "internal-error", status: 500),
                l10n.qqInternalError
            )
            XCTAssertEqual(
                ConnectView.failureCopy(code: "missing-field", status: 400),
                l10n.qqMissingFields
            )
            XCTAssertNil(ConnectView.failureCopy(code: "account-exists", status: 409))
        }
    }

    func test_failureCopy_fallsBackToStatusWhenCodeIsUnparseable() {
        withChinese {
            let l10n = L10n(language: .zhHans)
            XCTAssertEqual(ConnectView.failureCopy(code: nil, status: 400), l10n.qqMissingFields)
            XCTAssertEqual(ConnectView.failureCopy(code: nil, status: 401), l10n.qqAuthFailed)
            XCTAssertNil(ConnectView.failureCopy(code: nil, status: 409))
            XCTAssertEqual(ConnectView.failureCopy(code: nil, status: 500), l10n.qqInternalError)
            XCTAssertEqual(ConnectView.failureCopy(code: nil, status: 502), l10n.qqUnreachable)
            XCTAssertEqual(ConnectView.failureCopy(code: nil, status: 503), l10n.qqProviderNotConfigured)
        }
    }

    func test_failureCopy_unknownCodeAndStatusNeverLeaksServerBody() {
        withChinese {
            let l10n = L10n(language: .zhHans)
            let copy = ConnectView.failureCopy(code: "totally-new", status: 418)
            XCTAssertEqual(copy, l10n.connectFailed + l10n.httpStatus(418))
            XCTAssertFalse(copy?.isEmpty ?? true)
            // The mapper only receives code/status, so the server body can never
            // be spliced into user-facing copy.
            XCTAssertFalse(copy?.contains("upstream exploded") ?? true)
        }
    }
}
