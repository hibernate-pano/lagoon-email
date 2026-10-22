import XCTest
import SwiftUI
import LagoonKit
@testable import Lagoon

/// The triage panels, one test per defect the third-round audit found in
/// them.
///
/// ## Why most of these read the source
///
/// SwiftUI bodies are not runnable in a unit test. The failures being
/// guarded here are *missing wiring* — a button that was never rendered, a
/// confirmation that was never asked for, a count that names the wrong
/// set — and a missing wire cannot be seen from the outside. The parts
/// that *are* arithmetic (the remaining-count rule, the palette's spoken
/// value) are tested as behaviour, on the real types.
@MainActor
final class PanelBehaviourTests: XCTestCase {
    // MARK: - T-03 · the advice panel offers the verbs the inline strip offers

    /// 「设提醒」 — for a `.remind` suggestion.
    ///
    /// A suggestion with a deadline and no way to act on it is the empty
    /// promise the whole feature exists to remove, and the advice panel is
    /// where a user goes to see the suggestions they have not dealt with
    /// yet. The panel used to offer two verbs where the inline strip
    /// offered three, so a `.remind` row visible in the panel could not
    /// become a reminder at all.
    func test_theAdvicePanelOffersToSetAReminder() throws {
        let source = try ViewSource.read("AdviceSheet")
        let row = try XCTUnwrap(
            source.range(of: "private func row(_ record: AdviceRecord)"),
            "the row builder moved"
        )
        let end = try XCTUnwrap(
            source.range(of: "// MARK: - Actions"),
            "the actions section moved"
        )
        let body = ViewSource.code(
            after: row.lowerBound,
            in: source[row.lowerBound..<end.lowerBound],
            limit: 8_000
        )
        XCTAssertTrue(
            body.contains("record.advice.action == .remind"),
            "the 设提醒 button must be gated on a .remind suggestion"
        )
        XCTAssertTrue(
            body.contains("l10n.reminderSet"),
            "the panel must offer 设提醒"
        )
    }

    /// 「照做」 — for a suggestion that performs a mailbox write, and only
    /// while it is still pending.
    ///
    /// The gate is `AdvisedAction.isMutating`, the same property the
    /// inline strip uses: a non-mutating suggestion has no mailbox write to
    /// perform, and a button for it would be a button that does nothing.
    func test_theAdvicePanelOffersToPerformAMutatingSuggestion() throws {
        let source = try ViewSource.read("AdviceSheet")
        let row = try XCTUnwrap(
            source.range(of: "private func row(_ record: AdviceRecord)"),
            "the row builder moved"
        )
        let end = try XCTUnwrap(
            source.range(of: "// MARK: - Actions"),
            "the actions section moved"
        )
        let body = ViewSource.code(
            after: row.lowerBound,
            in: source[row.lowerBound..<end.lowerBound],
            limit: 8_000
        )
        XCTAssertTrue(
            body.contains("record.advice.action.isMutating"),
            "the 照做 button must be gated on the model's own mutating rule"
        )
        XCTAssertTrue(
            body.contains("l10n.adviceAccept"),
            "the panel must offer 照做"
        )
        XCTAssertTrue(
            body.contains("record.decision == .pending"),
            "a decided suggestion must not offer to be performed"
        )
    }

    /// The irreversible case stops and asks.
    ///
    /// An unsubscribe tells the publisher, and that cannot be taken back —
    /// so the same rule the inline strip follows (`isIrreversible`) has to
    /// stop the request here too.
    func test_anIrreversibleSuggestionIsConfirmedBeforeItRuns() throws {
        let source = try ViewSource.read("AdviceSheet")
        XCTAssertTrue(
            source.contains("record.advice.action.isIrreversible"),
            "an irreversible action must wait for the answer"
        )
        XCTAssertTrue(
            source.contains("l10n.adviceAcceptConfirmTitle"),
            "the confirmation must be the one the app already uses for an irreversible action"
        )
        // And it must not fire straight away.
        let accept = try XCTUnwrap(
            source.range(of: "private func accept(_ record: AdviceRecord)"),
            "the accept path moved"
        )
        let end = try XCTUnwrap(
            source.range(of: "private func performAcceptedAdvice"),
            "the performer moved"
        )
        let body = ViewSource.code(
            after: accept.lowerBound,
            in: source[accept.lowerBound..<end.lowerBound],
            limit: 2_000
        )
        XCTAssertTrue(
            body.contains("pendingIrreversibleAccept = record"),
            "the irreversible case must stop at the confirmation"
        )
    }

