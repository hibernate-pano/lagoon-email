import XCTest
import Foundation
@testable import Lagoon
@testable import LagoonKit

/// The guard for "a group can be changed after it is created" (P1-12).
///
/// ## Why source, and why *attachment*
///
/// The whole feature is **wiring**: a context-menu item that sets a piece of
/// state, a sheet that reads it, a PATCH call in the sheet's save path, and
/// a notification that tells the sidebar to re-read. None of it is
/// reachable from a unit test that drives a `@State` view — SwiftUI's view
/// tree is not inspectable from a test in this package, and the sheet's
/// network call is behind an `APIClient.shared` the test cannot substitute.
///
/// So each assertion below pins the *attachment* — a string that only exists
/// where the wiring exists, positioned between anchors — never the mere
/// presence of a word somewhere in the file. A test that asserted "the file
/// mentions PATCH" would stay green if the menu item were deleted and the
/// string left behind in a comment.
///
/// Every one of these was checked by mutation: remove the wiring and the
/// test goes red.
final class StackEditWiringTests: XCTestCase {

    // MARK: - The entry point

    /// The group's context menu must offer an **edit** action, and it must
    /// set the state the editor reads.
    ///
    /// Before this, the menu offered exactly one item — 删除 — so a group
    /// could be created and destroyed but never changed. The user who built
    /// a group on the wrong keyword had exactly one exit: delete it and
    /// rebuild it.
    func test_theContextMenuOffersAnEditEntry() throws {
        let source = try ViewSource.read("StackSheets")

        // The group's row, sliced so the assertion cannot be satisfied by an
        // "编辑" string that lives somewhere else in the file (the sheet's
        // title, say). The anchors are the list's `ForEach(stacks)` and the
        // `} header:` that closes its Section — both unique in this file, and
        // both *inside* the group list, so the slice cannot wander into the
        // archived row's menu or the mail sheet's.
        let rowStart = try XCTUnwrap(
            source.range(of: "ForEach(stacks) { stack in"),
            "the group's row is gone"
        )
        let rowEnd = try XCTUnwrap(
            source.range(of: "} header: {", range: rowStart.upperBound..<source.endIndex),
            "the group's row has no end anchor — the list's structure changed"
        )
        let row = source[rowStart.lowerBound..<rowEnd.lowerBound]
        XCTAssertTrue(
            row.contains(".contextMenu {"),
            "the group row has no context menu"
        )
        XCTAssertTrue(
            row.contains("l10n.stackEditRule"),
            "the context menu must offer 「编辑此分组…」 — without it a group can only be deleted"
        )
        XCTAssertTrue(
            row.contains("editing = StackEditRequest(rule: stack.rule)"),
            "the edit entry must hand the group to the editor; the state it sets is the editor's only input"
        )
        // The delete entry must survive the edit entry: a menu that replaced
        // delete with edit would have fixed one dead end by opening another.
        XCTAssertTrue(
            row.contains("l10n.stackDeleteRule"),
            "the delete entry must still be there"
        )
    }

    /// The editor must be presented for the group being edited, and it must
    /// be told *which* group it is editing.
    ///
    /// A sheet that opened without the id would create a second group
    /// instead of changing the first — a "fix" that silently duplicates.
    func test_theEditorIsPresentedWithTheGroupBeingEdited() throws {
        let source = try ViewSource.read("StackSheets")

        let sheetStart = try XCTUnwrap(
            source.range(of: ".sheet(item: $editing)"),
            "the edit sheet is never presented"
        )
        let sheet = ViewSource.code(after: sheetStart.lowerBound, in: source, limit: 700)
        XCTAssertTrue(
            sheet.contains("StackRuleEditorSheet("),
            "the edit sheet must reuse the same editor as the create path"
        )
        XCTAssertTrue(
            sheet.contains("editing: request.rule.id"),
            "the editor must be told which group it is editing, or it creates a second one"
        )
        // The three fields are pre-filled from the group, so the user edits
        // what exists rather than retyping it.
        XCTAssertTrue(
            sheet.contains("request.rule.kind"),
            "the editor must open with the group's own match type"
        )
        XCTAssertTrue(
            sheet.contains("request.rule.value"),
            "the editor must open with the group's own match value"
        )
        XCTAssertTrue(
            sheet.contains("request.rule.name"),
            "the editor must open with the group's own name"
        )
    }

    // MARK: - The write

    /// The save path must PATCH when the sheet is editing, and POST when it
    /// is creating. The two are one function, and the branch is the whole
    /// difference between "changed" and "made a second one".
    func test_theSavePathPatchesWhenEditing() throws {
        let source = try ViewSource.read("StackSheets")

        let saveStart = try XCTUnwrap(
            source.range(of: "private func save() async"),
            "the editor's save path is gone"
        )
        let save = ViewSource.code(after: saveStart.lowerBound, in: source, limit: 2600)
        XCTAssertTrue(
            save.contains("api.updateStack("),
            "an edit must go through PATCH — createStack would make a second group"
        )
        XCTAssertTrue(
            save.contains("api.createStack("),
            "the create path must still be there"
        )
        XCTAssertTrue(
            save.contains("id: editing"),
            "the PATCH must name the group being edited"
        )
    }

