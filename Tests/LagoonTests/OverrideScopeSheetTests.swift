import XCTest
import SwiftUI
import LagoonKit
@testable import Lagoon

/// P2-13, client side: the 「改分组」 interface must tell the truth.
///
/// ## What was wrong
///
/// The detail view offered "change group" on **one mail**, through a
/// `confirmationDialog` that listed the groups and said nothing else. The
/// server applied the change to **every mail from that sender**. The
/// interface never said so — the user acted on one mail and something
/// broader happened, silently.
///
/// ## Why these are source-level guards
///
/// The bug is a *wording* bug: the code did what it always did, and the
/// promise it made on screen did not match. A behavioural test cannot see
/// that — it would have to assert on the rendered strings of a
/// `confirmationDialog`, which is a snapshot of a popover, not a view. So
/// these read the source and pin the facts that must be true of it.
///
/// They are not a substitute for reading the diff; they are the part that
/// survives a refactor. A future change that removes the scope picker, or
/// that drops the sender's address from the confirmation, fails here.
final class OverrideScopeSheetTests: XCTestCase {
    private func detailSource() throws -> String {
        try ViewSource.read("MessageDetailView")
    }

    private func sheetSource() throws -> String {
        try ViewSource.read("OverrideScopeSheet")
    }

    private func l10nSource() throws -> String {
        try String(
            contentsOf: ViewSource.url(under: "Localization", "L10n+Override"),
            encoding: .utf8
        )
    }

    private func apiSource() throws -> String {
        try String(
            contentsOf: ViewSource.url(under: "Services", "APIClient+Override"),
            encoding: .utf8
        )
    }

    // MARK: - The detail view must offer a scope, not just a group

    /// The detail view must open the scope sheet, not the old
    /// `confirmationDialog`.
    ///
    /// The dialog is the shape of the bug: a flat list of groups with no
    /// room to say how far the change reaches.
    func test_theDetailViewOpensTheScopeSheet_notABareGroupList() throws {
        let source = try detailSource()
        XCTAssertTrue(
            source.contains("OverrideScopeSheet("),
            "the detail view must open the scope sheet"
        )
        XCTAssertFalse(
            source.contains(".confirmationDialog(l10n.overrideGroup"),
            "the old group-only confirmation dialog must be gone — it could not "
                + "state the blast radius"
        )
    }

    /// The sheet must receive the sender's address.
    ///
    /// "Every mail from this sender" is only meaningful if the user can see
    /// *which* sender. Without the address the confirmation is a promise
    /// about nobody.
    func test_theSheetIsGivenTheSenderAddress() throws {
        let source = try detailSource()
        XCTAssertTrue(
            source.contains("senderAddress: senderEmail"),
            "the sheet must be told which sender's mail is about to move"
        )
    }

    /// The scope must reach the request.
    ///
    /// This is the wiring assertion: the sheet's choice has to arrive at the
    /// API call, or the sheet is a decoration.
    ///
    /// ## Why this reads the call site and not the file
    ///
    /// The first version asserted `source.contains("scope: scope")` over the
    /// whole of `MessageDetailView`. That string also appears in the two
    /// local calls (`overrideClassification(to:scope:)` and its retry), so
    /// hard-coding `.sender` at the **API** call site left the assertion
    /// green — the sheet would have offered a choice that the code then
    /// ignored, and the test would have blessed it. The window below is the
    /// few lines around `api.overrideClassification(` only.
    func test_theChosenScopeReachesTheApiCall() throws {
        let source = try detailSource()
        let callSites = ViewSource.occurrences(of: "api.overrideClassification(", in: source)
        XCTAssertEqual(
            callSites.count, 1,
            "there must be exactly one classify call site; found \(callSites.count)"
        )
        let call = ViewSource.code(after: try XCTUnwrap(callSites.first), in: source, limit: 400)
        XCTAssertTrue(
            call.contains("scope: scope"),
            "the chosen scope must be passed to the API call, not a hard-coded one"
        )
        XCTAssertFalse(
            call.contains("scope: .sender"),
            "the API call must not hard-code the broad scope — the sheet's choice would be a lie"
        )
        let api = try apiSource()
        XCTAssertTrue(
            api.contains("\"scope\": scope.rawValue"),
            "the scope must travel in the request body"
        )
    }

