import XCTest
import Foundation
import LagoonKit
@testable import Lagoon

/// The reminders the user set for themselves must be a **real** feature.
///
/// ## Why this file exists
///
/// The AI's action vocabulary included "remind", the row carried a bell
/// icon, and the copy read 「建议提醒」 — and nothing was stored, nothing
/// was scheduled, nothing ever happened. The user was shown a promise the
/// product could not keep, which is worse than not making it: it teaches
/// the user to distrust every other suggestion.
///
/// These are source-level guards, not behaviour tests. The observable
/// behaviour lives on the server (`ReminderStoreTests` proves the store
/// and the routes), and what these pin is the **wiring** — the client must
/// actually offer the setting, actually store it, actually list it, and
/// actually re-arm the notification. A set that never fires, or a list
/// nobody can find, is the exact failure this feature exists to remove.
final class ReminderWiringTests: XCTestCase {

    // MARK: - Setting a reminder

    /// The message detail view must offer 「设提醒」.
    ///
    /// This is where the user is looking when they decide a mail needs
    /// following up, so this is where the button belongs. A reminder that
    /// can only be set from a panel the user has to go looking for is a
    /// reminder most people never set.
    func test_theDetailViewOffersToSetAReminder() throws {
        let source = try ViewSource.read("MessageDetailView")
        XCTAssertTrue(
            source.contains("l10n.reminderSet"),
            "the message detail view has no 「设提醒」 entry"
        )
        XCTAssertTrue(
            source.contains("ReminderSheet("),
            "the 「设提醒」 entry does not open the reminder sheet"
        )
    }

    /// The sheet must be told **which** mail it is about.
    ///
    /// A sheet that opened without the remote id would set a reminder the
    /// user could never act on, and one that opened with the wrong id
    /// would set a reminder on a *different* mail — the worst kind of
    /// bug, because it looks like it worked.
    func test_theReminderSheetIsToldWhichMailItIsAbout() throws {
        let source = try ViewSource.read("MessageDetailView")
        let sheetStart = try XCTUnwrap(
            source.range(of: "ReminderSheet("),
            "the reminder sheet is never presented"
        )
        let sheet = ViewSource.code(after: sheetStart.lowerBound, in: source, limit: 400)
        XCTAssertTrue(
            sheet.contains("remoteId:"),
            "the sheet must be told the mail's remote id, or it reminds about the wrong thing"
        )
        XCTAssertTrue(
            sheet.contains("accountId:"),
            "the sheet must be told the account, or it writes into another mailbox"
        )
    }

    /// The advice strip must offer the reminder for a "remind" suggestion.
    ///
    /// The AI's 「建议提醒」 used to be a dead end: the row said "you should
    /// be reminded" and the only thing the user could do was scroll past
    /// it. The suggestion now has to be actionable — that is what makes
    /// the model a participant in the workflow instead of a decoration.
    func test_theAdviceStripOffersTheReminderForARemindSuggestion() throws {
        let source = try ViewSource.read("RowAdviceStrip")
        XCTAssertTrue(
            source.contains("advice.action == .remind"),
            "the 「设提醒」 button must appear only for a 'remind' suggestion"
        )
        XCTAssertTrue(
            source.contains("l10n.reminderSet"),
            "the advice strip has no 「设提醒」 button"
        )
    }

    // MARK: - The list

    /// The reminder list must be reachable.
    ///
    /// A reminder that can be set and never seen is half a feature: the
    /// user presses 「设提醒」, the app says 「设好了」, and then the moment
    /// arrives and nothing on screen says "this is what you set".
    func test_theReminderListIsReachable() throws {
        let root = try ViewSource.read("RootView")
        XCTAssertTrue(
            root.contains("RemindersSheet()"),
            "the reminder list is never presented"
        )
        XCTAssertTrue(
            root.contains("showReminders = true"),
            "nothing opens the reminder list"
        )
        // The command palette is the power-user path; a feature that only
        // lives behind a hidden toolbar menu is invisible to the people
        // who use the app the fastest.
        let palette = try ViewSource.read("CommandPaletteView")
        XCTAssertTrue(
            palette.contains("onShowReminders"),
            "the command palette has no 「我的提醒」 row"
        )
        // And the app's own menu bar, which is where a macOS user looks.
        // The app's own menu bar lives in `Platform/`, not `Views/` — the
        // menu is a `Commands` type, and SwiftUI's `Commands` are not
        // views.
        let commands = try String(
            contentsOf: ViewSource.url(under: "Platform", "LagoonAppCommands"),
            encoding: .utf8
        )
        XCTAssertTrue(
            commands.contains(".showReminders"),
            "the 邮件 menu has no 「我的提醒」 item"
        )
    }

    /// The list must actually read the reminders and show the mail.
    ///
    /// A list of times and ids is a list the user has to decode: "10月8日
    /// 09:00" next to *what*? The subject has to be on the row.
    func test_theReminderListShowsTheMailItPointsAt() throws {
        let source = try ViewSource.read("RemindersSheet")
        XCTAssertTrue(
            source.contains("api.fetchReminders("),
            "the list never reads the reminders"
        )
        XCTAssertTrue(
            source.contains("reminder.subject"),
            "the row does not show the mail's subject — a reminder you cannot tie to a mail is a nag"
        )
    }

