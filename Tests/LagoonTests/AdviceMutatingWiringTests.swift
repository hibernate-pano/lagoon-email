import XCTest
import SwiftUI
import LagoonKit
@testable import Lagoon

/// P2-14: `AdvisedAction.isMutating` was dead code — and behind it sat two
/// real defects.
///
/// ## What the audit said
///
/// The property's comment promised "Used by the UI to decide whether a
/// suggestion needs an explicit confirmation step", and nothing used it.
/// The audit's options were (A) wire it up, or (B) delete it and the
/// lie.
///
/// ## What was actually true
///
/// Option (A) was right, and it exposed two bugs the audit did not name:
///
/// 1. **The 「照做」 button was rendered for a `.delete` suggestion and did
///    nothing.** The row's button set said `.delete` was performable
///    (`acceptableActions` contained it), the executor's switch had no
///    case for it, and the default branch was a silent no-op with a
///    comment claiming it was unreachable. The user tapped "Do it", the
///    mail stayed in the inbox, and nothing said otherwise. A button that
///    silently does nothing is worse than no button — the user believes
///    the mail is gone.
///
/// 2. **An unsubscribe fired on a single tap with no confirmation.** The
///    unsubscribe request tells the publisher; the server archives the
///    mail; the toast says "not undoable". Everything is *correct* — and
///    the user never got to say yes to the one thing that cannot be
///    taken back. That is what `isMutating` was for.
///
/// So `isMutating` is now load-bearing, and the tests below pin the two
/// behaviours it drives.
final class AdviceMutatingWiringTests: XCTestCase {
    private func stripSource() throws -> String {
        try ViewSource.read("RowAdviceStrip")
    }

    private func feedSource() throws -> String {
        try ViewSource.read("BriefingFeedView")
    }

    // MARK: - The property is used, and it is used for the right thing

    /// The strip must offer 「照做」 only for a **mutating** suggestion.
    ///
    /// A 「照做」 on a non-mutating suggestion (reply, wait, remind,
    /// nothing) would be a button that does nothing — the same defect as
    /// the `.delete` one, just for a different set of suggestions.
    func test_theAcceptButtonIsGatedOnTheMutatingFlag() throws {
        let source = try stripSource()
        XCTAssertTrue(
            source.contains("advice.action.isMutating"),
            "the accept button must be gated on isMutating — that is what the property is for"
        )
    }

    /// The property must say what it means: the mutating actions are
    /// exactly the three that change the mailbox.
    func test_theMutatingFlagCoversExactlyTheMailboxChangingActions() {
        let mutating = Set(AdvisedAction.allCases.filter(\.isMutating))
        XCTAssertEqual(mutating, [.archive, .delete, .unsubscribe])
        XCTAssertFalse(AdvisedAction.reply.isMutating)
        XCTAssertFalse(AdvisedAction.wait.isMutating)
        XCTAssertFalse(AdvisedAction.remind.isMutating)
        XCTAssertFalse(AdvisedAction.nothing.isMutating)
    }

    /// The property must not be dead any more.
    ///
    /// The audit's finding was literally "never used". A test that asserts
    /// the property is *referenced* is the only thing that stops it from
    /// going back to being dead code with a comment that promises a
    /// behaviour.
    func test_theMutatingFlagIsReferencedByTheUI() throws {
        let source = try stripSource()
        XCTAssertFalse(
            source.contains("// Used by the UI"),
            "the property's promise must be kept, not just documented"
        )
        XCTAssertTrue(
            source.contains("isMutating"),
            "isMutating must be referenced by the UI"
        )
    }

    // MARK: - The dead `.delete` button

    /// The feed must actually perform a `.delete` suggestion.
    ///
    /// This is the defect the audit did not name: the button was offered
    /// and did nothing.
    func test_theFeedPerformsADeleteSuggestion() throws {
        let source = try feedSource()
        let perform = try XCTUnwrap(
            source.range(of: "private func performAcceptedAdvice("),
            "the executor must exist"
        )
        let body = ViewSource.code(after: perform.lowerBound, in: source, limit: 1200)
        XCTAssertTrue(
            body.contains("case .delete:"),
            "the executor must handle a .delete suggestion — the button promised it"
        )
        XCTAssertTrue(
            body.contains("deleteOne(item)"),
            "a .delete suggestion must reach a real delete"
        )
    }

