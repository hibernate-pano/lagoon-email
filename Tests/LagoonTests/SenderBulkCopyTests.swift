import XCTest
import Foundation
@testable import Lagoon
@testable import LagoonKit

/// The sender sheet's bulk verbs are the fastest way to move a lot of mail at
/// once, so their copy carries more risk than usual: a button that reads like
/// it only touches the visible rows while it actually fans out over every
/// unread message from the sender is the exact kind of silent-scope bug this
/// suite keeps finding.
@MainActor
final class SenderBulkCopyTests: XCTestCase {
    private let zh = L10n(language: .zhHans)
    private let en = L10n(language: .english)

    func test_count_isTranslated() {
        XCTAssertNotEqual(zh.senderCount(9), en.senderCount(9))
        XCTAssertEqual(zh.senderCount(9), "9 封邮件")
        XCTAssertEqual(en.senderCount(9), "9 messages")
    }

    /// Both verbs name the scope in their confirmation copy. "全部" is the
    /// load-bearing word: the fan-out is over every unread mail from the
    /// sender, which can be far more than the 200 rows the sheet lists.
    func test_confirmCopy_statesTheScope() {
        for text in [zh.senderAllReadConfirm, zh.senderAllArchiveConfirm] {
            XCTAssertTrue(text.contains("所有未读邮件"), "zh confirmation must name the scope: \(text)")
        }
        for text in [en.senderAllReadConfirm, en.senderAllArchiveConfirm] {
            XCTAssertTrue(
                text.lowercased().contains("all unread"),
                "en confirmation must name the scope: \(text)"
            )
        }
    }

    /// The archive confirmation must say the action is undoable — that is the
    /// difference between a scary bulk verb and a routine one, and undo is a
    /// real guarantee the archive route ships (per-message audit rows).
    func test_archiveConfirm_mentionsUndo() {
        XCTAssertTrue(zh.senderAllArchiveConfirm.contains("撤销"))
        XCTAssertTrue(en.senderAllArchiveConfirm.lowercased().contains("undo"))
        // ...and the read confirmation must NOT promise what markRead never
        // offered: it records audit rows too, but read/unread undo is a
        // different toast; the copy stays neutral rather than over-promising.
        XCTAssertFalse(zh.senderAllReadConfirm.contains("撤销"))
    }

    func test_done_toasts_carryTheCount() {
        XCTAssertEqual(zh.senderAllReadDone(17), "已标记 17 封为已读")
        XCTAssertEqual(en.senderAllReadDone(17), "Marked 17 messages as read")
        XCTAssertEqual(zh.senderAllArchiveDone(9), "已归档 9 封")
        XCTAssertEqual(en.senderAllArchiveDone(9), "Archived 9 messages")
    }

    /// Verb labels are short and imperative: they sit in a toolbar-sized row.
    func test_verbLabels_existInBothLanguages() {
        for (zhV, enV) in [(zh.senderAllRead, en.senderAllRead),
                           (zh.senderAllArchive, en.senderAllArchive)] {
            XCTAssertFalse(zhV.isEmpty)
            XCTAssertFalse(enV.isEmpty)
            XCTAssertNotEqual(zhV, enV, "untranslated verb label")
        }
    }
}
