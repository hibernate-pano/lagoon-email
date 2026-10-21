import XCTest
import Foundation
import LagoonKit
@testable import Lagoon

/// The reminder must be a promise the app can keep.
///
/// ## The bug these guard
///
/// The app said 「你设的提醒会在到点时通知你」 — your reminders notify you
/// when they are due — and the copy was true only when three things
/// lined up, none of which the user could see:
///
/// 1. The notification *preference* was on. It defaulted to **off**, so
///    a fresh install never rang.
/// 2. The system's *authorization* was granted. And it was only ever
///    read in the Settings window, so on every fresh launch the app
///    believed the answer was "not permitted" — and armed nothing, even
///    for a user who had turned notifications on.
/// 3. The `scheduleReminder` guard returned **silently**. The sheet
///    then reported 「设好了」 and the sheet closed, and at the due time
///    nothing happened, with no message anywhere.
///
/// The user was told the product would do something, and the product
/// did not do it and did not say so. A product that promises a reminder
/// and does not deliver it teaches the user to distrust every other
/// thing it says.
///
/// These are source-level guards, not behaviour tests: the observable
/// behaviour lives in the system (`UNUserNotificationCenter`), which a
/// unit test cannot reach. What these pin is the **wiring** — that the
/// sheet asks, that the failure reaches a view, and that a dismissed
/// reminder cannot leave a notification behind.
final class ReminderDeliveryHonestyTests: XCTestCase {

    // MARK: - The user finds out at the moment they set it

    /// Setting a reminder must have a path that tells the user the
    /// reminder will not be delivered.
    ///
    /// The promise is discharged by the operating system, minutes or
    /// hours later, with the app closed. The app cannot show a banner at
    /// that moment — the user is not looking at it, and by then the
    /// moment has passed. So the *only* moment the user can be told is
    /// at the moment they set the reminder, and the sheet has to have
    /// that path.
    func test_settingAReminderHasAUserVisibleDeliveryPath() throws {
        let source = try ViewSource.read("ReminderSheet")

        // The sheet must read the system's answer before it says
        // anything about delivery.
        XCTAssertTrue(
            source.contains("refreshAuthorization()"),
            "the sheet never asks the system whether notifications are allowed, "
                + "so it cannot know whether the reminder will ring"
        )

        // And it must have a way to ask the system for permission.
        XCTAssertTrue(
            source.contains("requestAuthorization()"),
            "the sheet has no way to ask for the permission the reminder needs"
        )

        // The warning has to be in the sheet, and it has to be visible
        // when the reminder cannot be delivered.
        XCTAssertTrue(
            source.contains("l10n.reminderNotificationsOff"),
            "the sheet never says the reminder will not ring"
        )
        XCTAssertTrue(
            source.contains("canDeliverReminder"),
            "the sheet does not ask whether the reminder can be delivered"
        )
    }

    /// The warning must be **shown**, not merely present in the file.
    ///
    /// A string that is defined and never rendered is a string in a file.
    /// This pins the render: the sheet's body has to contain a
    /// conditional that draws the warning, and that conditional has to
    /// be gated on the delivery question — a warning that is always on
    /// is as dishonest as one that is never on.
    func test_theDeliveryWarningIsActuallyRendered() throws {
        let source = try ViewSource.read("ReminderSheet")
        let body = try XCTUnwrap(
            source.range(of: "var body: some View"),
            "the sheet has no body"
        )
        // The body is long; the window is generous but bounded, so the
        // assertion cannot be satisfied by a mention in a distant
        // helper.
        let rendered = ViewSource.code(after: body.lowerBound, in: source, limit: 6000)
        XCTAssertTrue(
            rendered.contains("deliveryWarning"),
            "the sheet's body never draws the delivery warning"
        )
        // The gate has to depend on the delivery question, and it has to
        // be a real condition rather than a constant.
        XCTAssertTrue(
            rendered.contains("shouldWarnAboutDelivery"),
            "the delivery warning is not gated on whether the reminder can be delivered"
        )
        let gate = try XCTUnwrap(
            source.range(of: "private var shouldWarnAboutDelivery: Bool"),
            "the sheet has no delivery gate"
        )
        let gateBody = ViewSource.code(after: gate.lowerBound, in: source, limit: 300)
        XCTAssertTrue(
            gateBody.contains("canDeliverReminder"),
            "the delivery gate does not ask whether the reminder can be delivered"
        )
        XCTAssertFalse(
            gateBody.contains("return false"),
            "the delivery gate is hard-coded off — the warning can never appear"
        )
    }

