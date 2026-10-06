import XCTest
@testable import Lagoon

/// Structural guards for the three-column layout.
///
/// ## Why most of these read source instead of calling code
///
/// The invariant that matters most is an **absence**: there must be no
/// `NavigationSplitView` and no `NSView` in the layout, because each was the
/// thing that produced a window that could not be trusted.
///
/// A behavioural test cannot catch either. Re-adding `NavigationSplitView` would
/// compile, every width would still solve, every drag would still work — and the
/// window would show a duplicate sidebar toggle in the corner, because
/// `NavigationSplitView` injects one into the *window* toolbar and `RootView`
/// keeps both surfaces alive in a ZStack (see
/// `.memory/toolbar-items-escape-hidden-zstack-surfaces`). Re-adding an AppKit
/// container would compile too, and the second layout authority would only
/// surface as a blank window or an endless constraint loop at run time — the
/// failure this layout was rewritten to end.
///
/// So the only thing that fails is a test that reads the source.
final class ColumnLayoutGuardTests: XCTestCase {
    /// The layout's own sources.
    private func layoutSources() throws -> [(name: String, text: String)] {
        let root = ViewSource.url(under: "Views", "MessageSplitLayout")
            .deletingLastPathComponent()
        let urls = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil
        )?.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(urls.isEmpty, "no layout sources found under \(root.path)")
        return try urls.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    /// No split view anywhere in the layout. See the type comment.
    func test_theLayoutContainsNoNavigationSplitView() throws {
        for (name, text) in try layoutSources() {
            // Comments are stripped deliberately: several of them *name*
            // `NavigationSplitView` while explaining why it must not come back,
            // and a test that read the prose would fail for the wrong reason.
            let code = Self.strippingComments(text)
            XCTAssertFalse(
                code.contains("NavigationSplitView"),
                """
                \(name) uses NavigationSplitView.

                That re-introduces the automatic sidebar toggle, which the window
                toolbar shows once per keep-alive surface. The layout is an
                HStack of solved columns; see MessageSplitLayout's doc comment.
                """
            )
        }
    }

