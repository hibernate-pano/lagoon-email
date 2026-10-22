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
///
/// ## Why the link is optional
///
/// The product ships without a support channel, so there is nothing for
/// the link to open — and the button is not rendered at all. That is the
/// same rule as a banner that says "帮助" and opens nothing: a channel
/// that does not exist must not be offered as one.
final class BannerHelpLinkTests: XCTestCase {
    private let zh = L10n(language: .zhHans)
    private let en = L10n(language: .english)

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
            LagoonHelp.supportMailto(
                to: "support@example.invalid",
                subject: "归档不可用",
                body: "服务器没有可归档的文件夹。"
            )
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.scheme, "mailto")
        XCTAssertEqual(components.path, "support@example.invalid")
        let items = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        )
        XCTAssertEqual(items["subject"], "归档不可用")
        XCTAssertEqual(items["body"], "服务器没有可归档的文件夹。")
    }

    /// The banner's link says what failed *and* asks for the one thing
    /// only the user knows.
    func test_theBannerLinkCarriesTheFailureAndTheRequest() throws {
        let url = try XCTUnwrap(
            LagoonHelp.bannerMailto(
                to: "support@example.invalid",
                failure: "归档不可用",
                detail: "服务器没有可归档的文件夹。",
                l10n: zh
            )
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        )
        XCTAssertEqual(components.path, "support@example.invalid")
        XCTAssertTrue(items["subject"]?.contains("归档不可用") == true)
        XCTAssertTrue(items["body"]?.contains("归档不可用") == true)
        XCTAssertTrue(
            items["body"]?.contains(zh.helpRequestFooter) == true,
            "the report has to ask for the thing only the user knows"
        )
    }

    /// Without a configured channel there is no link at all.
    ///
    /// The product ships without one, and the two entry points have to
    /// agree: the About sheet's feedback button and the banner's help
    /// button reach the same inbox — or neither of them exists.
    func test_withoutAChannelThereIsNoLinkToOffer() {
        guard let address = LagoonHelp.supportAddress else {
            XCTAssertNil(
                LagoonHelp.feedbackMailto,
                "no support address, no feedback link"
            )
            XCTAssertNil(
                LagoonHelp.supportMailto(subject: "s", body: "b"),
                "no support address, nothing to write to"
            )
            XCTAssertNil(
                LagoonHelp.bannerMailto(failure: "f", detail: "d", l10n: zh),
                "no support address, the banner must not offer a help button"
            )
            XCTAssertNil(
                LagoonHelp.bannerMailto(failure: "f", detail: "d", l10n: en),
                "the help button is not a Chinese-only affordance"
            )
            return
        }
        // With an address configured, both entry points must reach it.
        XCTAssertEqual(
            LagoonHelp.feedbackMailto?.path,
            address,
            "the About sheet and the banner must reach the same inbox"
        )
        XCTAssertEqual(LagoonHelp.feedbackMailto?.scheme, "mailto")
    }
}