    /// The sheet must have a button that asks for the permission.
    ///
    /// A warning with no way out is a dead end: the user is told the
    /// reminder will not ring and is given nothing to do about it. The
    /// sheet therefore has to offer the request, and the request has to
    /// be **reachable** — the button is drawn by the warning view, and
    /// the warning view is drawn by the body. Both links are pinned
    /// here, because a button in a view nobody renders is a button that
    /// does not exist.
    func test_theSheetOffersAWayToAskForThePermission() throws {
        let source = try ViewSource.read("ReminderSheet")

        // The button lives in the warning view.
        let warning = try XCTUnwrap(
            source.range(of: "private var deliveryWarning: some View"),
            "the sheet has no delivery warning view"
        )
        let warningBody = ViewSource.code(after: warning.lowerBound, in: source, limit: 3000)
        XCTAssertTrue(
            warningBody.contains("requestNotificationPermission()"),
            "the delivery warning offers no way to ask for the permission"
        )
        XCTAssertTrue(
            source.contains("l10n.reminderEnableNotifications"),
            "the sheet has no label for the button that asks for the permission"
        )

        // And the warning view is drawn by the body.
        let body = try XCTUnwrap(
            source.range(of: "var body: some View"),
            "the sheet has no body"
        )
        let rendered = ViewSource.code(after: body.lowerBound, in: source, limit: 6000)
        XCTAssertTrue(
            rendered.contains("deliveryWarning"),
            "the sheet's body never draws the delivery warning"
        )

        // And the request itself really asks the system.
        let request = try XCTUnwrap(
            source.range(of: "private func requestNotificationPermission() async"),
            "the sheet has no permission request"
        )
        let requestBody = ViewSource.code(after: request.lowerBound, in: source, limit: 600)
        XCTAssertTrue(
            requestBody.contains("requestAuthorization()"),
            "the permission request does not ask the system"
        )
    }

    /// The sheet must not report success it has not checked.
    ///
    /// The old code called `scheduleReminder` — which returned `Void`
    /// and returned *early* on every guard — and then reported 「设好了」
    /// and dismissed the sheet. The outcome was never looked at, so the
    /// sheet reported a success for a reminder that would never ring.
    ///
    /// The delivery has to come back as a value, and the sheet has to
    /// branch on it.
    func test_theSheetReportsWhatActuallyHappened() throws {
        let source = try ViewSource.read("ReminderSheet")

        // The outcome is captured, not discarded.
        XCTAssertTrue(
            source.contains("let delivery = MailNotificationService.shared.scheduleReminder("),
            "the sheet does not look at what scheduling actually returned"
        )
        // And it branches on the outcome.
        XCTAssertTrue(
            source.contains("case .scheduled:"),
            "the sheet does not branch on the delivery outcome"
        )
        XCTAssertTrue(
            source.contains("savedButNotArmed = true"),
            "the sheet does not record that the reminder was saved but will not ring"
        )
        XCTAssertTrue(
            source.contains("l10n.reminderSavedNotArmed"),
            "the sheet never tells the user the reminder will not ring"
        )
    }

    /// The scheduler must return what happened too, and count the
    /// reminders it could not arm.
    ///
    /// `armedCount` alone cannot tell the user anything: "12 armed" and
    /// "12 armed, 3 more that will never ring" are different facts, and
    /// only the second one is actionable.
    func test_theSchedulerCountsTheRemindersItCouldNotArm() throws {
        let source = try String(
            contentsOf: ViewSource.url(under: "Platform", "ReminderScheduler"),
            encoding: .utf8
        )
        XCTAssertTrue(
            source.contains("blockedCount"),
            "the scheduler does not count the reminders it could not arm — "
                + "the user cannot be told how many of their reminders will not ring"
        )
        XCTAssertTrue(
            source.contains("blockedReason"),
            "the scheduler does not keep the reason it could not arm, "
                + "so the user cannot be told what to do about it"
        )
    }

    // MARK: - The failure reaches a view