    /// The save must report which of the two things happened. "已创建" on an
    /// edit says the wrong thing about what just happened, and the two
    /// paths are one function, so the branch has to be there.
    func test_theSaveReportsCreatedVersusUpdated() throws {
        let source = try ViewSource.read("StackSheets")
        let saveStart = try XCTUnwrap(
            source.range(of: "private func save() async"),
            "the editor's save path is gone"
        )
        let save = ViewSource.code(after: saveStart.lowerBound, in: source, limit: 2600)
        XCTAssertTrue(
            save.contains("L10n.current.stackUpdated("),
            "an edit must say it updated the group, not that it created one"
        )
        XCTAssertTrue(
            save.contains("L10n.current.stackCreated("),
            "a create must still say it created the group"
        )
    }

    // MARK: - The refresh

    /// A renamed group that only changed in the panel it was edited in would
    /// leave the sidebar showing the old name — the "I renamed it and
    /// nothing happened" failure.
    ///
    /// The notification is the same one the two mail surfaces already listen
    /// for, so there is one definition of "refresh" rather than one per
    /// surface.
    func test_aSuccessfulEditTellsTheSidebarToReRead() throws {
        let source = try ViewSource.read("StackSheets")
        let saveStart = try XCTUnwrap(
            source.range(of: "private func save() async"),
            "the editor's save path is gone"
        )
        let save = ViewSource.code(after: saveStart.lowerBound, in: source, limit: 2600)
        XCTAssertTrue(
            save.contains("NotificationCenter.default.post(name: .lagoonDidChangeData"),
            "a saved edit must tell the sidebar to re-read, or the old name stays on screen"
        )
    }

    /// The sidebar is the surface that lists the groups, and it re-reads them
    /// from `/api/stacks` — which it did not do on this notification before.
    /// Without the listener, the notification the editor posts goes to the
    /// two mail surfaces and nobody else, and the sidebar keeps the old
    /// name and the old count.
    func test_theSidebarReReadsOnThatNotification() throws {
        let source = try ViewSource.read("RootView")
        XCTAssertTrue(
            source.contains(".onReceive(NotificationCenter.default.publisher(for: .lagoonDidChangeData))"),
            "RootView must listen for the data-change notification, or the sidebar keeps the old group name"
        )
        // The listener has to actually re-read the sidebar's data, not just
        // exist: the notification arrives on every surface's change, and a
        // listener that does nothing is the same as no listener.
        let listener = try XCTUnwrap(
            source.range(of: ".onReceive(NotificationCenter.default.publisher(for: .lagoonDidChangeData))"),
            "RootView must listen for the data-change notification"
        )
        let after = ViewSource.code(after: listener.lowerBound, in: source, limit: 400)
        XCTAssertTrue(
            after.contains("refreshSidebarData()"),
            "the listener must re-read the sidebar's groups and counts"
        )
    }

    // MARK: - The naming

    /// The product must not call these things 「规则」 any more.
    ///
    /// In a mail product a 规则 means "condition + action" — Outlook's rules
    /// file mail into a folder, Gmail's rules label and skip. A group here
    /// has a condition and **no action**: it is a saved filter, evaluated
    /// when the list is read. Calling it a rule promised an action that does
    /// not exist.
    ///
    /// This is pinned on the *user-visible* strings, not on the comments:
    /// the source is full of 「规则」 in prose that never reaches a screen.
    func test_theUserFacingStringsDoNotSay规则() throws {
        let l10n = try String(
            contentsOf: ViewSource.url(under: "Localization", "L10n"),
            encoding: .utf8
        )
        // The strings that name the thing: the group list, the section
        // header, the empty state, the editor's name field.
        for key in [
            "stackListTitle", "stackRulesHeader", "myGroups",
            "stackEmpty", "stackRuleName", "stackEditorTitle",
        ] {
            let declaration = try XCTUnwrap(
                l10n.range(of: "public var \(key): String"),
                "the localization key \(key) is gone"
            )
            let line = l10n[declaration.lowerBound...].prefix(200)
            XCTAssertFalse(
                line.contains("规则"),
                "\(key) still says 「规则」 — a group is a saved filter, not a rule: \(line)"
            )
        }
    }

    /// The match type's name must come from the localization layer.
    ///
    /// `StackRule.Kind.displayName` used to return hardcoded Chinese
    /// ("发件人" / "关键词") from `LagoonKit`, and the group row printed it
    /// straight to the screen — so an English user read 「按发件人」 under a
    /// group they had just named in English.
    func test_theMatchTypeNameComesFromL10n() throws {
        let source = try ViewSource.read("StackSheets")
        XCTAssertFalse(
            source.contains("kind.displayName"),
            "the group row must not read the hardcoded Chinese match-type name"
        )
        XCTAssertTrue(
            source.contains("l10n.stackKindName("),
            "the group row must ask the localization layer for the match-type name"
        )
    }
}