    /// The advice panel and the Briefing row must run the *same* executor.
    ///
    /// Two implementations of "照做" is how two surfaces end up disagreeing
    /// about what the button did — one of them offering an undo the other
    /// does not, or recording the acceptance and the other not.
    func test_theAdvicePanelUsesTheSharedPerformer() throws {
        let source = try ViewSource.read("AdviceSheet")
        XCTAssertTrue(
            source.contains("AdvicePerformer.perform("),
            "the panel must perform the advised action through the shared executor"
        )
        XCTAssertTrue(
            source.contains("AdviceAcceptanceRecorder.record("),
            "the panel must record the acceptance through the shared recorder"
        )
        XCTAssertTrue(
            source.contains("AdvicePerformer.undoItem("),
            "the panel must build the undo toast through the shared executor"
        )
    }

    // MARK: - T-04 · the empty aggregation panel explains itself

    /// The empty state must say what is empty.
    ///
    /// The sheet used to say 「没有来自此发件人的邮件」 for both of its
    /// sources — but one is the archive cabinet and the other is a group
    /// the user wrote, which may match on a *keyword*. Telling a user who
    /// just created a keyword group that they have no mail from a sender
    /// explains something that was never asked, and is false.
    func test_theStackMailEmptyStateIsSourceSpecific() throws {
        let source = try ViewSource.read("StackSheets")
        XCTAssertFalse(
            source.contains("l10n.senderMailEmpty"),
            "the stack panel must not talk about senders — one of its sources is a keyword group"
        )
        XCTAssertTrue(
            source.contains("l10n.stackArchivedEmpty"),
            "the archive cabinet needs its own empty state"
        )
        XCTAssertTrue(
            source.contains("l10n.stackGroupEmpty"),
            "a group needs its own empty state"
        )
    }

    // MARK: - T-05 · deleting a reminder asks first

    /// A reminder delete is a hard delete, and it used to happen on one
    /// right-click with no confirmation and no way back.
    func test_deletingAReminderAsksFirstAndNamesIt() throws {
        let source = try ViewSource.read("RemindersSheet")
        XCTAssertTrue(
            source.contains("pendingDelete"),
            "the delete must wait for a confirmation"
        )
        XCTAssertTrue(
            source.contains("l10n.reminderDeleteConfirmTitle"),
            "the confirmation must have a title"
        )
        XCTAssertTrue(
            source.contains("l10n.reminderDeleteConfirmMessage("),
            "the confirmation must name the reminder that is about to go"
        )
        // The context menu may only *ask*.
        let menu = try XCTUnwrap(
            source.range(of: ".contextMenu {"),
            "the context menu moved"
        )
        let end = try XCTUnwrap(
            source.range(of: "private func subject(of reminder: Reminder?)"),
            "the subject helper moved"
        )
        let body = ViewSource.code(
            after: menu.lowerBound,
            in: source[menu.lowerBound..<end.lowerBound],
            limit: 3_000
        )
        XCTAssertFalse(
            body.contains("await delete(reminder)"),
            "the context menu must not delete outright — it must ask"
        )
        XCTAssertTrue(
            body.contains("pendingDelete = reminder"),
            "the context menu must arm the confirmation"
        )
    }

    // MARK: - T-06 · deleting a group asks first, and says what it does

