import SwiftUI
import LagoonKit

/// Set a reminder for one message.
///
/// ## Why the user sets the time, and the AI does not
///
/// The AI can *suggest* a reminder ("this mail says the deadline is
/// Friday"), and it quotes the date phrase out of the mail. But the moment
/// the user confirms, the time is **theirs**: a suggestion that quietly
/// schedules a notification for a moment the user never chose is the AI
/// acting on its own, which the advisory-only constitution forbids — and
/// the user's trust in every other suggestion with it.
///
/// So the sheet opens on a time the user can see and change, pre-seeded
/// from the mail's own deadline phrase when the model found one, and the
/// user presses "Set reminder" to make it real.
///
/// ## Why the sheet asks for notification permission
///
/// A reminder is delivered by the operating system, minutes or hours
/// later, with the app closed. The app cannot show a banner at that
/// moment — the user is not looking at it, and by then the moment has
/// passed. So the only place the promise can be kept or broken is
/// *here*, at the moment the user says "remind me about this".
///
/// So the sheet does not accept a reminder it cannot deliver. It asks
/// for the system's permission as part of setting the reminder, with the
/// reason stated in the same breath, and if the permission cannot be
/// granted the user is told that the reminder will not ring **before**
/// they press the button — not at the due time, in silence.
///
/// The preference is never turned on behind the user's back: the system
/// prompt is the user answering, and the app's own switch follows that
/// answer rather than the other way round.
struct ReminderSheet: View {
    let accountId: UUID
    let remoteId: String
    /// The mail's subject, so the sheet says which mail the reminder is
    /// about.
    let subject: String?
    /// The model's own deadline phrase, when it found one. Shown as a hint
    /// next to the picker — never applied silently.
    let dueText: String?
    /// Called after the reminder is stored, with the stored row.
    let onSet: (Reminder) -> Void

    @Environment(\.l10n) private var l10n
    @Environment(\.dismiss) private var dismiss

    @State private var dueAt: Date
    @State private var note: String = ""
    @State private var isSaving = false
    @State private var error: String?

    /// The reminder was stored, but the system will not ring it.
    ///
    /// The reminder is not thrown away — the user asked for it, and it is
    /// on their list. But it cannot do the one thing a reminder is for,
    /// and saying so is the difference between a product the user can
    /// trust and one that goes quiet at the moment it promised not to.
    @State private var savedButNotArmed = false
    /// The user is being asked for the system's permission right now.
    @State private var isRequestingPermission = false

    /// The notification service, observed so the sheet redraws when the
    /// system's answer changes.
    @StateObject private var notifications = MailNotificationService.shared

    private let api = APIClient.shared

    init(
        accountId: UUID,
        remoteId: String,
        subject: String? = nil,
        dueText: String? = nil,
        onSet: @escaping (Reminder) -> Void
    ) {
        self.accountId = accountId
        self.remoteId = remoteId
        self.subject = subject
        self.dueText = dueText
        self.onSet = onSet
        // The default is tomorrow morning: far enough away that the user
        // can think about it, near enough that it is worth setting. An
        // hour is too eager and a week is a filing cabinet.
        _dueAt = State(initialValue: ReminderSheet.defaultDueAt())
    }

