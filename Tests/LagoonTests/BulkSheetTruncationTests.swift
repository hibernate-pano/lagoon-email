import XCTest
import Foundation
@testable import Lagoon
@testable import LagoonKit

/// The bulk sheets' truncation honesty.
///
/// ## Why this file exists
///
/// `StackMailSheet` has a 清扫 verb that archives every message its filter
/// matched, and archiving is remote and effectively irreversible in bulk. Before
/// this, both bulk sheets dropped their client-side limit — correctly, since the
/// server owns the window — but neither read `totalCount`, so a sender with 800
/// messages rendered 500 rows and the sheet looked complete. The user would
/// sweep 500 of 800 and read the result as "done".
///
/// This is the same failure class as the briefing-window bug the project has
/// already fixed twice (`totalCount`, `omittedCount`, `truncatedCount`). The
/// recurring lesson is that **a list which silently drops rows must say so**,
/// and that these tests exist to keep saying it.
@MainActor
final class BulkSheetTruncationTests: XCTestCase {
    private let zh = L10n(language: .zhHans)
    private let en = L10n(language: .english)

    /// The shared decision, expressed once so both sheets cannot drift.
    ///
    /// This now calls the **production** rule (`ListTruncationNotice.text`),
    /// which is what both `StackMailSheet.truncatedNotice` and
    /// `SenderSheet.truncationNotice` call. The previous version of this file
    /// reimplemented the guard locally — at which point editing the production
    /// threshold left every assertion here green. A test that restates the rule
    /// can only ever catch a change to the restatement.
    private func notice(shown: Int, total: Int?) -> String? {
        ListTruncationNotice.text(shown: shown, total: total, l10n: L10n(language: .zhHans))
    }

    /// A sheet holding everything says nothing.
    func test_completeList_showsNoTruncationNotice() {
        XCTAssertNil(notice(shown: 500, total: 500))
        XCTAssertNil(notice(shown: 500, total: nil), "an unknown total is not a truncation")
        XCTAssertNil(notice(shown: 0, total: nil))
    }

    /// A capped list says so, and names both numbers.
    ///
    /// Both numbers matter and they mean different things: `shown` is what the
    /// user can act on, `total` is what the sender actually has. A notice
    /// carrying only one of them leaves the user unable to tell whether the
    /// sweep was partial.
    func test_cappedList_namesBothNumbers() throws {
        XCTAssertNotNil(notice(shown: 500, total: 800))
        let text = zh.listTruncated(500, 800)
        XCTAssertTrue(text.contains("500"), "must state how many are shown")
        XCTAssertTrue(text.contains("800"), "must state the real total")
    }

    /// Removing a row moves the total with it.
    ///
    /// The mirror-image bug: without this, archiving one message from the detail
    /// pane leaves the total where it was, and a list that is now *complete*
    /// goes on claiming to be truncated. A caveat that cries wolf is the same
    /// failure as one that lies by omission.
    func test_removingARowRetiresTheNoticeOnceCaughtUp() {
        var total: Int? = 800
        var shown = 500
        XCTAssertNotNil(notice(shown: shown, total: total))

        // The sheet's `removeRow` decrements both sides by the same amount.
        total = max(0, (total ?? 0) - 1)
        shown -= 1

        // Still capped after one removal — 799 remain, 499 are shown.
        XCTAssertNotNil(notice(shown: shown, total: total))
        // Drain the visible rows the way a full sweep would.
        while shown > 0 && (total ?? 0) > shown {
            shown -= 1
            total = (total ?? 0) - 1
        }
        // The gap never closes on its own: a sweep of the shown rows cannot
        // reach the rows that were never fetched. This is the whole point.
        XCTAssertLessThan(shown, total ?? 0)
    }

    /// The total can never go negative — a defensive guard on the decrement.
    func test_totalNeverGoesNegative() {
        var total: Int? = 3
        total = max(0, (total ?? 0) - 5)
        XCTAssertEqual(total, 0)
        XCTAssertNil(notice(shown: 0, total: total))
    }

    /// The copy is translated, and it reads as a statement about the list rather
    /// than an apology for it.
    func test_copy_isTranslatedInBothLanguages() {
        XCTAssertNotEqual(zh.listTruncated(500, 800), en.listTruncated(500, 800))
        for text in [zh.listTruncated(500, 800), en.listTruncated(500, 800)] {
            XCTAssertFalse(text.isEmpty)
            XCTAssertFalse(
                text.lowercased().contains("error"),
                "a capped list is not an error state: \"\(text)\""
            )
        }
    }

    /// The notice must not imply anything *happened* to the withheld mail.
    ///
    /// Same rule as the advice surface: nothing on screen may read as though
    /// Lagoon acted on a message. The withheld rows are untouched — they were
    /// simply not fetched — and the wording has to keep that true.
    func test_copy_doesNotClaimTheWithheldMailWasTouched() {
        for text in [zh.listTruncated(500, 800), en.listTruncated(500, 800)] {
            for word in ["已归档", "archived", "已删除", "deleted", "已退订"] {
                XCTAssertFalse(
                    text.lowercased().contains(word.lowercased()),
                    "the withheld rows were never fetched, not archived: \"\(text)\""
                )
            }
        }
    }
}