    /// `ReminderScheduler.lastError` must be read by a view.
    ///
    /// The property was published with a comment saying a silent failure
    /// "is exactly the failure this whole class exists to prevent" — and
    /// **nothing read it**. A published property nobody reads is a
    /// comment about a feature that does not exist.
    func test_theArmingFailureReachesAView() throws {
        let source = try ViewSource.read("RemindersSheet")
        XCTAssertTrue(
            source.contains("scheduler.lastError"),
            "the reminders panel never reads the scheduler's error — "
                + "a reminder that could not be armed is invisible to the user"
        )
        // It has to become a banner, not a log line: the app's banner
        // pattern is the one way a failure is shown.
        XCTAssertTrue(
            source.contains("ErrorBanner("),
            "the arming failure is not shown in a banner"
        )
    }

    /// The panel must also say how many reminders the system is holding.
    ///
    /// A row on the list is not a delivery. The user goes to this panel
    /// to answer "what is waiting" — and a reminder that is on the list
    /// but was never handed to the system is waiting for nothing.
    func test_thePanelShowsTheArmedCountAndTheBlockedCount() throws {
        let source = try ViewSource.read("RemindersSheet")
        XCTAssertTrue(
            source.contains("scheduler.armedCount"),
            "the panel never says how many reminders are actually armed"
        )
        XCTAssertTrue(
            source.contains("scheduler.blockedCount"),
            "the panel never says how many reminders will not ring"
        )
        XCTAssertTrue(
            source.contains("l10n.reminderArmedCount("),
            "the armed count is never shown to the user"
        )
    }

    /// The launch-time re-arm must read the system's answer.
    ///
    /// This is the second, deeper half of the bug: the authorization was
    /// only ever read in the Settings window, so on every fresh launch
    /// the app thought it was not allowed to post. The re-arm then
    /// armed **nothing** — for a user who *had* turned notifications on.
    /// The reminder was on the list, looked fine, and never rang.
    func test_theLaunchReArmReadsTheSystemsAnswer() throws {
        let source = try String(
            contentsOf: ViewSource.url(under: "Platform", "ReminderScheduler"),
            encoding: .utf8
        )
        let arm = try XCTUnwrap(
            source.range(of: "public func armPending("),
            "the scheduler has no arming pass"
        )
        let body = ViewSource.code(after: arm.lowerBound, in: source, limit: 2000)
        XCTAssertTrue(
            body.contains("refreshAuthorization()"),
            "the re-arm does not read the system's answer, so it arms nothing "
                + "for a user who enabled notifications and launched the app"
        )
    }

    // MARK: - A dismissed reminder leaves nothing behind

    /// Dismissing a reminder must cancel its notification.
    ///
    /// A reminder the user marked done that still pops up is worse than
    /// one that was never set: it teaches the user that the app's
    /// 「完成」 is a lie.
    ///
    /// The cancel has to be in the *dismiss* path, not somewhere else
    /// in the file: a cancel that happens on some other code path
    /// leaves this one ringing.
    func test_dismissingAReminderCancelsItsNotification() throws {
        let source = try ViewSource.read("RemindersSheet")
        let dismiss = try XCTUnwrap(
            source.range(of: "private func dismiss("),
            "the panel cannot dismiss a reminder"
        )
        // The window ends where the next function begins, so a cancel
        // in a *different* function cannot satisfy this.
        let restore = try XCTUnwrap(
            source.range(of: "private func restore("),
            "the panel cannot restore a reminder"
        )
        let body = ViewSource.code(
            after: dismiss.lowerBound,
            in: source[dismiss.lowerBound..<restore.lowerBound],
            limit: 2000
        )
        XCTAssertTrue(
            body.contains("cancelReminder(id:"),
            "a dismissed reminder keeps its notification and still pops up"
        )
    }

    /// Deleting a reminder must cancel its notification too.
    func test_deletingAReminderCancelsItsNotification() throws {
        let source = try ViewSource.read("RemindersSheet")
        let delete = try XCTUnwrap(
            source.range(of: "private func delete("),
            "the panel cannot delete a reminder"
        )
        // The delete is the last function in the file, so the window
        // runs to the end.
        let body = ViewSource.code(after: delete.lowerBound, in: source, limit: 2000)
        XCTAssertTrue(
            body.contains("cancelReminder(id:"),
            "a deleted reminder keeps its notification and still pops up"
        )
    }