    /// Tomorrow at 9:00.
    static func defaultDueAt(now: Date = Date()) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(l10n.reminderTitle, systemImage: "bell")
                    .font(.headline)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(l10n.dismiss)
            }

            if let subject, !subject.isEmpty {
                Text(subject)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(l10n.reminderWhen)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                DatePicker(
                    "",
                    selection: $dueAt,
                    in: Date()...,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .datePickerStyle(.field)
                .labelsHidden()
                .accessibilityLabel(l10n.reminderWhen)
                // The model's own phrase, shown as a hint — and only as a
                // hint. It is the mail's wording, not a date the app
                // computed, and it is never applied without the user.
                if let dueText, !dueText.isEmpty {
                    Label(dueText, systemImage: "quote.bubble")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            HStack(spacing: 8) {
                ForEach(Self.quickPicks, id: \.title) { pick in
                    Button(pick.title) {
                        dueAt = pick.value()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(l10n.reminderNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(l10n.reminderNotePlaceholder, text: $note)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(l10n.reminderNote)
            }

            Text(l10n.reminderHelp)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            // The delivery warning, shown *before* the user commits.
            //
            // The reminder's whole value is that it reaches the user later,
            // when the app is closed. If the system cannot ring it, the
            // user has to know now — at the moment they are looking at the
            // sheet and can still do something about it.
            if shouldWarnAboutDelivery {
                deliveryWarning
            }

            if savedButNotArmed {
                Text(l10n.reminderSavedNotArmed)
                    .font(.callout)
                    .foregroundStyle(LagoonTheme.Severity.warning.color)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button(l10n.cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if savedButNotArmed {
                    // The reminder is already stored. The only thing left
                    // to do is close the sheet and let the user go and
                    // turn the notification on — the banner in the
                    // reminders panel is waiting for them there.
                    Button(l10n.reminderAcknowledge) { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving || isRequestingPermission {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(l10n.reminderSave)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving || isRequestingPermission)
                }
            }
        }
        .padding(20)
        .frame(width: LagoonSheetSize.compact.width)
        .task {
            // The system's answer to "may this app post notifications?"
            // is not known until the system is asked, and asking does not
            // prompt. Without this the sheet would say "notifications are
            // off" to a user who had already turned them on.
            await notifications.refreshAuthorization()
            hasReadPermission = true
        }
    }

    /// The warning about delivery, when the system cannot ring it.
    ///
    /// It is not a banner: the sheet is a *decision*, and a decision
    /// interrupted by a red strip reads as a failure that already
    /// happened. This is a condition the user can still act on, so it is
    /// drawn in the theme's warning colour, with the way out next to it.
    @ViewBuilder
    private var deliveryWarning: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(l10n.reminderNotificationsOff, systemImage: "bell.slash")
                .font(.callout)
                .foregroundStyle(LagoonTheme.Severity.warning.color)
            Text(l10n.reminderNotificationsOffHelp)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if notifications.authorization == .denied {
                // The system has already refused. Asking again does
                // nothing, so the way forward is System Settings — and
                // saying so is better than a button that fails silently.
                Text(l10n.reminderNotificationsDeniedHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(l10n.notificationsOpenSettings) {
                    MailNotificationService.openSystemNotificationSettings()
                }
                .buttonStyle(.link)
                .font(.caption)
            } else {
                Button {
                    Task { await requestNotificationPermission() }
                } label: {
                    if isRequestingPermission {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(l10n.reminderEnableNotifications)
                    }
                }
                .buttonStyle(.link)
                .font(.caption)
                .disabled(isRequestingPermission)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LagoonTheme.Severity.warning.color.opacity(0.12))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(LagoonTheme.Severity.warning.color)
                .frame(width: 3)
        }
        .accessibilityElement(children: .contain)
    }

    /// Whether the sheet has to warn that the reminder will not ring.
    ///
    /// The permission has to be read before the sheet can say anything
    /// true about it, so this waits until the first read has happened: a
    /// warning shown against an unknown answer is a guess.
    private var shouldWarnAboutDelivery: Bool {
        hasCheckedPermission && !notifications.canDeliverReminder
    }

    /// Whether the system's answer is known yet.
    ///
    /// `.notDetermined` is the *initial* value of the published
    /// authorization, and it is also the system's real answer for a user
    /// who has never been asked. The two are told apart by a separate
    /// flag, because "we have not looked yet" and "the system says no"
    /// must not draw the same conclusion.
    private var hasCheckedPermission: Bool {
        hasReadPermission
    }

    /// Set once the sheet has read the system's answer.
    @State private var hasReadPermission = false

    /// The quick picks. Three, not more: a row of eight buttons is a
    /// control panel, and a reminder is a decision the user makes once.
    private struct QuickPick {
        let title: String
        let value: () -> Date
    }

    private static var quickPicks: [QuickPick] {
        let l10n = L10n.current
        return [
            QuickPick(title: l10n.reminderInThreeHours) {
                Date().addingTimeInterval(3 * 60 * 60)
            },
            QuickPick(title: l10n.reminderTomorrowMorning) {
                defaultDueAt()
            },
            QuickPick(title: l10n.reminderNextMonday) {
                nextMondayMorning()
            },
        ]
    }

    /// Next Monday at 9:00 — the case that is genuinely awkward to pick
    /// out of a date picker, and the one that comes up most often in
    /// "I'll deal with it after the weekend" mail.
    static func nextMondayMorning(now: Date = Date()) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        // `weekday` is 1-based and Sunday is 1; Monday is 2.
        let daysUntilMonday = (9 - calendar.component(.weekday, from: now)) % 7
        let days = daysUntilMonday == 0 ? 7 : daysUntilMonday
        let monday = calendar.date(byAdding: .day, value: days, to: now) ?? now
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: monday) ?? monday
    }

    /// Asks the system for permission to post notifications.
    ///
    /// The prompt is the user answering, so the app does not decide for
    /// them: if they say no, the preference stays off and the sheet says
    /// the reminder will not ring. The app's own switch follows the
    /// system's answer — `requestAuthorization` only turns the preference
    /// on when the system says yes.
    private func requestNotificationPermission() async {
        isRequestingPermission = true
        defer { isRequestingPermission = false }
        await notifications.requestAuthorization()
    }

    /// Stores the reminder and arms its notification.
    ///
    /// ## Why the order is: store, then arm, then say
    ///
    /// The row is the truth; the notification is the delivery. But the
    /// delivery is not guaranteed — the system may have no permission,
    /// and only the *outcome* of arming says so. So the sheet stores the
    /// row, arms it, and then reports what actually happened, instead of
    /// reporting a success it has not checked.
    private func save() async {
        // The picker already forbids the past; this catches the race where
        // the sheet sat open across midnight.
        guard dueAt > Date() else {
            error = l10n.reminderDueInThePast
            return
        }
        isSaving = true
        error = nil
        do {
            let reminder = try await api.setReminder(
                remoteId: remoteId,
                dueAt: dueAt,
                note: note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil
                    : note,
                accountId: accountId
            )
            // The notification is armed here, from the row the server
            // returned. The row is the truth; the notification is the
            // delivery.
            let delivery = MailNotificationService.shared.scheduleReminder(
                id: reminder.id,
                dueAt: reminder.dueAt,
                subject: subject,
                remoteId: reminder.remoteId
            )
            onSet(reminder)
            switch delivery {
            case .scheduled:
                dismiss()
            case .dueInThePast:
                // The moment passed while the sheet was open. The row is
                // stored, but a notification for a moment that has been
                // would fire immediately — a pop-up nobody asked for.
                // The reminder still shows on the list as overdue.
                savedButNotArmed = true
            default:
                // The system will not ring it. The reminder is stored and
                // the user is told so *now*, in the sheet, with the sheet
                // still open — not at the due time, in silence.
                savedButNotArmed = true
            }
        } catch {
            self.error = l10n.sendFailed + error.lagoonUIMessage
        }
        isSaving = false
    }
}