    // MARK: - The safe default

    /// The narrow scope must be the default.
    ///
    /// The user opened this from **one mail**. The broad option changes
    /// every mail from that sender — a larger act than the gesture implied
    /// — so it must never be what a single click lands on.
    func test_theNarrowScopeIsTheDefault() throws {
        let source = try sheetSource()
        XCTAssertTrue(
            source.contains("_scope = State(initialValue: .message)"),
            "the sheet must open on the narrow scope"
        )
        XCTAssertFalse(
            source.contains("_scope = State(initialValue: .sender)"),
            "the broad scope must never be the default"
        )
    }

    /// Both options must be offered.
    ///
    /// Offering only the narrow one would leave the user with no way to say
    /// "everything from this sender" — which is a thing people genuinely
    /// want, and which the product did before (silently).
    func test_bothScopesAreOffered() throws {
        let source = try sheetSource()
        XCTAssertTrue(
            source.contains("Text(l10n.overrideScopeMessageOnly).tag(OverrideScope.message)"),
            "the narrow scope must be offered"
        )
        XCTAssertTrue(
            source.contains("Text(l10n.overrideScopeSenderAll).tag(OverrideScope.sender)"),
            "the broad scope must be offered"
        )
    }

    // MARK: - The copy says what will happen

    /// Both bodies must name the sender.
    ///
    /// The whole point of the change is that the user is told *whose* mail
    /// is about to move. A body that says "all mail" without the address
    /// would still be a promise about an unknown party.
    ///
    /// ## Why the count, and not one `contains`
    ///
    /// The first version asserted `contains("sender: senderAddress")` — one
    /// literal, once. A mutation that replaced **only the narrow** body's
    /// argument with an empty string left the broad body's call site intact,
    /// so the assertion still passed while the sheet had started saying
    /// "Only this mail moves… other mail from  is unaffected". The count is
    /// what makes the test describe the invariant rather than one shape of
    /// the source.
    func test_bothScopeBodiesNameTheSender() throws {
        let l10n = try l10nSource()
        for function in ["overrideSenderScopeBody", "overrideMessageScopeBody"] {
            XCTAssertTrue(
                l10n.contains("func \(function)(sender: String)"),
                "\(function) must take the sender's address"
            )
        }
        // Both call sites — narrow and broad — must pass the real address.
        let sheet = try sheetSource()
        let callSites = ViewSource.occurrences(of: "sender: senderAddress", in: sheet)
        XCTAssertEqual(
            callSites.count, 2,
            "both scope bodies must be given the sender's address; got \(callSites.count) "
                + "call site(s)"
        )
        XCTAssertFalse(
            sheet.contains("sender: \"\""),
            "an empty sender turns the confirmation into a promise about nobody"
        )
    }

    /// The narrow body must say the other mail is **not** affected, and the
    /// broad body must say it **is**.
    ///
    /// "It does not affect anything else" and "it affects everything" are
    /// opposite sentences, and both have to be present: the user is
    /// choosing between them.
    func test_theTwoBodiesSayOppositeThings() throws {
        let l10n = try l10nSource()
        XCTAssertTrue(
            l10n.contains("不受影响"),
            "the narrow body must say the sender's other mail is unaffected"
        )
        XCTAssertTrue(
            l10n.contains("的所有邮件"),
            "the broad body must say every mail from the sender moves"
        )
    }

    /// The toast must say which scope happened.
    ///
    /// "已记录你的偏好" says *that* something happened and not *what*. The
    /// scope detail says "one mail" or "the whole sender" — the two facts
    /// the user needs and cannot otherwise recover.
    func test_theToastCarriesTheScope() throws {
        let l10n = try l10nSource()
        XCTAssertTrue(
            l10n.contains("func overrideScopeDetail(_ scope: OverrideScope)"),
            "the scope detail must be a function of the scope"
        )
        let detail = try detailSource()
        XCTAssertTrue(
            detail.contains("l10n.overrideAppliedToast(scope: scope)"),
            "the toast must be built from the scope that was applied"
        )
    }

