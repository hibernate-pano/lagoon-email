import XCTest
@testable import Lagoon

/// The banner's help link (spec INV-5).
///
/// A failure that retrying cannot fix must not offer a retry button — the
/// button would fail the same way every time, and pressing it teaches the
/// user that the app does not listen. What it must offer instead is a way
/// out. The help link is that way out, and it has to be a real, working
/// link: a banner that says "帮助" and opens nothing is worse than no
/// button at all.
final class BannerHelpLinkTests: XCTestCase {
    /// The banner carries the link.
    func test_bannerCarriesItsHelpLink() {
        let url = URL(string: "https://example.invalid/help")!
        let banner = ErrorBanner(
            severity: .error,
            title: "归档不可用",
            detail: "服务器没有可归档的文件夹。",
            helpURL: url
        )
        XCTAssertEqual(banner.helpURL, url)
    }

    /// A banner with no help link simply has none — the button must not
    /// appear for the failures that a retry does fix.
    func test_bannerWithoutHelpLinkHasNone() {
        let banner = ErrorBanner(severity: .error, title: "归档失败", detail: "请重试。")
        XCTAssertNil(banner.helpURL)
    }

    /// The link is a `mailto:` that already says what went wrong, so the
    /// person on the other end does not have to ask.
    func test_supportMailtoCarriesTheSubjectAndTheContext() throws {
        let url = try XCTUnwrap(
            LagoonHelp.supportMailto(subject: "归档不可用", body: "服务器没有可归档的文件夹。")
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.scheme, "mailto")
        XCTAssertEqual(components.path, LagoonHelp.supportAddress)
        let items = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        )
        XCTAssertEqual(items["subject"], "归档不可用")
        XCTAssertEqual(items["body"], "服务器没有可归档的文件夹。")
    }

    /// The About sheet's feedback button and the banner's help link have to
    /// reach the same place, or the product has two support channels and
    /// only one of them is monitored.
    func test_theAboutSheetAndTheBannerShareOneSupportAddress() {
        XCTAssertEqual(
            LagoonHelp.feedbackMailto.scheme, "mailto",
            "the shared feedback link must still be a mailto"
        )
        XCTAssertTrue(
            LagoonHelp.feedbackMailto.absoluteString.contains(LagoonHelp.supportAddress),
            "the shared feedback link must address the support inbox"
        )
    }

    /// The support address has to be an address. A malformed one produces a
    /// `mailto:` that no mail client can act on, and the user is left with
    /// a button that silently does nothing.
    func test_theSupportAddressLooksLikeAnAddress() {
        XCTAssertTrue(
            LagoonHelp.supportAddress.contains("@"),
            "the support address is not an address: '\(LagoonHelp.supportAddress)'"
        )
        XCTAssertFalse(
            LagoonHelp.supportAddress.contains(" "),
            "the support address contains a space"
        )
    }
}
