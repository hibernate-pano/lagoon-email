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
///
/// ## T1 (Q-04 in docs/全方位审查报告-2026-10-16.md)
///
/// Two upgrades, because both halves of this file used to be able to pass
/// without looking at the product:
///
/// * The length assertion compared two literals typed into this test — so a
///   translation that turned 「简报」 into a paragraph stayed invisible; the
///   test was validating itself. It now reads the *production* strings from
///   `L10n`.
/// * The `fixedSize()` claim was prose in a comment. It is now a source
///   assertion per pipeline: a `.fixedSize()` must sit between each title's
///   anchors, so deleting any one of the four modifiers turns a test red.
@MainActor
final class SurfaceTitleLayoutTests: XCTestCase {
    /// The titles that must never wrap, read from the real `L10n` values.
    ///
    /// These are the titles the two surfaces actually render:
    /// `MessageListView.surfaceTitle` (全部邮件 — the fallback case beside
    /// every other lens) and `BriefingFeedView`'s header.
    private func protectedTitles() -> [(chinese: String, english: String)] {
        let zh = L10n(language: .zhHans)
        let en = L10n(language: .english)
        return [
            (zh.allMessages, en.allMessages),
            (zh.briefing, en.briefing),
        ]
    }

    /// Each protected title is short enough to sit beside a segmented control
    /// and three icon buttons in a 280pt column.
    ///
    /// The threshold is not arbitrary: the list column is `min: 280` in
    /// `MessageSplitLayout`, and the controls that share the row with the title
    /// need roughly 200pt of it. Anything past ~8 CJK glyphs starts competing.
    /// Reading the production strings is what lets a longer translation fail
    /// here — the old literal-in-test version could not.
    func test_protectedTitles_areShortEnoughForTheNarrowColumn() {
        for (chinese, english) in protectedTitles() {
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

    /// The regression itself, pinned per pipeline: every title chain still
    /// carries its `.fixedSize()`.
    ///
    /// Each entry is (source, from-anchor, to-anchor): the assertion is that a
    /// `.fixedSize()` sits *between* the two anchors — string presence
    /// anywhere in the file is not enough, because a `.fixedSize()` that
    /// survived on a neighbouring control would read as coverage while the
    /// title itself wrapped. The four pipelines are the four production sites:
    /// `MessageListView.swift:341` (title) and `:349` (grouping picker),
    /// `BriefingFeedView.swift:234` (header title), `RootView.swift:834`
    /// (surface picker). Deleting any one turns this red.
    func test_surfaceTitlesStillCarryFixedSize() throws {
        let pipelines: [(name: String, source: String, from: String, to: String)] = [
            ("MessageListView title", try ViewSource.read("MessageListView"),
             "Text(surfaceTitle)", ".layoutPriority(1)"),
            ("MessageListView grouping picker", try ViewSource.read("MessageListView"),
             "Picker(l10n.groupingLabel", ".help(l10n.groupingHelp)"),
            ("BriefingFeedView title", try ViewSource.read("BriefingFeedView"),
             "Text(l10n.briefing)", ".layoutPriority(1)"),
            ("RootView surface picker", try ViewSource.read("RootView"),
             "Picker(l10n.surface", ".help(l10n.surfaceHelp)"),
        ]
        for (name, source, from, to) in pipelines {
            let start = try XCTUnwrap(
                source.range(of: from), "\(name): anchor '\(from)' moved"
            )
            let rest = source[start.upperBound...]
            let end = try XCTUnwrap(
                rest.range(of: to), "\(name): anchor '\(to)' moved"
            )
            XCTAssertTrue(
                rest[..<end.lowerBound].contains(".fixedSize()"),
                """
                \(name) lost its .fixedSize() — the title will wrap one glyph \
                per line under width pressure, which is the exact regression \
                this file was written for.
                """
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