    /// 「完成」 must dismiss, and it must be recoverable.
    ///
    /// A dismissal that cannot be undone is a delete wearing a nicer hat:
    /// the user mis-clicks once and the reminder is gone for good.
    func test_theReminderListCanDismissAndRestore() throws {
        let source = try ViewSource.read("RemindersSheet")
        XCTAssertTrue(
            source.contains("api.dismissReminder("),
            "the list cannot dismiss a reminder"
        )
        XCTAssertTrue(
            source.contains("dismissed: false"),
            "a dismissed reminder cannot be restored — a mis-click would be permanent"
        )
    }

    // MARK: - The notification

    /// Setting a reminder must arm the notification.
    ///
    /// The row is the truth; the notification is the delivery. A stored
    /// row that never produces a notification is a to-do list, not a
    /// reminder — and the user's whole reason for setting it was to be
    /// interrupted at the right moment.
    func test_settingAReminderArmsTheNotification() throws {
        let source = try ViewSource.read("ReminderSheet")
        XCTAssertTrue(
            source.contains("MailNotificationService.shared.scheduleReminder("),
            "the saved reminder never arms its notification"
        )
        XCTAssertTrue(
            source.contains("api.setReminder("),
            "the sheet never stores the reminder"
        )
    }

    /// The system forgets scheduled notifications, so the app must rebuild
    /// them from its own store on every launch.
    ///
    /// A reboot, a logout, a reinstall — and the reminder never fires. The
    /// user set it, the app said 「设好了」, and the moment came and went in
    /// silence. This is the difference between a reminder and a row.
    func test_theRemindersAreReArmedOnLaunch() throws {
        // `LagoonApp` is the `@main` type and sits at the root of
        // `Sources/Lagoon/`, not in a subdirectory.
        let app = try String(
            contentsOf: ViewSource.url(under: "", "LagoonApp"),
            encoding: .utf8
        )
        XCTAssertTrue(
            app.contains("armPending("),
            "nothing re-arms the reminder notifications on launch"
        )

        let scheduler = try String(
            contentsOf: ViewSource.url(under: "Platform", "ReminderScheduler"),
            encoding: .utf8
        )
        XCTAssertTrue(
            scheduler.contains("cancelAllReminders()"),
            "the system's queue must be cleared before the rebuild, or a deleted reminder still fires"
        )
        XCTAssertTrue(
            scheduler.contains("api.fetchReminders("),
            "the re-arm does not read the app's own store — the store is the truth"
        )
    }

    /// Dismissing a reminder must cancel its notification.
    ///
    /// A reminder the user marked done that still pops up is worse than
    /// one that was never set: it teaches the user that the app's
    /// 「完成」 is a lie.
    func test_dismissingAReminderCancelsItsNotification() throws {
        let source = try ViewSource.read("RemindersSheet")
        XCTAssertTrue(
            source.contains("MailNotificationService.shared.cancelReminder("),
            "a dismissed reminder keeps its notification and still pops up"
        )
    }

    // MARK: - The promise the AI makes

    /// The copy must not say the AI sets reminders.
    ///
    /// The advisory-only constitution: the AI never acts on its own. A
    /// 「建议提醒」 that quietly scheduled a notification for a moment the
    /// user never chose would be the AI acting on its own, and would cost
    /// the user their trust in every other suggestion.
    func test_theCopySaysTheAIIsOnlySuggesting() throws {
        let l10n = try String(
            contentsOf: ViewSource.url(under: "Localization", "L10n"),
            encoding: .utf8
        )
        let declaration = try XCTUnwrap(
            l10n.range(of: "public var reminderHelp: String"),
            "the reminder help line is gone"
        )
        let line = l10n[declaration.lowerBound...].prefix(200)
        XCTAssertTrue(
            line.contains("AI 只建议"),
            "the help line must say the AI only suggests — the user sets the time, always"
        )
    }

    /// The reminder sheet must default to a time the user can see, and it
    /// must not be the past.
    ///
    /// A reminder due in the past is a reminder that can never fire, and
    /// the server refuses it — so the default has to be a real future
    /// moment.
    func test_theDefaultReminderTimeIsInTheFuture() throws {
        let due = ReminderSheet.defaultDueAt(now: Date())
        XCTAssertGreaterThan(
            due.timeIntervalSinceNow, 0,
            "the default reminder time is in the past — the server refuses it and the sheet cannot save"
        )
        // Tomorrow morning, not "in one hour": an hour is too eager and a
        // week is a filing cabinet.
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())
        let components = Calendar.current.dateComponents([.year, .month, .day], from: due)
        let expected = Calendar.current.dateComponents([.year, .month, .day], from: tomorrow!)
        XCTAssertEqual(components.year, expected.year)
        XCTAssertEqual(components.month, expected.month)
        XCTAssertEqual(components.day, expected.day)
    }
}