    /// A group is not a message: deleting one re-routes an endless future
    /// stream of mail, and it used to have a smaller safety net than
    /// deleting a single mail — one right-click and no confirmation.
    func test_deletingAGroupAsksFirstAndNamesTheGroupAndItsCount() throws {
        let source = try ViewSource.read("StackSheets")
        XCTAssertTrue(
            source.contains("pendingDeleteRule"),
            "the delete must wait for a confirmation"
        )
        XCTAssertTrue(
            source.contains("l10n.stackDeleteRuleConfirmTitle("),
            "the confirmation must name the group"
        )
        XCTAssertTrue(
            source.contains("l10n.stackDeleteRuleConfirmMessage("),
            "the confirmation must say what deleting the group does"
        )
        XCTAssertTrue(
            source.contains("count(of: pendingDeleteRule)"),
            "the confirmation must name how much mail the group matches"
        )
    }

    // MARK: - T-10 · the sender panel counts what it acts on

    /// The bulk bar must state the number the buttons act on.
    ///
    /// The server's total is the truth about the sender; the loaded window
    /// is the truth about what the verbs will move. The bar used to show
    /// the first while the buttons did the second.
    func test_theBulkBarCountsTheRowsTheVerbsActOn() throws {
        let source = try ViewSource.read("SenderSheet")
        XCTAssertTrue(
            source.contains("l10n.senderCount(messages.count)"),
            "the bar must count the rows the bulk verbs act on"
        )
        XCTAssertFalse(
            source.contains("l10n.senderCount(totalCount"),
            "the bar must not count rows the verbs will not touch"
        )
    }

    /// The scope has to be stated *in the bar* — the one place the user
    /// reads before pressing a button. It used to appear at the bottom of
    /// the list, after the action.
    func test_theBulkScopeIsStatedWhereTheButtonsAre() throws {
        let source = try ViewSource.read("SenderSheet")
        XCTAssertTrue(
            source.contains("l10n.senderBulkScope("),
            "the bar must say what the bulk actions cover"
        )
        let bar = try XCTUnwrap(
            source.range(of: "private var bulkBar: some View"),
            "the bulk bar moved"
        )
        let end = try XCTUnwrap(
            source.range(of: "private var confirmTitle: String"),
            "the confirmation helpers moved"
        )
        let body = ViewSource.code(
            after: bar.lowerBound,
            in: source[bar.lowerBound..<end.lowerBound],
            limit: 6_000
        )
        XCTAssertTrue(
            body.contains("scopeNotice"),
            "the scope notice must be rendered in the bar"
        )
    }

    /// Every confirmation names the number it is about to move.
    ///
    /// "所有" is a promise the panel cannot keep: the verbs act on the rows
    /// the response carried.
    func test_everyBulkConfirmationCarriesItsCount() throws {
        let source = try ViewSource.read("SenderSheet")
        XCTAssertTrue(
            source.contains("l10n.senderAllArchiveConfirm(archivableIds.count)"),
            "the archive confirmation must name the number of mails it moves"
        )
        XCTAssertTrue(
            source.contains("l10n.senderAllReadConfirm(unreadIds.count)"),
            "the mark-read confirmation must name the number of mails it moves"
        )
        XCTAssertTrue(
            source.contains("l10n.senderAllDeleteConfirm(archivableIds.count)"),
            "the delete confirmation must name the number of mails it moves"
        )
    }

    // MARK: - U3-19 · the palette never reads an empty value

    /// A row without a shortcut must not be announced with a blank value.
    ///
    /// VoiceOver reads "value, empty" out loud, so every shortcut-less row
    /// made the user wait through a field that said nothing.
    func test_thePaletteNeverAnnouncesAnEmptyValue() throws {
        let source = try ViewSource.read("CommandPaletteView")
        XCTAssertFalse(
            source.contains(".accessibilityValue(command.shortcut ?? \"\")"),
            "an empty accessibility value is read out loud — the value must be omitted instead"
        )
        XCTAssertTrue(
            source.contains("OptionalAccessibilityValue(value: command.spokenValue)"),
            "the row must take its spoken value from the command"
        )
    }

