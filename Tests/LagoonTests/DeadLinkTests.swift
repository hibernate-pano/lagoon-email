import XCTest
import Foundation
@testable import Lagoon

/// Guards the product's outbound links.
///
/// ## The class of bug these guard
///
/// A button that opens a link is a claim: *this destination exists and
/// somebody reads it*. The product shipped two claims it could not back —
/// a support address on a domain that is not registered, and a website on
/// that same domain — and every surface that offered them offered a dead
/// end instead of an exit.
///
/// The fix is not a better URL; it is that a channel is **configured or it
/// is not**, and a surface renders the button only when there is one. So
/// these tests guard two things: that the channels are configured from
/// outside the source (so an address is never compiled in), and that no
/// file smuggles a link back in.
final class DeadLinkTests: XCTestCase {
    private let zh = L10n(language: .zhHans)
    private let en = L10n(language: .english)

    // MARK: - The channels

    /// The product ships with no support channel.
    ///
    /// Not "the address is wrong" — there is no address, on purpose. A
    /// configured channel is a fact about a running app, not about the
    /// source, so the value comes from `Info.plist` and this test says so
    /// out loud: when a support address is configured for real, this test
    /// has to be replaced by one that checks the buttons it enables.
    func test_theProductShipsWithoutASupportChannel() {
        XCTAssertNil(
            LagoonHelp.supportAddress,
            "the app now has a support address: the About sheet's feedback button "
                + "and the banner's help button have to exist for it, and this test "
                + "has to be replaced by one that checks that they do"
        )
        XCTAssertNil(
            LagoonHelp.siteURL,
            "the app now has a website: the About sheet's website button has to "
                + "exist for it, and this test has to be replaced by one that "
                + "checks that it does"
        )
    }

    /// A channel is offered only when it is configured.
    ///
    /// This is the rule the whole fix rests on, and it is stated so that it
    /// holds in both directions: a configured address produces a link that
    /// points at that address, and an unconfigured one produces no link at
    /// all — never a link to somewhere that does not exist.
    func test_aChannelIsOfferedOnlyWhenItIsConfigured() {
        if let address = LagoonHelp.supportAddress {
            XCTAssertTrue(
                address.contains("@"),
                "a configured support address has to be an address: \(address)"
            )
            XCTAssertEqual(
                LagoonHelp.feedbackMailto?.path,
                address,
                "the feedback link must reach the configured address"
            )
            let support = LagoonHelp.supportMailto(subject: "s", body: "b")
            XCTAssertEqual(support?.path, address)
            XCTAssertNotNil(
                LagoonHelp.bannerMailto(failure: "f", detail: "d", l10n: zh),
                "a configured channel means the banner's help button has a link to open"
            )
        } else {
            XCTAssertNil(
                LagoonHelp.feedbackMailto,
                "with no support address there is nothing for the feedback button to open"
            )
            XCTAssertNil(
                LagoonHelp.supportMailto(subject: "s", body: "b"),
                "with no support address there is nothing to write to"
            )
            XCTAssertNil(
                LagoonHelp.bannerMailto(failure: "f", detail: "d", l10n: zh),
                "with no support address the banner must not offer a help button"
            )
            XCTAssertNil(
                LagoonHelp.bannerMailto(failure: "f", detail: "d", l10n: en),
                "the banner's help button is not a Chinese-only affordance"
            )
        }
    }

    /// The support address is configuration, not source.
    ///
    /// The address used to be a constant in `LagoonHelp.swift`, which
    /// meant it was in the repository and in every build of the app. A
    /// channel is a fact about whoever is running the product, so it is
    /// read from `Info.plist` — and the key name is the only thing the
    /// source has to know.
    func test_theSupportAddressIsNotCompiledIntoTheSource() throws {
        let source = try ViewSource.read("LagoonHelp")
        XCTAssertTrue(
            source.contains("LagoonSupportEmail"),
            "the channel must be read from Info.plist by key, not hardcoded"
        )
        XCTAssertFalse(
            source.contains("@"),
            "LagoonHelp must not contain a mail address: a support address is "
                + "configuration, and configuration does not live in the repository"
        )
    }

    // MARK: - No link to somewhere that does not exist

    /// No source file may point a link at the domain that does not exist.
    ///
    /// The check is deliberately about *links*: the package also contains
    /// `com.lagoon.email.server.plist`, which is a LaunchAgent file name
    /// and not something a user can click. A grep for the bare domain would
    /// flag that and teach everyone to ignore the test.
    func test_noSourceFileLinksToTheUnregisteredDomain() throws {
        let offenders = try Self.linkLiterals().filter {
            $0.contains("lagoon.email") || $0.contains("{{")
        }
        XCTAssertTrue(
            offenders.isEmpty,
            """
            These literals point at a domain that is not registered, or at a \
            template that was never filled in:
            \(offenders.sorted().joined(separator: "\n"))

            A link is a claim that the destination exists. If the channel is
            not configured, the surface renders no button at all.
            """
        )
    }

    /// The About sheet renders a button only when there is a link to open.
    func test_theAboutSheetRendersNoButtonWithoutALink() throws {
        let source = try ViewSource.read("AboutSheet")
        XCTAssertTrue(
            source.contains("if let feedbackMailto = LagoonHelp.feedbackMailto"),
            "the feedback button must be behind the channel it opens"
        )
        XCTAssertTrue(
            source.contains("if let siteURL = LagoonHelp.siteURL"),
            "the website button must be behind the channel it opens"
        )
        XCTAssertTrue(
            source.contains("NSWorkspace.shared.open(feedbackMailto)"),
            "the feedback button must open the link it was given"
        )
        XCTAssertTrue(
            source.contains("NSWorkspace.shared.open(siteURL)"),
            "the website button must open the link it was given"
        )
    }

    /// The banner's help button is behind the link it opens.
    ///
    /// The banner was the other half of the dead-link problem: eight
    /// surfaces offered a 「帮助」 button whose mailto went to a mailbox
    /// nobody owns. The button is already conditional — this guards that
    /// it stays that way.
    func test_theBannerHelpButtonIsBehindItsLink() throws {
        let source = try ViewSource.read("NoticeBanner")
        XCTAssertTrue(
            source.contains("if let helpURL = banner.helpURL"),
            "the help button must be rendered only when there is a link to open"
        )
    }

    // MARK: - Helpers

    /// Every string literal in the product that looks like a link.
    private static func linkLiterals() throws -> [String] {
        let root = ViewSource.url(under: "Views", "RootView")
            .deletingLastPathComponent()          // Views
            .deletingLastPathComponent()          // Lagoon
            .deletingLastPathComponent()          // Sources
        let urls = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil
        )?.compactMap { ($0 as? URL) }.filter { $0.pathExtension == "swift" } ?? []
        var found: [String] = []
        let pattern = try NSRegularExpression(pattern: "\"[^\"]*(?:https?://|mailto:)[^\"]*\"")
        for url in urls {
            let text = try String(contentsOf: url, encoding: .utf8)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in pattern.matches(in: text, range: range) {
                guard let swiftRange = Range(match.range, in: text) else { continue }
                found.append(String(text[swiftRange]))
            }
        }
        return found
    }
}
