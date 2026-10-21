import Foundation
import XCTest
import LagoonKit
@testable import Lagoon

/// P2-12 from the client's side: the panel must never imply it showed
/// everything when it did not.
///
/// ## What was wrong
///
/// The panel loaded once and stopped. `GET /api/actions` answered with at
/// most 100 rows and said nothing about the rest, so a user with 200 actions
/// saw a complete-looking list of 100. The audit's sharper point was that
/// the rows it *did* show and the rows it withheld were the wrong way
/// round: rows are `created_at DESC`, and the oldest are the ones nearest
/// their 30-day undo expiry.
///
/// ## Why these are source-level
///
/// SwiftUI bodies are not runnable in a unit test. The failures being
/// guarded are deleted wiring — a missing `before=`, a footer that renders
/// nothing, a spinner on the wrong state — rather than arithmetic. The
/// arithmetic that *is* testable (the keyset query, the count predicate, the
/// tie at a page boundary) is covered against a real database in
/// `LagoonServerTests/ActionHistoryPagingTests`.
@MainActor
final class ActionHistoryPanelPagingTests: XCTestCase {
    private func sheetSource() throws -> String {
        try ViewSource.read("ActionHistorySheet")
    }

    private func apiExtensionSource() throws -> String {
        try String(
            contentsOf: ViewSource.url(under: "Services", "APIClient+Actions"),
            encoding: .utf8
        )
    }

    // MARK: - The panel asks for a page, not for everything

    /// The panel must use the paged call, and must pass the cursor.
    ///
    /// `fetchActions` (the old call) has no `before` parameter. A panel that
    /// kept calling it could not page at all, and the "load older" button
    /// would have nothing to load.
    func test_thePanelUsesThePagedCallWithACursor() throws {
        let source = try sheetSource()
        XCTAssertTrue(
            source.contains("api.fetchActionPage("),
            "the panel must use the paged call, or it can only ever show the first page"
        )
        XCTAssertTrue(
            source.contains("before: last.id"),
            "the next page must start after the last row the panel holds"
        )
        XCTAssertFalse(
            source.contains("api.fetchActions("),
            "the one-shot call returns no total and cannot page"
        )
    }

    /// The API extension sends `limit` and `before`, and nothing else is
    /// implied. A URL with a missing `before` on page two would re-fetch the
    /// first page forever.
    func test_thePagedCallSendsLimitAndBefore() throws {
        let source = try apiExtensionSource()
        XCTAssertTrue(source.contains("name: \"before\""))
        XCTAssertTrue(source.contains("name: \"limit\""))
        XCTAssertTrue(source.contains("name: \"accountId\""))
    }

    // MARK: - The panel says there is more

    /// The footer must exist, be driven by `hasMore`, and offer the button.
    ///
    /// This is the "a panel that silently stops is indistinguishable from a
    /// broken one" half of the audit item. Without a rendered affordance the
    /// panel is exactly as dishonest as it was before, whatever the server
    /// can now do.
    func test_theFooterOffersOlderRowsWhenThereAreAny() throws {
        let source = try sheetSource()
        XCTAssertTrue(source.contains("if hasMore {"), "the footer must be gated on the server's answer")
        XCTAssertTrue(
            source.contains("l10n.actionHistoryLoadMoreOlder"),
            "a load-more affordance must be rendered, not merely modelled"
        )
        XCTAssertTrue(
            source.contains("l10n.actionHistoryRemaining("),
            "the panel must say how many older rows exist"
        )
    }

    /// The number shown must be "total minus shown", not the page size and
    /// not the total. A footer that said "还有 250 条" over a 100-row list
    /// that the server had already delivered 100 of would overstate the
    /// withheld rows by exactly the page.
    func test_theRemainingCountIsTotalMinusShown() throws {
        let source = try sheetSource()
        XCTAssertTrue(
            source.contains("max(0, totalCount - actions.count)"),
            "the remaining count must be the difference, or the footer overstates what is missing"
        )
    }

    /// A server that does not report `hasMore` must not be read as "there is
    /// nothing else".
    ///
    /// That fallback is the original bug in miniature: an absent field
    /// turned into a claim that the list was complete.
    func test_anAbsentHasMoreDoesNotClaimTheListIsComplete() throws {
        let source = try sheetSource()
        XCTAssertTrue(
            source.contains("hasMore = page.hasMore ?? true"),
            "an older server that cannot answer must leave the button available, not hide it"
        )
    }

