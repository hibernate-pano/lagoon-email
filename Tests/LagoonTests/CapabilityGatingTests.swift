import XCTest
import SwiftUI
import LagoonKit
@testable import Lagoon

/// P2-10: the client learned that a server could not do something only by
/// clicking it and getting a 409.
///
/// ## The shape of the fix
///
/// `MailCapabilities` now carries the three role answers the server already
/// knew but never published: `uidplus`, `sentFolder`, `trashFolder`. The
/// client reads them and turns the verb off *before* the click, with a
/// tooltip that says why.
///
/// ## Why these are source-level guards
///
/// A SwiftUI view's disabled state is not reachable from a unit test without
/// a running app and a live account. What *is* checkable — and what
/// actually broke — is the wiring: which verb is gated on which
/// capability, and whether the gate is reachable at all. A verb that is
/// offered but gated on the wrong capability is exactly the bug this item
/// is about, and a behavioural test could not tell the difference between
/// "gated on the trash folder" and "gated on UIDPLUS".
final class CapabilityGatingTests: XCTestCase {
    private func listSource() throws -> String { try ViewSource.read("MessageListView") }
    private func detailSource() throws -> String { try ViewSource.read("MessageDetailView") }
    private func feedSource() throws -> String { try ViewSource.read("BriefingFeedView") }
    private func bulkBarSource() throws -> String { try ViewSource.read("BulkActionBar") }

    // MARK: - The gates exist and read the right capability

    /// The list must gate delete on the **trash folder**, not on something
    /// else.
    ///
    /// Delete moves mail to the server's trash. UIDPLUS is about *permanent*
    /// delete, which is a different verb with a different precondition.
    /// Swapping the two would disable delete on a server that can do it, or
    /// offer 彻底删除 on a server that cannot.
    func test_theListGatesDeleteOnTheTrashFolder() throws {
        let source = try listSource()
        let gate = try XCTUnwrap(
            source.range(of: "private var canDelete: Bool"),
            "the list must have a delete gate"
        )
        let body = ViewSource.code(after: gate.lowerBound, in: source, limit: 300)
        XCTAssertTrue(
            body.contains("allowsDelete"),
            "the delete gate must read the trash-folder capability"
        )
        XCTAssertFalse(
            body.contains("allowsPurge"),
            "the delete gate must not read the UIDPLUS capability — that is 彻底删除's precondition"
        )
    }

    /// 彻底删除 must be gated on UIDPLUS.
    ///
    /// A permanent delete is `UID EXPUNGE` on exactly one message. Without
    /// UIDPLUS the server refuses rather than expunge another client's
    /// pending deletions, so the verb must not be offered.
    func test_theListGatesPurgeOnUIDPlus() throws {
        let source = try listSource()
        let gate = try XCTUnwrap(
            source.range(of: "private var canPurge: Bool"),
            "the list must have a purge gate"
        )
        let body = ViewSource.code(after: gate.lowerBound, in: source, limit: 300)
        XCTAssertTrue(
            body.contains("allowsPurge"),
            "the purge gate must read the UIDPLUS capability"
        )
    }

    /// The detail view must gate its delete verb the same way.
    ///
    /// The detail view is the *primary* surface — the one the user opens a
    /// message in. A gate that exists only in the list would leave the
    /// most-used surface still answering 409.
    func test_theDetailViewGatesDeleteOnTheTrashFolder() throws {
        let source = try detailSource()
        let gate = try XCTUnwrap(
            source.range(of: "private var canDelete: Bool"),
            "the detail view must have a delete gate"
        )
        let body = ViewSource.code(after: gate.lowerBound, in: source, limit: 300)
        XCTAssertTrue(
            body.contains("allowsDelete"),
            "the detail view's delete gate must read the trash-folder capability"
        )
    }

    /// The briefing feed must gate delete the same way.
    ///
    /// It is the app's *default* surface, so an ungated delete there is the
    /// first thing a user would hit.
    func test_theBriefingFeedGatesDeleteOnTheTrashFolder() throws {
        let source = try feedSource()
        let gate = try XCTUnwrap(
            source.range(of: "private var canDelete: Bool"),
            "the briefing feed must have a delete gate"
        )
        let body = ViewSource.code(after: gate.lowerBound, in: source, limit: 300)
        XCTAssertTrue(
            body.contains("allowsDelete"),
            "the feed's delete gate must read the trash-folder capability"
        )
    }

    // MARK: - The gates are actually applied

    /// The row context menu must disable its delete and purge items.
    ///
    /// The context menu is where the verbs live for a keyboard-first user,
    /// and it is the one place the "照做" of the whole item: the user must
    /// not be able to pick a verb the server will refuse.
    func test_theRowMenuDisablesDeleteAndPurge() throws {
        let source = try listSource()
        let chrome = try XCTUnwrap(
            source.range(of: "private struct RowChrome"),
            "the row chrome must exist"
        )
        let body = ViewSource.code(after: chrome.lowerBound, in: source, limit: 6000)

        XCTAssertTrue(
            body.contains(".disabled(!canDelete)"),
            "the row menu's delete item must be gated on the trash folder"
        )
        XCTAssertTrue(
            body.contains(".disabled(!canPurge)"),
            "the row menu's 彻底删除 item must be gated on UIDPLUS"
        )
        // And each gate must carry an explanation: a disabled button with
        // no reason is a broken-looking button.
        XCTAssertTrue(
            body.contains("l10n.deleteUnavailable"),
            "the disabled delete must say why it is disabled"
        )
        XCTAssertTrue(
            body.contains("l10n.purgeUnavailable"),
            "the disabled 彻底删除 must say why it is disabled"
        )
    }