    /// The behaviour, on the real type: a row with nothing to say has no
    /// value at all, and a row with a state says the state.
    func test_aCommandWithoutAShortcutOrStateHasNoSpokenValue() {
        let palette = CommandPaletteView(
            onNewMessage: {}, onSearch: {}, onToggleSurface: {},
            onShowUsage: {}, onShowActionHistory: {},
            onShowAdvice: {}, onShowReminders: {}, onShowSenderRanking: {},
            onCycleDensity: {}, onShowShortcuts: {}, onShowAISettings: {},
            onRefresh: {}, onGetNewMail: {}, onToggleSound: {}
        )
        let bare = palette.allCommands.first { $0.shortcut == nil && $0.state == nil }
        XCTAssertNotNil(bare, "the palette is expected to have a row without a key")
        XCTAssertNil(bare?.spokenValue, "a row with nothing to say must have no value")

        let keyed = palette.allCommands.first { $0.shortcut != nil }
        XCTAssertEqual(keyed?.spokenValue, keyed?.shortcut)

        let stateful = palette.allCommands.first { $0.state != nil }
        XCTAssertEqual(stateful?.spokenValue, stateful?.state)
    }

    // MARK: - U3-20 · the sound row says what it is and what it did

    /// The sound is the one row whose *state* matters.
    func test_theSoundRowCarriesItsState() throws {
        let source = try ViewSource.read("CommandPaletteView")
        XCTAssertTrue(
            source.contains("state: SoundEffects.isEnabled ? l10n.soundOn : l10n.soundOff"),
            "the sound row must say whether the sound is on"
        )
    }

    /// And toggling it says what happened.
    ///
    /// The palette closes on every command, so a toggle that reported its
    /// result only in its own row would report nothing at all.
    func test_togglingTheSoundReportsTheNewState() throws {
        let source = try ViewSource.read("CommandPaletteView")
        XCTAssertTrue(
            source.contains("ErrorCenter.shared.report("),
            "the toggle must report its result where the user can still see it"
        )
        let toggle = try XCTUnwrap(
            source.range(of: "private func toggleSound()"),
            "the sound toggle moved"
        )
        let end = try XCTUnwrap(
            source.range(of: "// MARK: - Chrome"),
            "the chrome section moved"
        )
        let body = ViewSource.code(
            after: toggle.lowerBound,
            in: source[toggle.lowerBound..<end.lowerBound],
            limit: 2_000
        )
        XCTAssertTrue(
            body.contains("onToggleSound()"),
            "the toggle must actually flip the sound"
        )
        XCTAssertTrue(
            body.contains("severity: .success"),
            "a successful toggle is a success, and must not be reported in the error colour"
        )
    }

    // MARK: - U3-13 · the density row is where it can be reached

    /// The palette is ordered by how often a row is used, and the density
    /// row was last but three — behind three panels the user opens
    /// rarely — while it is the one row that changes how every other row
    /// looks.
    func test_theDensityRowSitsAboveTheRarelyOpenedPanels() {
        let palette = CommandPaletteView(
            onNewMessage: {}, onSearch: {}, onToggleSurface: {},
            onShowUsage: {}, onShowActionHistory: {},
            onShowAdvice: {}, onShowReminders: {}, onShowSenderRanking: {},
            onCycleDensity: {}, onShowShortcuts: {}, onShowAISettings: {},
            onRefresh: {}, onGetNewMail: {}, onToggleSound: {}
        )
        let ids = palette.allCommands.map(\.id)
        let density = try? XCTUnwrap(ids.firstIndex(of: "density"))
        XCTAssertNotNil(density)
        for rare in ["ai-settings", "reminders", "senders"] {
            let index = try? XCTUnwrap(ids.firstIndex(of: rare))
            XCTAssertNotNil(index)
            XCTAssertLessThan(
                density!, index!,
                "the density row must come before \(rare)"
            )
        }
    }
}
