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

    /// The read confirmation names the unread scope; the archive confirmation
    /// names the whole-sender scope. They differ on purpose: mark-read only
    /// means anything for unread mail, while archive must survive "mark all
    /// read, then archive all" — the flow whose first half used to hide the
    /// second half's button.
    func test_confirmCopy_statesTheScope() {
        XCTAssertTrue(zh.senderAllReadConfirm.contains("所有未读邮件"))
        XCTAssertTrue(en.senderAllReadConfirm.lowercased().contains("all unread"))
        // Archive covers everything from this sender — unread or not.
        XCTAssertTrue(zh.senderAllArchiveConfirm.contains("所有邮件"))
        XCTAssertTrue(en.senderAllArchiveConfirm.lowercased().contains("all mail"))
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

    /// The emptied sheet must name the action, not read as "there was never
    /// anything here". The title carries the count; the detail names the undo
    /// window; both languages agree.
    func test_emptiedState_copyNamesTheActionAndUndo() {
        for count in [0, 1, 23] {
            XCTAssertTrue(
                zh.senderAllArchivedEmptyTitle(count).contains("\(count)"),
                "zh title must carry the count: \(zh.senderAllArchivedEmptyTitle(count))"
            )
            XCTAssertTrue(
                en.senderAllArchivedEmptyTitle(count).contains("\(count)"),
                "en title must carry the count: \(en.senderAllArchivedEmptyTitle(count))"
            )
        }
        XCTAssertTrue(zh.senderAllArchivedEmptyTitle(9).contains("已归档"))
        XCTAssertTrue(en.senderAllArchivedEmptyTitle(9).lowercased().contains("archived"))
        for text in [zh.senderAllArchivedEmptyDetail, en.senderAllArchivedEmptyDetail] {
            XCTAssertTrue(
                text.lowercased().contains("30"),
                "the undo window is the concrete promise: \(text)"
            )
        }
    }

    /// The delete confirmation is the highest-stakes copy in the sheet: it
    /// must carry the exact count (blast radius) and the honest destination
    /// ("废纸篓"/Trash — delete means recoverable, not annihilation).
    func test_deleteConfirm_carriesCountAndTrashDestination() {
        let zhText = zh.senderAllDeleteConfirm(9)
        let enText = en.senderAllDeleteConfirm(9)
        XCTAssertTrue(zhText.contains("9"), "count must be visible: \(zhText)")
        XCTAssertTrue(zhText.contains("废纸篓"), "the destination must be Trash: \(zhText)")
        XCTAssertTrue(zhText.contains("撤销"))
        XCTAssertTrue(enText.contains("9"))
        XCTAssertTrue(enText.lowercased().contains("trash"))
        XCTAssertTrue(enText.lowercased().contains("undo"))
    }

    func test_deleteVerbLabels_existInBothLanguages() {
        XCTAssertEqual(zh.senderAllDelete, "全部删除")
        XCTAssertEqual(en.senderAllDelete, "Delete all")
        XCTAssertEqual(zh.senderAllDeleteDone(5), "已删除 5 封")
        XCTAssertEqual(en.senderAllDeleteDone(5), "Deleted 5 messages")
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
