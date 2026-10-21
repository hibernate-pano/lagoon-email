import XCTest
import SwiftUI
@testable import Lagoon

/// The 发件人排行 panel has to *say* that a rule landed.
///
/// `markFiled(_:)` was never called, so `filedAddress` stayed nil and the
/// green 「已建立聚合」 label never appeared — the panel looked exactly the
/// same whether the rule was created or the button did nothing.
///
/// The fix has two halves, and both are pinned here: the panel writes
/// through a binding (so the write reaches the owner of the state instead
/// of dying in a view instance nobody can reach), and the rule editor's
/// success callback is what raises the write.
final class SenderFilingFeedbackTests: XCTestCase {

    /// The write has to leave the panel. A local `@State` would have made
    /// `markFiled` a method that changes nothing anybody can see.
    @MainActor
    func test_markFiledWritesThroughToTheOwner() {
        var filed: String?
        let panel = SenderRankingSheet(
            accountId: UUID(),
            filedAddress: Binding(get: { filed }, set: { filed = $0 })
        )
        panel.markFiled("newsletter@example.com")
        XCTAssertEqual(
            filed, "newsletter@example.com",
            "the confirmation must reach the state the row reads"
        )
    }

    /// The write is per sender: filing one sender must not mark another.
    @MainActor
    func test_markFiledNamesTheSenderItWasGiven() {
        var filed: String?
        let panel = SenderRankingSheet(
            accountId: UUID(),
            filedAddress: Binding(get: { filed }, set: { filed = $0 })
        )
        panel.markFiled("a@example.com")
        XCTAssertEqual(filed, "a@example.com")
        XCTAssertNotEqual(filed, "b@example.com")
    }

    /// The panel marks the row from the rule editor's *success* callback —
    /// that is the only place that knows the rule exists. Marking on the
    /// click would claim a rule the server may have refused.
    func test_theRuleCreationCallbackRaisesTheConfirmation() throws {
        let source = try ViewSource.read("SenderRankingSheet")
        let editor = try XCTUnwrap(
            source.range(of: "StackRuleEditorSheet("),
            "the panel must present the rule editor"
        )
        let code = ViewSource.code(after: editor.lowerBound, in: source, limit: 800)
        XCTAssertTrue(
            code.contains("markFiled("),
            "the success callback must mark the sender, or the checkmark stays dead code"
        )
        XCTAssertTrue(
            code.contains("onFileSender("),
            "the parent has to hear about the new rule so the sidebar can list it"
        )
    }

    /// The panel's state is a binding, not local state — the sheet is an
    /// independent view instance, so a local `@State` could never be
    /// written by the owner of the flow.
    func test_filedAddressIsABindingNotLocalState() throws {
        let source = try ViewSource.read("SenderRankingSheet")
        XCTAssertTrue(
            source.contains("@Binding var filedAddress: String?"),
            "filedAddress must be a binding so the write reaches the owner"
        )
        XCTAssertFalse(
            source.contains("@State private var filedAddress"),
            "a local @State is exactly the dead end the fix removed"
        )
    }

    /// The owner holds the state and hands it down.
    func test_rootViewOwnsTheFiledAddress() throws {
        let source = try ViewSource.read("RootView")
        XCTAssertTrue(
            source.contains("@State private var filedSenderAddress: String?"),
            "RootView must own the filed address — it is the only view that "
                + "sees both the panel and the list"
        )
        XCTAssertTrue(
            source.contains("filedAddress: $filedSenderAddress"),
            "the panel must receive the owner's state as a binding"
        )
    }

    /// The 归集 button opens the editor from the panel itself. It used to
    /// hand a pending value to the list instead, and that request was
    /// dropped whenever the destination changed underneath it — the list is
    /// keyed on the destination, so switching to it recreated the list and
    /// the pending value with it.
    func test_thePanelPresentsTheEditorItself() throws {
        let source = try ViewSource.read("SenderRankingSheet")
        XCTAssertTrue(
            source.contains("pendingFiling = PendingFiling(sender: sender)"),
            "归集 must open the editor from the panel"
        )
        XCTAssertTrue(
            source.contains(".sheet(item: $pendingFiling)"),
            "the editor must be presented by the panel, not by another surface"
        )
    }
}