    /// The single-message delete must exist and must be a real API call.
    func test_theSingleMessageDeleteCallsTheServer() throws {
        let source = try feedSource()
        let fn = try XCTUnwrap(
            source.range(of: "private func deleteOne("),
            "the single-message delete must exist"
        )
        let body = ViewSource.code(after: fn.lowerBound, in: source, limit: 1200)
        XCTAssertTrue(
            body.contains("api.deleteMessage("),
            "the delete must go through the ordinary user-triggered route"
        )
        XCTAssertTrue(
            body.contains("recordAcceptedAdvice("),
            "the acceptance must be recorded, or the learning loop does not start"
        )
        XCTAssertTrue(
            body.contains("errorBanner = ErrorBanner("),
            "a failed delete must be reported, not swallowed"
        )
    }

    /// The button set and the executor must agree.
    ///
    /// They used not to: `acceptableActions` contained `.delete` and the
    /// executor's `default:` branch silently did nothing. The two lists
    /// must now be the same set — and the test says so in both
    /// directions, because a set that grows on one side only is exactly
    /// how the bug came back.
    func test_theButtonSetAndTheExecutorAgree() throws {
        let source = try feedSource()
        let set = try XCTUnwrap(
            source.range(of: "static let acceptableActions:"),
            "the button set must exist"
        )
        let setLine = ViewSource.code(after: set.lowerBound, in: source, limit: 200)
        for action in [".archive", ".delete", ".unsubscribe"] {
            XCTAssertTrue(
                setLine.contains(action),
                "the button set must include \(action)"
            )
        }
        let perform = try XCTUnwrap(
            source.range(of: "private func performAcceptedAdvice(")
        )
        let body = ViewSource.code(after: perform.lowerBound, in: source, limit: 1200)
        for action in [".archive", ".delete", ".unsubscribe"] {
            XCTAssertTrue(
                body.contains("case \(action):"),
                "the executor must handle \(action) — a button with no case is a dead button"
            )
        }
    }

    // MARK: - The missing confirmation

    /// An irreversible action must not fire on the tap.
    ///
    /// The unsubscribe request tells the publisher. There is no undo for
    /// that. The user must get a yes.
    func test_anIrreversibleActionWaitsForAConfirmation() throws {
        let source = try feedSource()
        let accept = try XCTUnwrap(
            source.range(of: "private func acceptAdvice("),
            "the accept entry point must exist"
        )
        let body = ViewSource.code(after: accept.lowerBound, in: source, limit: 1200)
        XCTAssertTrue(
            body.contains("isIrreversible"),
            "an irreversible suggestion must be checked before acting on it"
        )
        XCTAssertTrue(
            body.contains("pendingIrreversibleAccept = record"),
            "the irreversible case must park the suggestion and wait, not fire"
        )
    }

    /// The confirmation must actually exist in the view.
    func test_theConfirmationDialogIsPresented() throws {
        let source = try feedSource()
        XCTAssertTrue(
            source.contains(".confirmationDialog("),
            "the irreversible action needs a confirmation dialog"
        )
        XCTAssertTrue(
            source.contains("adviceAcceptConfirmTitle"),
            "the dialog must have a title that says what is about to happen"
        )
        XCTAssertTrue(
            source.contains("adviceAcceptConfirmBody"),
            "the dialog must say what cannot be undone"
        )
        XCTAssertTrue(
            source.contains("confirmIrreversibleAccept"),
            "the dialog's action must run the action"
        )
    }

    /// The confirmation must be able to say no.
    ///
    /// A confirmation dialog with only one button is not a confirmation.
    func test_theConfirmationOffersACancel() throws {
        let source = try feedSource()
        let dialog = try XCTUnwrap(source.range(of: ".confirmationDialog("))
        let body = ViewSource.code(after: dialog.lowerBound, in: source, limit: 1200)
        XCTAssertTrue(
            body.contains("role: .cancel"),
            "the user must be able to decline"
        )
    }

    /// The destructive button in the dialog must say so.
    func test_theConfirmActionIsMarkedDestructive() throws {
        let source = try feedSource()
        let dialog = try XCTUnwrap(source.range(of: ".confirmationDialog("))
        let body = ViewSource.code(after: dialog.lowerBound, in: source, limit: 1200)
        XCTAssertTrue(
            body.contains("role: .destructive"),
            "the confirm button must be marked destructive — it cannot be undone"
        )
    }

    /// The copy must say the action is irreversible.
    ///
    /// A confirmation that does not say what cannot be undone is a speed
    /// bump, not a safeguard.
    func test_theCopySaysTheActionCannotBeUndone() throws {
        let l10n = try String(
            contentsOf: ViewSource.url(under: "Localization", "L10n"),
            encoding: .utf8
        )
        XCTAssertTrue(
            l10n.contains("不可撤销") || l10n.contains("cannot be undone"),
            "the confirmation body must say the action cannot be undone"
        )
    }
}