    /// The notification service must offer a way to cancel by mail id.
    ///
    /// The system's queue is keyed by the reminder's numeric id, and a
    /// caller that only knows the mail cannot use it. The map between
    /// the two is what makes "cancel the reminder about this mail"
    /// possible without a round trip.
    func test_theServiceCanCancelTheRemindersAboutAMail() throws {
        let source = try String(
            contentsOf: ViewSource.url(under: "Platform", "MailNotificationService"),
            encoding: .utf8
        )
        XCTAssertTrue(
            source.contains("cancelReminders(forRemoteId"),
            "the service cannot cancel a reminder by the mail it is about"
        )
    }

    /// Throwing the mail away must cancel the reminder's notification.
    ///
    /// The server hides a reminder whose mail is in the Trash from the
    /// list, and a hard delete takes the row away with the foreign key
    /// — but the *notification* lives in the system's queue, and the
    /// system does not know the mail is gone. The client is the only
    /// place that can close that gap, and this is where the mail goes.
    ///
    /// The cancel has to be inside the delete path: a call somewhere
    /// else in the file would not fire when the mail is thrown away.
    func test_throwingTheMailAwayCancelsTheReminderNotification() throws {
        // The detail view's delete.
        let detail = try ViewSource.read("MessageDetailView")
        let detailDelete = try XCTUnwrap(
            detail.range(of: "private func deleteMessage() async"),
            "the detail view cannot delete a message"
        )
        let detailBody = ViewSource.code(
            after: detailDelete.lowerBound, in: detail, limit: 1500
        )
        XCTAssertTrue(
            detailBody.contains("cancelReminders(forRemoteId:"),
            "the detail view deletes a mail without cancelling the reminder's "
                + "notification — the system will still ring for mail the user threw away"
        )

        // The list view's delete, and its two hard-delete paths.
        let list = try ViewSource.read("MessageListView")
        for (anchor, label) in [
            ("private func delete(_ m: MessageHeader) async", "moves a mail to the trash"),
            ("private func purge(_ m: MessageHeader) async", "permanently deletes a mail"),
            ("private func emptyTrashNow() async", "empties the trash"),
        ] {
            let start = try XCTUnwrap(
                list.range(of: anchor),
                "the list view has no path that \(label)"
            )
            let body = ViewSource.code(after: start.lowerBound, in: list, limit: 2000)
            XCTAssertTrue(
                body.contains("cancelReminders(forRemoteId:"),
                "the list view \(label) without cancelling the reminder's "
                    + "notification — the system will still ring for mail the user threw away"
            )
        }
    }

    // MARK: - The copy agrees with the behaviour

    /// The promise must state its condition.
    ///
    /// The delivery depends on the system's permission, and the app
    /// cannot grant that on the user's behalf. So the sentence has to
    /// name the condition — otherwise it is a promise the app breaks
    /// every time the user has not turned notifications on.
    func test_theReminderCopyStatesTheConditionItDependsOn() throws {
        let l10n = try String(
            contentsOf: ViewSource.url(under: "Localization", "L10n"),
            encoding: .utf8
        )
        for key in ["public var reminderHelp: String", "public var reminderEmptyHelp: String"] {
            let declaration = try XCTUnwrap(
                l10n.range(of: key),
                "the reminder copy is gone: \(key)"
            )
            let line = l10n[declaration.lowerBound...].prefix(400)
            XCTAssertTrue(
                line.contains("开启系统通知") || line.contains("system notifications on"),
                "\(key) must state the condition it depends on — the system "
                    + "delivers the reminder, and only if the user allowed it"
            )
        }
    }

    /// The copy must not promise delivery without qualification.
    ///
    /// This is the regression check on the exact string that made the
    /// promise: 「到点时系统会通知你」 with no condition attached.
    func test_theReminderCopyDoesNotPromiseUnqualifiedDelivery() {
        let zh = L10n(language: .zhHans)
        let en = L10n(language: .english)
        for (name, text) in [
            ("reminderHelp", zh.reminderHelp),
            ("reminderEmptyHelp", zh.reminderEmptyHelp),
            ("reminderHelp (en)", en.reminderHelp),
            ("reminderEmptyHelp (en)", en.reminderEmptyHelp),
        ] {
            XCTAssertFalse(
                text.contains("到点时系统会通知你"),
                "\(name) promises the system will notify the user, with no "
                    + "condition — the promise is broken whenever notifications are off"
            )
            XCTAssertFalse(
                text.contains("will notify you when it is due"),
                "\(name) promises delivery without naming the condition"
            )
        }
    }
}