    // MARK: - Ordering, surfaced

    /// The panel tells the user that older rows are nearest their expiry.
    ///
    /// The ordering interaction is the audit's own observation: `created_at
    /// DESC` means "load older" means "load the rows about to expire". Not
    /// saying so turns a caveat into a surprise.
    func test_theFooterExplainsThatOlderMeansNearerExpiry() throws {
        let source = try sheetSource()
        XCTAssertTrue(source.contains("l10n.actionHistoryOlderNearExpiry"))
    }

    /// The panel must not shrink its own count after an undo.
    ///
    /// An undo removes one row from the list and the server records an
    /// *undo* row in its place: one out, one in, the history unchanged in
    /// size. So the "还有 N 条" figure stays where it was. A client that
    /// decremented it would be counting a history the server does not have —
    /// the server-side counterpart of this property is pinned by
    /// `ActionHistoryPagingTests.test_anUndoDoesNotChangeTheCount`.
    func test_anUndoDoesNotShrinkThePanelCount() throws {
        let source = try sheetSource()
        XCTAssertFalse(
            source.contains("totalCount = totalCount.map"),
            "an undo replaces a row with an undo row; the count does not shrink"
        )
        XCTAssertFalse(
            source.contains("totalCount - ids.count"),
            "decrementing the count here would make the footer claim fewer older rows than exist"
        )
    }

    // MARK: - Failures are visible

    /// Loading the next page can fail, and when it does the panel must say
    /// so rather than leaving the button looking inert.
    func test_aFailedNextPageSurfacesInsteadOfDoingNothing() throws {
        let source = try sheetSource()
        XCTAssertTrue(
            source.contains("l10n.actionHistoryLoadMoreFailed"),
            "a failed load-more must surface; a button that does nothing reads as broken"
        )
        // And the first page's failure has its own copy — reporting a failed
        // refresh as "couldn't load older entries" points the user at the
        // wrong part of the panel.
        XCTAssertTrue(source.contains("l10n.actionHistoryLoadFailed"))
    }

    // MARK: - Copy

    /// Every new string exists in both languages, and the remaining-count
    /// string carries the number it is about.
    func test_theNewCopyIsTranslatedAndCarriesItsNumber() {
        let zh = L10n(language: .zhHans)
        let en = L10n(language: .english)

        for (zhText, enText) in [
            (zh.actionHistoryRemaining(7), en.actionHistoryRemaining(7)),
            (zh.actionExpired, en.actionExpired),
            (zh.actionHistoryLoadMoreOlder, en.actionHistoryLoadMoreOlder),
            (zh.actionHistoryOlderNearExpiry, en.actionHistoryOlderNearExpiry),
            (zh.actionHistoryLoadFailed, en.actionHistoryLoadFailed),
            (zh.actionHistoryLoadMoreFailed, en.actionHistoryLoadMoreFailed),
            (zh.actionHistoryLoadFailedHint, en.actionHistoryLoadFailedHint),
            (zh.undoNoAccount, en.undoNoAccount),
        ] {
            XCTAssertFalse(zhText.isEmpty)
            XCTAssertFalse(enText.isEmpty)
            XCTAssertNotEqual(zhText, enText, "every string needs both languages")
        }
        XCTAssertTrue(zh.actionHistoryRemaining(7).contains("7"))
        XCTAssertTrue(en.actionHistoryRemaining(7).contains("7"))

        // The load-more control says "older", not "more": the list is
        // newest-first, so the next page is always further back in time.
        XCTAssertTrue(zh.actionHistoryLoadMoreOlder.contains("更早"))
        XCTAssertTrue(en.actionHistoryLoadMoreOlder.lowercased().contains("older"))
    }

    /// The panel must not claim it showed everything.
    ///
    /// This is the audit's sentence, kept as an assertion: the panel is
    /// allowed to be short, but it is never allowed to say it is complete
    /// when the server reported more.
    func test_theFooterIsAbsentOnlyWhenTheServerSaysThereIsNoMore() throws {
        let source = try sheetSource()
        // The footer's only branch is `if hasMore`. A second, unconditional
        // "that is everything" line would contradict it.
        XCTAssertFalse(
            source.contains("actionHistoryComplete"),
            "there is no complete-list claim to make — the panel simply stops offering more"
        )
    }
}