    // MARK: - The sheet has no dead ends

    /// Both buttons must dismiss the sheet.
    ///
    /// A Cancel button with an empty body leaves the sheet open with no way
    /// out except the window's close button — a dead end the user reaches
    /// by changing their mind about the scope. And a sheet that stays open
    /// after Apply hides the very mail the user is trying to re-check.
    func test_bothButtonsDismissTheSheet() throws {
        let sheet = try sheetSource()
        XCTAssertTrue(
            sheet.contains("@Environment(\\.dismiss) private var dismiss"),
            "the sheet must be able to dismiss itself"
        )
        XCTAssertTrue(
            sheet.contains("Button(l10n.cancel) { dismiss() }"),
            "Cancel must close the sheet"
        )
        let apply = try XCTUnwrap(
            ViewSource.occurrences(of: "Button(l10n.overrideScopeConfirm)", in: sheet).first
        )
        let applyCode = ViewSource.code(after: apply, in: sheet, limit: 600)
        XCTAssertTrue(
            applyCode.contains("dismiss()"),
            "Apply must close the sheet once the change is on its way"
        )
    }

    // MARK: - The concept overlap is named
    /// The sheet must say where the mail is **now**.
    ///
    /// "Move it out of 需要回复" is a different decision from "move it
    /// somewhere", and the current group is the fact that makes the first
    /// reading available. It is also the only place the sheet uses the
    /// group it was opened on — without it, the parameter would be dead.
    func test_theSheetSaysWhichGroupTheMailIsInNow() throws {
        let sheet = try sheetSource()
        XCTAssertTrue(
            sheet.contains("l10n.overrideCurrentGroup("),
            "the sheet must show the group the mail is in right now"
        )
        let detail = try detailSource()
        XCTAssertTrue(
            detail.contains("currentGroup: initialGroup"),
            "the detail view must hand the sheet the mail's current group"
        )
    }
    /// The sheet must point at the sidebar's own groups.
    ///
    /// 「改分组」 and 「我的分组」 are two different mechanisms that both
    /// group mail by sender, with two tables and two names. The user has no
    /// way to know they are related. The sheet must say where the other one
    /// lives — without pretending they are the same thing, which they are
    /// not.
    func test_theSheetPointsAtTheSidebarGroups() throws {
        let sheet = try sheetSource()
        XCTAssertTrue(
            sheet.contains("l10n.overrideSidebarGroupsNote"),
            "the sheet must name the sidebar's group mechanism"
        )
        let l10n = try l10nSource()
        XCTAssertTrue(
            l10n.contains("我的分组"),
            "the note must name the sidebar section the user can see"
        )
    }

    // MARK: - The scope type is shared, not re-declared

    /// The scope must be one shared type, not two stringly-typed copies.
    ///
    /// The client and the server exchange the scope as a string; if each
    /// side had its own spelling, the mismatch would be silent — the server
    /// would treat an unknown scope as the narrow one, and the user's broad
    /// choice would quietly become a one-mail change.
    func test_theScopeIsOneSharedType() throws {
        // `ViewSource.url` is rooted at `Sources/Lagoon`, and the shared
        // type lives in the *kit* — so the path is built from the package
        // root instead.
        let scopeType = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()   // LagoonTests
                .deletingLastPathComponent()   // Tests
                .deletingLastPathComponent()   // package root
                .appendingPathComponent("Sources/LagoonKit/OverrideScope.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            scopeType.contains("public enum OverrideScope"),
            "the scope must be one public type in LagoonKit, shared by both sides"
        )
        // The client must use *that* type, not a local copy of the strings.
        let api = try apiSource()
        XCTAssertTrue(
            api.contains("scope: OverrideScope"),
            "the client method must take the shared OverrideScope"
        )
        let sheet = try sheetSource()
        XCTAssertTrue(
            sheet.contains("@State private var scope: OverrideScope = .message"),
            "the sheet must hold the shared OverrideScope, not a local string"
        )
    }
}