    /// The bulk bar must disable its delete item.
    ///
    /// The bar is the *bulk* path: a user who selected 50 mails and pressed
    /// 移到废纸篓 would get 50 failed requests and 50 error banners.
    func test_theBulkBarDisablesDelete() throws {
        let source = try bulkBarSource()
        let delete = try XCTUnwrap(
            source.range(of: "Button(role: .destructive, action: onDelete)"),
            "the bulk bar must have a delete button"
        )
        let body = ViewSource.code(after: delete.lowerBound, in: source, limit: 400)
        XCTAssertTrue(
            body.contains(".disabled(!canDelete)"),
            "the bulk delete must be gated on the trash folder"
        )
        XCTAssertTrue(
            body.contains("l10n.deleteUnavailable"),
            "the disabled bulk delete must say why it is disabled"
        )
    }

    /// The keyboard shortcut must be gated too.
    ///
    /// ⌘⌫ is a verb. A shortcut that fires a request the server will refuse
    /// is the same "点了才知道不行" the item is about — and worse, because
    /// there is no button on screen to have looked disabled.
    func test_theKeyboardShortcutIsGatedAsWell() throws {
        for (name, source) in [
            ("MessageListView", try listSource()),
            ("BriefingFeedView", try feedSource()),
        ] {
            let shortcut = try XCTUnwrap(
                source.range(of: "keyboardShortcut(.delete, modifiers: .command)"),
                "\(name) must bind ⌘⌫"
            )
            let body = ViewSource.code(after: shortcut.lowerBound, in: source, limit: 300)
            XCTAssertTrue(
                body.contains("!canDelete"),
                "\(name)'s ⌘⌫ must be gated on the trash folder — a shortcut is a verb too"
            )
        }
    }

    /// 清空废纸篓 must be gated on UIDPLUS.
    ///
    /// It is `UID EXPUNGE` over the whole folder, so it has the same
    /// precondition as a single permanent delete.
    func test_theEmptyTrashButtonIsGatedOnUIDPlus() throws {
        let source = try listSource()
        let button = try XCTUnwrap(
            source.range(of: "confirmEmptyTrash = true"),
            "the empty-trash button must exist"
        )
        // The window has to reach past the `label:` closure and the comment
        // that explains the gate — a character limit that stopped short of
        // the `.disabled` line would pass for the wrong reason.
        let body = ViewSource.code(after: button.lowerBound, in: source, limit: 600)
        XCTAssertTrue(
            body.contains("!canPurge"),
            "清空废纸篓 must be gated on UIDPLUS"
        )
    }

    // MARK: - The 已发送 surface tells the truth

    /// A 404 `sent-unavailable` must not be reported as a failed load.
    ///
    /// "这个邮箱没有已发送文件夹" and "邮件列表加载失败" are different
    /// statements, and only the first is true. The second invites a retry
    /// that can never succeed — and the empty state underneath it claims
    /// the user has never sent anything, which is a different claim again
    /// and a wrong one.
    func test_theSentSurfaceReportsAMissingFolderHonestly() throws {
        let source = try listSource()
        let sent = try XCTUnwrap(
            source.range(of: "needsSentRoute == true"),
            "the sent branch must exist"
        )
        let body = ViewSource.code(after: sent.lowerBound, in: source, limit: 2000)
        XCTAssertTrue(
            body.contains("sent-unavailable"),
            "the sent branch must recognise the sent-unavailable code"
        )
        XCTAssertTrue(
            body.contains("l10n.sentUnavailable"),
            "the sent branch must use the dedicated copy for a missing folder"
        )
        XCTAssertTrue(
            body.contains("l10n.sentUnavailableDetail"),
            "the copy must say what it means — and what it does not mean"
        )
    }

    /// The generic "couldn't load the list" banner must not be what a
    /// missing Sent folder produces.
    func test_aMissingSentFolderIsNotAGenericLoadFailure() throws {
        let source = try listSource()
        let sent = try XCTUnwrap(
            source.range(of: "needsSentRoute == true"),
            "the sent branch must exist"
        )
        let body = ViewSource.code(after: sent.lowerBound, in: source, limit: 2000)
        let catchBlock = try XCTUnwrap(
            body.range(of: "catch let error as APIError"),
            "the sent branch must handle its own failure"
        )
        let afterCatch = ViewSource.code(after: catchBlock.lowerBound, in: body, limit: 1200)
        XCTAssertFalse(
            afterCatch.contains("l10n.listLoadFailed"),
            "a missing Sent folder is not a failed list load"
        )
    }
}
