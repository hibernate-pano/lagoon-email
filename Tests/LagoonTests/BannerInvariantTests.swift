import XCTest
@testable import Lagoon

/// The error-banner invariants, checked structurally.
///
/// Spec `docs/superpowers/specs/2026-09-13-client-ux-feedback-discipline.md`:
///
/// - **INV-3** — `detail` must not be empty; it says what failed *and* why.
/// - **INV-4** — a retryable failure carries `actionLabel = l10n.retry`.
/// - **INV-5** — a failure retrying cannot fix carries no retry, and carries
///   a help link instead.
///
/// These are checked on the *source*, not on a live view, because the
/// banner is built at call sites spread over a dozen files and a unit test
/// cannot drive a `@State` banner. The alternative — trusting review to
/// catch a missing `detail:` in the next file that grows one — is exactly
/// how nine banners ended up without one.
///
/// The scanner finds each `ErrorBanner(` call and reads its arguments.
final class BannerInvariantTests: XCTestCase {
    /// One `ErrorBanner(...)` call site.
    private struct CallSite {
        let file: String
        let line: Int
        let severity: String
        let body: String
    }

    /// The 1-based line a character offset falls on.
    ///
    /// Not `prefix.split(separator: "\n").count` — Swift's `split` drops
    /// empty subsequences, so that counts *non-blank* lines and reports a
    /// number that looks plausible and is wrong. A test that points the
    /// reader at the wrong line is worse than one that points nowhere.
    private static func line(of offset: String.Index, in text: String) -> Int {
        text[text.startIndex..<offset].reduce(into: 1) { count, character in
            if character == "\n" { count += 1 }
        }
    }

    /// Every `ErrorBanner(...)` construction in the client.
    private func callSites() throws -> [CallSite] {
        let root = ViewSource.url(under: "Views", "RootView")
            .deletingLastPathComponent()          // Views
            .deletingLastPathComponent()          // Lagoon
        let urls = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil
        )?.compactMap { ($0 as? URL) }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(urls.isEmpty, "no client sources found under \(root.path)")

        var found: [CallSite] = []
        for url in urls {
            let text = try String(contentsOf: url, encoding: .utf8)
            var searchStart = text.startIndex
            while let open = text.range(of: "ErrorBanner(", range: searchStart..<text.endIndex) {
                searchStart = open.upperBound
                // The type's own declaration is not a call site.
                let prefix = text[text.startIndex..<open.lowerBound]
                if prefix.hasSuffix("public let ") { continue }

                var depth = 1
                var index = open.upperBound
                while index < text.endIndex, depth > 0 {
                    if text[index] == "(" { depth += 1 }
                    else if text[index] == ")" { depth -= 1 }
                    index = text.index(after: index)
                }
                let body = String(text[open.upperBound..<text.index(before: index)])
                let severity: String
                if body.contains("severity: .error") { severity = "error" }
                else if body.contains("severity: .warning") { severity = "warning" }
                else { severity = "other" }
                found.append(
                    CallSite(
                        file: url.lastPathComponent,
                        line: Self.line(of: open.lowerBound, in: text),
                        severity: severity,
                        body: body
                    )
                )
            }
        }
        return found
    }

    /// INV-3: an error or a warning must say *why*, not just *what*.
    ///
    /// "同步失败" on its own leaves the user with three identical
    /// possibilities and no way to choose between them. The detail is the
    /// half that lets them choose.
    func test_everyErrorAndWarningBannerHasADetail() throws {
        var missing: [String] = []
        for site in try callSites() where site.severity == "error" || site.severity == "warning" {
            let hasDetail = site.body.contains("detail:")
            // A detail that is an empty string is the same defect as no
            // detail at all — the banner draws the second line and says
            // nothing.
            let isEmpty = site.body.contains("detail: \"\"") || site.body.contains("detail: \" \"")
            if !hasDetail || isEmpty {
                missing.append("\(site.file):\(site.line) [\(site.severity)]")
            }
        }
        XCTAssertTrue(
            missing.isEmpty,
            """
            These banners have no usable `detail:` — the user is told what \
            failed but not why (spec INV-3):
            \(missing.joined(separator: "\n"))
            """
        )
    }

    /// No dead-end banner.
    ///
    /// A failure with neither a button nor a help link leaves the user
    /// staring at a red strip with nothing to click — which is the whole
    /// difference between a product that reports a problem and one that
    /// dumps it. The way forward can be a retry (INV-4), a *specific* other
    /// action such as "重新连接", or a help link (INV-5); what it cannot
    /// be is nothing.
    func test_everyErrorBannerOffersAWayForward() throws {
        var deadEnds: [String] = []
        for site in try callSites() where site.severity == "error" {
            // `NoticeBannerView` only draws the button when *both* halves
            // are present, so a label without an action renders nothing.
            let hasButton = site.body.contains("actionLabel:") && site.body.contains("action:")
            let hasHelp = site.body.contains("helpURL:")
            if !hasButton && !hasHelp {
                deadEnds.append("\(site.file):\(site.line)")
            }
        }
        XCTAssertTrue(
            deadEnds.isEmpty,
            """
            These error banners offer neither a button nor a help link — the \
            user has nothing to click (spec INV-4 / INV-5):
            \(deadEnds.joined(separator: "\n"))
            """
        )
    }

    /// The scanner must actually find the banners. A scanner that silently
    /// matches nothing turns every assertion above into a green light
    /// wired to nothing.
    func test_theScannerActuallyFindsBanners() throws {
        let sites = try callSites()
        XCTAssertGreaterThan(sites.count, 30, "the banner scanner found almost nothing")
        XCTAssertGreaterThan(
            sites.filter { $0.severity == "error" }.count, 15,
            "the banner scanner found almost no error banners"
        )
    }
}
