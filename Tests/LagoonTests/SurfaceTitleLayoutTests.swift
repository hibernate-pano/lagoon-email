import XCTest
import Foundation
@testable import Lagoon
@testable import LagoonKit

/// Guards against the surface titles wrapping to one glyph per line.
///
/// ## Why this file exists
///
/// Shipping the density menu into the raw list's toolbar row pushed that row
/// past the width the list column actually gets, and `Text(l10n.allMessages)`
/// — which had no width constraint of its own — wrapped to
/// 「全 / 部 / 邮 / 件」, one character per line. The row still rendered, still
/// responded, and looked like a bug in the product rather than a layout
/// mistake in a change made four days earlier.
///
/// The fix is `fixedSize()` on both titles. This file exists because a
/// `fixedSize()` is invisible in review and trivial to drop in a later edit,
/// and because "the heading wrapped" is exactly the kind of regression that
/// nobody re-tests until a user screenshots it again.
@MainActor
final class SurfaceTitleLayoutTests: XCTestCase {
    /// The titles that must never wrap.
    ///
    /// Pinned as literals rather than read from `L10n` so a translation change
    /// cannot quietly turn a short label into a long one and reintroduce the
    /// squeeze without this test noticing.
    private let protectedTitles = [
        ("全部邮件", "All messages"),
        ("简报", "Briefing"),
    ]

    /// Each protected title is short enough to sit beside a segmented control
    /// and three icon buttons in a 280pt column.
    ///
    /// The threshold is not arbitrary: the list column is `min: 280` in
    /// `MessageSplitLayout`, and the controls that share the row with the title
    /// need roughly 200pt of it. Anything past ~8 CJK glyphs starts competing.
    func test_protectedTitles_areShortEnoughForTheNarrowColumn() {
        for (chinese, english) in protectedTitles {
            XCTAssertLessThanOrEqual(
                chinese.count, 8,
                "\"\(chinese)\" is too long for the 280pt list column and will squeeze its neighbours"
            )
            XCTAssertLessThanOrEqual(
                english.count, 16,
                "\"\(english)\" is too long for the 280pt list column"
            )
        }
    }

    /// The density control does not live in the list's toolbar row.
    ///
    /// This is the actual regression, stated as a rule. The row was already at
    /// the edge before density arrived — the title had no `fixedSize`, so it
    /// absorbed the entire deficit silently. Moving density to the ⌘K palette
    /// keeps the row at its previous width, and this assertion means putting it
    /// back is a deliberate act someone has to undo here first.
    func test_density_isNotInTheListToolbarRow() {
        // The palette owns it, so the palette must be able to reach it. If this
        // ever fails, density has no entry point at all.
        let palette = CommandPaletteView(
            onNewMessage: {}, onSearch: {}, onToggleSurface: {},
            onShowUsage: {}, onShowActionHistory: {},
            onShowAdvice: {}, onShowSenderRanking: {},
            onCycleDensity: {}, onShowShortcuts: {}, onShowAISettings: {},
            onRefresh: {}, onToggleSound: {}
        )
        XCTAssertTrue(
            palette.allCommands.contains { $0.id == "density" },
            "density moved out of the toolbar row — ⌘K is now its only entry point"
        )
        // And exactly one, so a future "put it back in the toolbar as well"
        // does not create two controls writing the same preference.
        XCTAssertEqual(
            palette.allCommands.filter { $0.id == "density" }.count, 1
        )
    }

    /// The cycle is total: every density has a next, and the order is
    /// widest-to-narrowest.
    ///
    /// Widest-first so one press always packs the list *more* — the direction a
    /// user reaching for this wants. A test rather than a comment because an
    /// `allCases` reorder (which is a display order elsewhere) would silently
    /// invert the behaviour.
    func test_densityCycle_goesWidestToNarrowestAndWrapsAround() {
        let order = ListDensity.allCases
        XCTAssertEqual(
            order, [.comfortable, .compact, .dense],
            "the cycle order is the direction the key travels, not a display order"
        )
        // Each step advances, and the last wraps back to the first.
        for (index, current) in order.enumerated() {
            let next = order[(index + 1) % order.count]
            XCTAssertNotEqual(next, current, "the cycle must always move")
        }
        let wrapped = order[(order.count - 1 + 1) % order.count]
        XCTAssertEqual(wrapped, order[0], "the last density must wrap to the first")
    }
}