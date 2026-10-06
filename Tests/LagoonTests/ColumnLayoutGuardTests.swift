import XCTest
@testable import Lagoon

/// Structural guards for the three-column layout.
///
/// ## Why these read source instead of calling code
///
/// The invariant they protect is an **absence**: there must be no
/// `NavigationSplitView` in the layout, because that is the thing that injects
/// an automatic sidebar toggle into the *window* toolbar, and `RootView` keeps
/// both mail surfaces alive in a ZStack — so two surfaces would each produce
/// one and the user would see the toggle twice
/// (`.memory/toolbar-items-escape-hidden-zstack-surfaces`).
///
/// The old guard was `.toolbar(removing: .sidebarToggle)`, declared in
/// `MessageSplitLayout` so a third surface could not forget it. That guard died
/// with the split views it guarded: there is nothing left to remove, because
/// nothing injects the toggle any more.
///
/// A behavioural test cannot catch this. Re-adding `NavigationSplitView` would
/// compile, every width would still solve correctly, every drag would still
/// work — and the window would show a duplicate toggle. So the only thing that
/// fails is a test that reads the source, which is what this is.
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

    /// Every Swift file under `Sources/Lagoon/Views`, paired with its code.
    private func clientSources() throws -> [(name: String, text: String)] {
        let root = ViewSource.url(under: "Views", "RootView")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let urls = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil
        )?.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(urls.isEmpty, "no client sources found under \(root.path)")
        return try urls.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    /// No split view anywhere in the layout. See the type comment.
    func test_theLayoutContainsNoNavigationSplitView() throws {
        for (name, text) in try layoutSources() {
            // Comments are excluded deliberately: several of them *name*
            // `NavigationSplitView` while explaining why it must not come back,
            // and a test that read the prose would fail for the wrong reason —
            // or worse, pass if someone deleted the warning.
            let code = Self.strippingComments(text)
            XCTAssertFalse(
                code.contains("NavigationSplitView"),
                """
                \(name) uses NavigationSplitView.

                That re-introduces the automatic sidebar toggle, which the window
                toolbar shows once per keep-alive surface. The layout replaces it
                with ColumnRegionView; see MessageSplitLayout's doc comment and
                .memory/toolbar-items-escape-hidden-zstack-surfaces.
                """
            )
        }
    }

    /// The same guard, wider: nothing under `Sources/` may reintroduce one
    /// without the layout being rebuilt around it.
    func test_noClientSourceUsesNavigationSplitView() throws {
        var offenders: [String] = []
        for (name, text) in try clientSources() where Self.strippingComments(text)
            .contains("NavigationSplitView") {
            offenders.append(name)
        }
        XCTAssertTrue(
            offenders.isEmpty,
            "NavigationSplitView reappeared in: \(offenders.joined(separator: ", "))"
        )
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
    /// none of it is on the drag's sample rate — the drag never re-renders
    /// SwiftUI at all, which is the point of `ColumnLayoutStore`'s two tiers.
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

    /// The drag does not re-render SwiftUI: only the *settled* tier publishes.
    ///
    /// The performance argument, stated as an assertion. If a future change made
    /// `widths` a `@Published` property, every pointer sample would schedule a
    /// SwiftUI transaction over the whole tree — reader, sidebar and a list of
    /// thousands of rows — at 120Hz. Nothing about that would fail a width test.
    func test_onlyTheSettledTierPublishes() throws {
        let source = try String(
            contentsOf: ViewSource.url(under: "Views/ColumnLayout", "ColumnLayoutStore"),
            encoding: .utf8
        )
        let code = Self.strippingComments(source)
        XCTAssertTrue(
            code.contains("@Published private(set) var settledWidths"),
            "the published tier must be `settledWidths`"
        )
        // The live tier must be a plain property.
        XCTAssertFalse(
            code.contains("@Published private(set) var widths:"),
            "`widths` must not publish — a drag writes it on every pointer sample"
        )
        XCTAssertTrue(
            code.contains("private(set) var widths:"),
            "`widths` must exist as the non-publishing live tier"
        )
    }

    /// Frame writes are wrapped in a non-animating context.
    ///
    /// The positive counterpart to the test above: `NSView` is an
    /// `NSAnimatablePropertyContainer`, so a frame set inside *any* animation
    /// context interpolates. The one place frames are written must therefore
    /// disable implicit animation, and this asserts it is still there — a
    /// refactor that drops the wrapper compiles and passes every width test.
    func test_frameWritesDisableImplicitAnimation() throws {
        let region = try String(
            contentsOf: ViewSource.url(under: "Views/ColumnLayout", "ColumnRegionView"),
            encoding: .utf8
        )
        let code = Self.strippingComments(region)
        XCTAssertTrue(
            code.contains("allowsImplicitAnimation = false"),
            "ColumnRegionView must disable implicit animation around its frame writes"
        )
        XCTAssertTrue(
            code.contains("context.duration = 0"),
            "ColumnRegionView must use a zero-duration animation context"
        )
    }

    /// The two regions share one store, so a surface switch cannot reset the
    /// layout and one drag moves the sidebar too.
    func test_bothRegionsAreHandedTheSameStore() throws {
        let root = try String(contentsOf: ViewSource.url(under: "Views", "RootView"), encoding: .utf8)
        let code = Self.strippingComments(root)
        // The store is a single `@StateObject` on RootView, and both the
        // navigation column and the keep-alive surfaces receive that instance.
        // A second `ColumnLayoutStore()` anywhere would be a second solver, and
        // two solvers is the nested-constraint bug the rewrite removed.
        XCTAssertEqual(
            code.components(separatedBy: "ColumnLayoutStore()").count - 1,
            1,
            "RootView must create exactly one ColumnLayoutStore"
        )
        XCTAssertTrue(
            code.contains("NavigationColumnView(store: columnStore)"),
            "the navigation column must be handed RootView's store"
        )
        XCTAssertTrue(
            code.contains("columnStore: columnStore"),
            "the keep-alive surfaces must be handed RootView's store"
        )
    }

    /// The store is `@MainActor` and the geometry is AppKit's, so a stray
    /// `Task { }` hop in the drag path would put a frame write off the main
    /// thread — where AppKit does not allow it.
    func test_theStoreIsIsolatedToTheMainActor() throws {
        let source = try String(
            contentsOf: ViewSource.url(under: "Views/ColumnLayout", "ColumnLayoutStore"),
            encoding: .utf8
        )
        let code = Self.strippingComments(source)
        XCTAssertTrue(
            code.contains("@MainActor"),
            "ColumnLayoutStore must be @MainActor — AppKit frame writes are main-thread only"
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
        // 10pt past the wall: 10/(1+10/150) = 9.375 — nearly one-for-one, so
        // the user can still feel that they moved.
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
        // The lower wall is the same curve, mirrored: 10pt under the floor
        // gives back 9.375, and 40pt under gives back 31.578
        // (40/(1+40/150)) — the cap is on the *travel*, not on the overshoot, so
        // the band is still moving at 40pt out.
        XCTAssertEqual(RubberBand.damped(270, range: 280...460), 270.625, accuracy: 0.001)
        XCTAssertEqual(RubberBand.damped(240, range: 280...460), 248.421, accuracy: 0.001)
        // 60pt under: the curve would give 42.9, capped at 40.
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
    /// This is the regression guard for a bug that shipped in the first version
    /// of the drag path and that **no width invariant could have caught**. The
    /// three columns are hosted by two regions, so the surface region's only
    /// divider is the *global* boundary 1 while its own index is 0. Passing the
    /// index to the store made a drag of the **list** separator resolve to the
    /// **sidebar** — the pointer moved, the widths still summed to the window,
    /// every bound was respected, and the list column simply did not respond
    /// while an unrelated column did.
    ///
    /// So the guard is on the *absence of the mechanism*, not on the arithmetic.
    func test_aHandleResolvesItsColumnByNameNotByIndex() throws {
        let store = try String(
            contentsOf: ViewSource.url(under: "Views/ColumnLayout", "ColumnLayoutStore"),
            encoding: .utf8
        )
        let code = Self.strippingComments(store)
        XCTAssertTrue(
            code.contains("func drag(column: LagoonColumn"),
            "the store must take the column by name"
        )
        XCTAssertFalse(
            code.contains("func drag(handle:"),
            "the store must not resolve a column from a handle index — the two "
            + "regions number their dividers differently"
        )
        XCTAssertFalse(
            code.contains("func endDrag(handle:"),
            "same for endDrag: it must settle the column the pointer was moving"
        )
    }

    /// The region computes each handle's column from its own hosted set.
    func test_theRegionNamesEachHandleFromItsOwnColumns() throws {
        let region = try String(
            contentsOf: ViewSource.url(under: "Views/ColumnLayout", "ColumnRegionView"),
            encoding: .utf8
        )
        let code = Self.strippingComments(region)
        XCTAssertTrue(
            code.contains("let left = hostedColumns[index - 1]"),
            "a handle's column must come from the region's own columns"
        )
        XCTAssertFalse(
            code.contains("resizedColumn(forHandle:"),
            "the region must not map a handle index through the global column set"
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
            contentsOf: ViewSource.url(under: "Views/ColumnLayout", "ColumnRegionView"),
            encoding: .utf8
        )
        let code = Self.strippingComments(region)
        XCTAssertTrue(
            code.contains("guard column == .list, store.columns.contains(.reader)"),
            "the inverted target must be the reader, on the list boundary only"
        )
        XCTAssertTrue(
            code.contains("isInverted ? (invertedColumn ?? column) : column"),
            "the drag must select its target column from the ⌥ flag"
        )
    }

    /// The ⌥ flag is read per sample, not latched at mouse-down.
    ///
    /// A user who starts dragging, realises they grabbed the wrong separator and
    /// holds ⌥ should not have to let go and start again. Latching the modifier
    /// at mouse-down would make the feature work only if the user guessed right
    /// the first time.
    func test_theModifierIsReadOnEveryDragSample() throws {
        let divider = try String(
            contentsOf: ViewSource.url(under: "Views/ColumnLayout", "ColumnDividerView"),
            encoding: .utf8
        )
        let code = Self.strippingComments(divider)
        let occurrences = code.components(separatedBy: "modifierFlags.contains(.option)").count - 1
        XCTAssertGreaterThanOrEqual(
            occurrences, 2,
            "the ⌥ flag must be read on mouse-down AND on every drag sample"
        )
    }

    /// Both handles carry a tooltip naming what a drag does.
    func test_everyHandleCarriesATooltip() throws {
        let region = try String(
            contentsOf: ViewSource.url(under: "Views/ColumnLayout", "ColumnRegionView"),
            encoding: .utf8
        )
        let code = Self.strippingComments(region)
        XCTAssertTrue(
            code.contains("handle.helpText = ColumnWidthFormatter.tooltip(for: column)"),
            "every handle must be given a tooltip"
        )
        let divider = try String(
            contentsOf: ViewSource.url(under: "Views/ColumnLayout", "ColumnDividerView"),
            encoding: .utf8
        )
        XCTAssertTrue(
            Self.strippingComments(divider).contains("var helpText: String"),
            "the handle must expose the tooltip through NSView.toolTip"
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

    // MARK: - Helpers

    /// The file's code with `//` and `/* */` comments removed.
    ///
    /// Needed because the layout's comments quote `NavigationSplitView`,
    /// `withAnimation` and `NavigationSplitViewColumnWidth` *while explaining
    /// why they must not come back*. Reading the prose as code would fail every
    /// guard above for the wrong reason.
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