    /// The same guard, wider: nothing under `Sources/` may reintroduce one.
    func test_noClientSourceUsesNavigationSplitView() throws {
        let root = ViewSource.url(under: "Views", "RootView")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let urls = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil
        )?.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        var offenders: [String] = []
        for url in urls {
            let text = try String(contentsOf: url, encoding: .utf8)
            if Self.strippingComments(text).contains("NavigationSplitView") {
                offenders.append(url.lastPathComponent)
            }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            "NavigationSplitView reappeared in: \(offenders.joined(separator: ", "))"
        )
    }

    /// No AppKit in the layout. The whole point of this rewrite.
    ///
    /// The previous attempt built the columns out of `NSSplitView` and wrote
    /// frames on the AppKit side. That put a second layout authority on the same
    /// geometry as SwiftUI's `HStack`, each update invalidating the other, and
    /// the window either rendered blank or died in an endless `Update Constraints`
    /// loop. One authority is not a style preference here; it is the fix.
    ///
    /// **Scoped to the layout's own files.** `HTMLMessageView` is a
    /// `NSViewRepresentable` around `WKWebView` because there is no SwiftUI
    /// equivalent for rendering an HTML mail body, and it is not a layout
    /// authority — it fills whatever frame it is handed. `AboutSheet` and
    /// `MessageDetailView` import AppKit for `NSWorkspace` and `NSSound`. The
    /// line is "no AppKit *geometry*", not "no AppKit".
    func test_theLayoutUsesNoAppKitGeometry() throws {
        // The layout is the column skeleton plus the two views that place the
        // columns — not everything under `Views/`.
        let layoutRoot = ViewSource.url(under: "Views", "MessageSplitLayout")
            .deletingLastPathComponent()
            .appendingPathComponent("ColumnLayout")
        let skeleton = ViewSource.url(under: "Views", "MessageSplitLayout")
        var files = (FileManager.default.enumerator(
            at: layoutRoot, includingPropertiesForKeys: nil
        )?.compactMap { $0 as? URL } ?? []).filter { $0.pathExtension == "swift" }
        files.append(skeleton)

        for url in files {
            let code = Self.strippingComments(
                try String(contentsOf: url, encoding: .utf8)
            )
            for banned in ["import AppKit", "NSView", "NSSplitView", "NSViewRepresentable"] {
                XCTAssertFalse(
                    code.contains(banned),
                    "\(url.lastPathComponent) contains \(banned) — the layout's "
                    + "geometry must have exactly one authority, and that one is SwiftUI"
                )
            }
        }
    }

    /// Nothing animates inside the layout itself. The spec's first rule.
    ///
    /// A `.animation` or `withAnimation` in the layout's own hot path would make
    /// a width chase the pointer, which is the exact lag the whole exercise
    /// exists to remove — and it would not show up in any width assertion, since
    /// the widths would still be correct one frame later.
    ///
    /// Scoped to `Views/ColumnLayout/` on purpose. The rest of `Views/` has
    /// plenty of legitimate animation (a row appearing, a banner sliding in), and
    /// none of it is on the drag's sample rate.
    func test_theLayoutAnimatesNothingWhileDragging() throws {
        let root = ViewSource.url(under: "Views", "MessageSplitLayout")
            .deletingLastPathComponent()
            .appendingPathComponent("ColumnLayout")
        let urls = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil
        )?.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(urls.isEmpty, "no layout sources under \(root.path)")
        for url in urls {
            let code = Self.strippingComments(try String(contentsOf: url, encoding: .utf8))
            for banned in ["withAnimation", ".animation("] {
                XCTAssertFalse(
                    code.contains(banned),
                    "\(url.lastPathComponent) contains \(banned) — a drag must not animate"
                )
            }
        }
    }

    /// Both surfaces are handed the same store, so a surface switch cannot reset
    /// the layout and one drag moves the sidebar too.
    func test_bothSurfacesAreHandedTheSameStore() throws {
        let root = try String(contentsOf: ViewSource.url(under: "Views", "RootView"), encoding: .utf8)
        let code = Self.strippingComments(root)
        // One store on `RootView`; both surfaces receive that instance. A second
        // `ColumnWidthStore()` anywhere would be a second solver, and two solvers
        // is the nested-constraint bug the rewrite removed.
        XCTAssertEqual(
            code.components(separatedBy: "ColumnWidthStore()").count - 1,
            1,
            "RootView must create exactly one ColumnWidthStore"
        )
        XCTAssertEqual(
            code.components(separatedBy: "columnStore: columnStore").count - 1,
            2,
            "both surfaces must be handed RootView's store"
        )
        XCTAssertTrue(
            code.contains("NavigationColumnView(store: columnStore)"),
            "the navigation column must be handed RootView's store"
        )
    }

    /// The store is `@MainActor`, so a stray `Task { }` hop in the drag path
    /// would put a width write off the main thread — where SwiftUI must not be
    /// touched.
    func test_theStoreIsIsolatedToTheMainActor() throws {
        let source = try String(
            contentsOf: ViewSource.url(under: "Views/ColumnLayout", "ColumnWidthStore"),
            encoding: .utf8
        )
        XCTAssertTrue(
            Self.strippingComments(source).contains("@MainActor"),
            "ColumnWidthStore must be @MainActor — SwiftUI updates are main-thread only"
        )
    }

    /// The rubber band's shape and cap, pinned as literals.
    ///
    /// They are the numbers in the spec (`over / (1 + over/150)`, 40pt) and a
    /// "tuning" change to either would be invisible everywhere else.
    func test_theRubberBandNumbersAreTheOnesTheSpecFixes() {
        XCTAssertEqual(ColumnLayoutMetrics.rubberBandScale, 150)
        XCTAssertEqual(ColumnLayoutMetrics.rubberBandCap, 40)
        XCTAssertEqual(ColumnLayoutMetrics.reboundDuration, 0.15)
        XCTAssertEqual(ColumnLayoutMetrics.keyboardStep, 16)
        XCTAssertEqual(ColumnLayoutMetrics.keyboardPageStep, 64)
    }

    /// The curve: the first points track the pointer, then it decays, then it
    /// stops. Asserted at four points rather than as a formula, because those
    /// four are the behaviours a user would describe.
    func test_theRubberBandTracksThenDecaysThenStops() {
        // Inside the range: untouched. The band is a boundary behaviour, not a
        // global handicap on the drag.
        XCTAssertEqual(RubberBand.damped(300, range: 280...460), 300, accuracy: 0.001)
        // 10pt past the wall: 10/(1+10/150) = 9.375 — nearly one-for-one, so the
        // user can still feel that they moved.
        XCTAssertEqual(
            RubberBand.damped(470, range: 280...460), 469.375, accuracy: 0.001
        )
        // 50pt past: 37.5 — decaying, and still under the cap.
        XCTAssertEqual(
            RubberBand.damped(510, range: 280...460), 497.5, accuracy: 0.001
        )
        // 200pt past: the curve would give 85.7, and the cap takes it to 40.
        XCTAssertEqual(RubberBand.damped(660, range: 280...460), 500, accuracy: 0.001)
        // 10 000pt past: still 40. The wall is a wall.
        XCTAssertEqual(RubberBand.damped(10_000, range: 280...460), 500, accuracy: 0.001)
        // The lower wall is the same curve, mirrored.
        XCTAssertEqual(RubberBand.damped(270, range: 280...460), 270.625, accuracy: 0.001)
        XCTAssertEqual(RubberBand.damped(240, range: 280...460), 248.421, accuracy: 0.001)
        XCTAssertEqual(RubberBand.damped(220, range: 280...460), 240, accuracy: 0.001)
    }

    /// Release always lands on a legal width, so `UserDefaults` never receives
    /// an over-limit one.
    func test_releasingAlwaysSettlesOnALegalWidth() {
        for range in [180.0...300.0, 280.0...460.0, 360.0...900.0] {
            for damped in stride(
                from: range.lowerBound - 100,
                through: range.upperBound + 100,
                by: 7.0
            ) {
                let settled = RubberBand.settled(damped: damped, range: range)
                XCTAssertGreaterThanOrEqual(settled, range.lowerBound - 0.001)
                XCTAssertLessThanOrEqual(settled, range.upperBound + 0.001)
            }
        }
    }

    /// A handle names its column; it is never looked up from an index.
    ///
    /// Three columns have **two** boundaries, so a handle's index in its own
    /// container is not its index in the window. Passing the index made a drag of
    /// the list separator resize the sidebar — the pointer moved, every width
    /// still summed to the window, every bound was respected, and the list simply
    /// did not respond while an unrelated column did.
    func test_aHandleResolvesItsColumnByName() throws {
        let region = try String(
            contentsOf: ViewSource.url(under: "Views/ColumnLayout", "ColumnDivider"),
            encoding: .utf8
        )
        let code = Self.strippingComments(region)
        XCTAssertTrue(
            code.contains("let column: LagoonColumn"),
            "a handle must be told which column it moves"
        )
        XCTAssertFalse(
            code.contains("resizedColumn(forHandle:"),
            "the handle must not map an index through the global column set"
        )
        XCTAssertTrue(
            code.contains("store.leadingEdgeX(of: column)"),
            "the drag must read the column's live leading edge — a captured "
            + "origin offsets every drag after the first"
        )
    }

    /// ⌥ inverts the second separator onto the reader, and only that one.
    ///
    /// The compensation for "the reader cannot be widened by dragging its own
    /// edge". Two properties matter and both are asserted: the reader *is*
    /// reachable, and ⌥ on the first separator is not offered — it would target
    /// the list, which is already the column to its left, so a tooltip
    /// advertising it would be a lie.
    func test_theOptionModifierInvertsOnlyTheSecondSeparator() throws {
        let region = try String(
            contentsOf: ViewSource.url(under: "Views/ColumnLayout", "ColumnDivider"),
            encoding: .utf8
        )
        let code = Self.strippingComments(region)
        XCTAssertTrue(
            code.contains("isInverted ? (invertedColumn ?? column) : column"),
            "the drag must select its target column from the ⌥ flag"
        )
        let root = try String(contentsOf: ViewSource.url(under: "Views", "RootView"), encoding: .utf8)
        XCTAssertTrue(
            Self.strippingComments(root).contains("column: .navigation,\n                    invertedColumn: nil"),
            "the first separator cannot invert and must not offer to"
        )
    }

    /// Both handles carry a tooltip naming what a drag does.
    func test_everyHandleCarriesATooltip() throws {
        let region = try String(
            contentsOf: ViewSource.url(under: "Views/ColumnLayout", "ColumnDivider"),
            encoding: .utf8
        )
        XCTAssertTrue(
            Self.strippingComments(region).contains(".help(ColumnWidthStrings.tooltip(for: column))"),
            "every handle must be given a tooltip"
        )
    }

    /// The tooltip exists in both languages, and the first separator's does not
    /// mention a modifier it cannot honour.
    func test_theTooltipIsLocalizedAndHonest() {
        for language in [AppLanguage.zhHans, .english] {
            let l10n = L10n(language: language)
            let plain = l10n.columnResizeTooltip("navigation")
            let invertible = l10n.columnResizeTooltip("list")
            XCTAssertFalse(plain.isEmpty)
            XCTAssertFalse(invertible.isEmpty)
            XCTAssertNotEqual(plain, invertible, "untranslated tooltip for \(language)")
            // The first separator cannot invert, so it must not advertise it.
            XCTAssertFalse(
                plain.contains("⌥"),
                "the first separator's tooltip must not mention ⌥ for \(language)"
            )
            XCTAssertTrue(
                invertible.contains("⌥"),
                "the second separator's tooltip must teach ⌥ for \(language)"
            )
        }
    }

    /// Every column's accessibility name exists in both languages.
    ///
    /// A separator is a 1pt line with no label of its own, so this string is the
    /// only thing that tells VoiceOver what the control adjusts. A missing
    /// translation announces "adjustable" with nothing to adjust.
    func test_everyColumnHasALocalizedAccessibilityName() {
        for language in [AppLanguage.zhHans, .english] {
            let l10n = L10n(language: language)
            for noun in ["navigation", "list", "reader"] {
                XCTAssertFalse(
                    l10n.columnWidthNoun(noun).isEmpty,
                    "missing column name for \(noun) in \(language)"
                )
            }
            XCTAssertFalse(l10n.columnWidthToMin.isEmpty)
            XCTAssertFalse(l10n.columnWidthToMax.isEmpty)
            XCTAssertFalse(l10n.columnWidthPoints(340).isEmpty)
        }
    }

    // MARK: - Helpers

    /// The file's code with `//` and `/* */` comments removed.
    ///
    /// Needed because the layout's comments quote `NavigationSplitView`,
    /// `NSSplitView` and `withAnimation` *while explaining why they must not come
    /// back*. Reading the prose as code would fail every guard above for the
    /// wrong reason.
    ///
    /// The state is `previous: String?` rather than `Character?` because the
    /// two-character delimiter `*/` has to be recognised, and a `Character`
    /// state machine cannot hold half of it across two iterations.
    static func strippingComments(_ source: String) -> String {
        var out = ""
        var inLine = false
        var inBlock = false
        var previous: String = ""
        for ch in source {
            if inLine {
                if ch == "\n" { inLine = false; out.append(ch) }
                previous = String(ch)
                continue
            }
            if inBlock {
                if previous == "*" && ch == "/" { inBlock = false }
                previous = String(ch)
                continue
            }
            if previous == "/" && ch == "/" {
                inLine = true
                previous = ""
                continue
            }
            if previous == "/" && ch == "*" {
                inBlock = true
                previous = ""
                continue
            }
            out.append(ch)
            previous = String(ch)
        }
        return out
    }
}
