import SwiftUI
import LagoonKit

/// The reminders the user set for themselves.
///
/// ## Why this list exists
///
/// A reminder that can only be set and never seen is half a feature: the
/// user presses 「设提醒」, the app says 「设好了」, and then the moment
/// arrives and nothing on screen says "this is what you set". A to-do
/// list you cannot come back to is a promise with no address.
///
/// This is that address. It is the list of everything still waiting, with
/// the mail's subject next to each one — a reminder you cannot tie to a
/// mail is a nag, and a nag is worse than no reminder.
///
/// ## Why "完成" is not a delete
///
/// Dismissing marks the reminder done and keeps the row. Two reasons:
/// the user can mis-click, and "I dismissed this" is information the
/// user may want later. A delete is offered too, for the reminders the
/// user set and then decided were never going to happen.
struct RemindersSheet: View {
    @EnvironmentObject private var accounts: AccountStore
    @Environment(\.l10n) private var l10n
    @Environment(\.dismiss) private var dismiss

    /// The scheduler, observed so the panel can show what the system is
    /// actually holding.
    ///
    /// This is the surface where the user goes to see "what is waiting".
    /// A reminder that could not be armed is exactly the thing they are
    /// looking for, and it is invisible everywhere else: the row is on
    /// the list, it looks fine, and the moment comes and nothing rings.
    @StateObject private var scheduler = ReminderScheduler.shared

    @State private var reminders: [Reminder] = []
    @State private var isLoading = true
    @State private var errorBanner: ErrorBanner?
    /// The reminder being acted on, so the row shows a spinner instead of
    /// a button that can be pressed twice.
    @State private var busyId: Int64?
    /// Whether the dismissed ones are shown too.
    @State private var showDismissed = false
    /// The reminder waiting for the user to confirm its deletion.
    ///
    /// A delete here is a hard delete — the row is destroyed, not marked
    /// done — and it happens in a context menu, which is exactly where a
    /// mis-click lands. The panel's own argument for 「完成」 being
    /// different from a delete is that a mis-click can be recovered; the
    /// delete path used to throw that away.
    @State private var pendingDelete: Reminder?
    /// No account is connected, so there is nothing to remind about.
    @State private var isDisconnected = false

    private let api = APIClient.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            // The standing warning, above the list.
            //
            // It is a strip rather than a banner because it describes a
            // *state*, not a failure: the reminders are saved and they
            // are fine, they just cannot ring while the system is not
            // allowed to. A red banner would train the user to ignore
            // the strip that actually matters.
            if !reminders.isEmpty, scheduler.blockedCount > 0 {
                notArmedStrip
            }
            content
        }
        .noticeBanner($errorBanner)
        .frame(
            width: LagoonSheetSize.standard.width,
            height: LagoonSheetSize.standard.height
        )
        .task { await load() }
        // The delete confirmation. It names the reminder, because "delete
        // this" in a context menu is ambiguous the moment the menu is open
        // over a list of rows that all look alike.
        .confirmationDialog(
            l10n.reminderDeleteConfirmTitle,
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(l10n.reminderDelete, role: .destructive) {
                guard let reminder = pendingDelete else { return }
                pendingDelete = nil
                Task { await delete(reminder) }
            }
            .tint(LagoonTheme.danger)
            Button(l10n.cancel, role: .cancel) { pendingDelete = nil }
        } message: {
            Text(l10n.reminderDeleteConfirmMessage(subject(of: pendingDelete)))
        }
        // The arming failure is the scheduler's own finding, and it is
        // published for exactly this: a view that shows it. The banner
        // slot holds one message at a time, so it is the arming failure
        // that wins over a fetch failure — a fetch failure means the
        // panel is empty, and an empty panel is visible; a silent
        // arming failure means the panel is full of reminders that will
        // never ring, and that is the one the user cannot see.
        .onChange(of: scheduler.lastError) { _, newValue in
            guard let newValue, !newValue.isEmpty else { return }
            errorBanner = ErrorBanner(
                severity: .error,
                title: l10n.reminderNotArmedTitle,
                detail: newValue,
                actionLabel: l10n.retry,
                action: { [self] in await self.rearm() }
            )
        }
        // The same reading, on the way in: the panel can be opened long
        // after the launch that failed to arm, and an `onChange` alone
        // would never fire for a failure that already happened.
        .onAppear { surfaceArmingFailureIfAny() }
    }

    /// Shows the scheduler's arming failure, if it has one.
    private func surfaceArmingFailureIfAny() {
        guard let lastError = scheduler.lastError, !lastError.isEmpty else { return }
        errorBanner = ErrorBanner(
            severity: .error,
            title: l10n.reminderNotArmedTitle,
            detail: lastError,
            actionLabel: l10n.retry,
            action: { [self] in await self.rearm() }
        )
    }

    /// Re-arms the notifications from the store.
    ///
    /// The retry has to rebuild the whole queue, not re-add one reminder:
    /// the system's queue is the thing that went wrong, and the store is
    /// the truth it is rebuilt from.
    private func rearm() async {
        guard let accountId = accounts.accountId else { return }
        await scheduler.armPending(accountId: accountId)
        await load()
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: LagoonMetrics.spaceMD) {
            Label(l10n.reminderTitle, systemImage: "bell")
                .font(.headline)
            Spacer()
            if !reminders.isEmpty {
                Text(l10n.reminderCount(pendingCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button(l10n.refresh) { Task { await load() } }
                .disabled(isLoading)
            // The dismissed ones are hidden by default — this list exists
            // to answer "what is still waiting" — but they must be
            // findable, because "done" and "mis-clicked" look the same
            // afterwards.
            if !reminders.isEmpty || showDismissed {
                Toggle(l10n.reminderShowDismissed, isOn: $showDismissed)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .onChange(of: showDismissed) { _, _ in
                        Task { await load() }
                    }
            }
            if isLoading && !reminders.isEmpty {
                ProgressView().controlSize(.small)
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .padding(LagoonMetrics.spaceXS)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(l10n.dismiss)
        }
        .padding(LagoonMetrics.spaceLG)
    }

    // MARK: - Content

    /// The strip that says the reminders on this list will not ring.
    ///
    /// The way out is on the strip, because the user's next move is a
    /// decision — turn notifications on, or open System Settings — and a
    /// strip that only states a problem makes them go looking for the
    /// settings themselves.
    private var notArmedStrip: some View {
        VStack(alignment: .leading, spacing: LagoonMetrics.spaceSM) {
            HStack(spacing: LagoonMetrics.spaceSM) {
                Image(systemName: "bell.slash")
                    .accessibilityHidden(true)
                Text(l10n.reminderNotArmedTitle)
                    .font(.caption)
                    .bold()
                Spacer(minLength: 0)
            }
            .foregroundStyle(LagoonTheme.Severity.warning.color)
            Text(l10n.reminderNotArmedDetail(scheduler.blockedCount))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(l10n.reminderEnableNotifications) {
                Task { await requestNotificationPermission() }
            }
            .buttonStyle(.link)
            .font(.caption)
        }
        .padding(.horizontal, LagoonMetrics.spaceMD)
        .padding(.vertical, LagoonMetrics.spaceSM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LagoonTheme.Severity.warning.color.opacity(0.12))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(LagoonTheme.Severity.warning.color.opacity(0.4))
                .frame(height: 1)
        }
        .accessibilityElement(children: .contain)
    }

    /// Asks the system for permission, and re-arms if it says yes.
    ///
    /// The permission is the user's answer, not the app's decision: the
    /// app's own switch follows it, and if the user says no the reminders
    /// stay unarmed and the strip stays up.
    private func requestNotificationPermission() async {
        guard await MailNotificationService.shared.requestAuthorization() else { return }
        await rearm()
    }

    @ViewBuilder
    private var content: some View {
        if isLoading, reminders.isEmpty {
            ProgressView().padding(LagoonMetrics.spaceXXL)
        } else if isDisconnected {
            ContentUnavailableView(
                l10n.notConnected,
                systemImage: "envelope.badge",
                description: Text(l10n.notConnectedHint)
            )
        } else if reminders.isEmpty {
            ContentUnavailableView(
                l10n.reminderEmpty,
                systemImage: "bell",
                description: Text(l10n.reminderEmptyHelp)
            )
        } else {
            list
        }
    }

    private var list: some View {
        List {
            Section {
                ForEach(reminders) { reminder in
                    row(for: reminder)
                }
            } footer: {
                VStack(alignment: .leading, spacing: LagoonMetrics.spaceXS) {
                    Text(l10n.reminderHelp)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    // How many the system is actually holding. A row on
                    // the list is not a delivery — this is the delivery,
                    // counted where it is counted.
                    if scheduler.armedCount > 0 {
                        Text(l10n.reminderArmedCount(scheduler.armedCount))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private func row(for reminder: Reminder) -> some View {
        HStack(alignment: .top, spacing: LagoonMetrics.spaceMD) {
            Image(systemName: reminder.isActive ? "bell" : "bell.slash")
                .foregroundStyle(reminder.isActive ? LagoonTheme.brand : .secondary)
                .frame(width: LagoonMetrics.iconColumnWidth)
            VStack(alignment: .leading, spacing: LagoonMetrics.spaceXS) {
                Text(subject(of: reminder))
                    .lineLimit(2)
                HStack(spacing: LagoonMetrics.spaceSM) {
                    Text(l10n.reminderDueAt(reminder.dueAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    // A reminder whose moment has passed and which the user
                    // has not marked done is overdue — and the user needs
                    // to be able to tell that apart from one that is
                    // still waiting. Both are "in the past"; only one of
                    // them is a thing to act on.
                    if reminder.isActive, reminder.dueAt < Date() {
                        Text(l10n.reminderOverdue)
                            .font(.caption2)
                            .foregroundStyle(LagoonTheme.Severity.warning.color)
                    }
                    if !reminder.isActive {
                        Text(l10n.reminderDismissedLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if let note = reminder.note, !note.isEmpty {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            actions(for: reminder)
        }
        .padding(.vertical, LagoonMetrics.spaceXS)
        .opacity(reminder.isActive ? 1 : 0.55)
        .contextMenu {
            // A reminder the user set and then decided was never going to
            // happen needs a way out that is not "mark it done" — that
            // would keep it in the list forever, marked as finished.
            //
            // The delete is a hard delete, so it asks first.
            Button(l10n.reminderDelete, role: .destructive) {
                pendingDelete = reminder
            }
        }
    }

    /// The reminder's subject, or the placeholder when it has none. The
    /// confirmation names the thing being deleted, and a confirmation that
    /// says "this" is not a confirmation.
    private func subject(of reminder: Reminder?) -> String {
        guard let reminder else { return l10n.reminderNoSubject }
        guard let subject = reminder.subject, !subject.isEmpty else {
            return l10n.reminderNoSubject
        }
        return subject
    }

    @ViewBuilder
    private func actions(for reminder: Reminder) -> some View {
        if busyId == reminder.id {
            ProgressView().controlSize(.small)
        } else if reminder.isActive {
            Button(l10n.reminderDismiss) {
                Task { await dismiss(reminder) }
            }
            .buttonStyle(.link)
            .font(.caption)
            .help(l10n.reminderDismissHelp)
        } else {
            Button(l10n.reminderRestore) {
                Task { await restore(reminder) }
            }
            .buttonStyle(.link)
            .font(.caption)
        }
    }

    // MARK: - Data

    private var pendingCount: Int {
        reminders.filter(\.isActive).count
    }

    private func load() async {
        guard let accountId = accounts.accountId else {
            isDisconnected = true
            isLoading = false
            return
        }
        isDisconnected = false
        isLoading = true
        errorBanner = nil
        do {
            reminders = try await api.fetchReminders(
                accountId: accountId,
                includeDismissed: showDismissed
            )
        } catch {
            errorBanner = ErrorBanner(
                severity: .error,
                title: l10n.reminderTitle,
                detail: l10n.loadFailed + error.lagoonUIMessage,
                actionLabel: l10n.retry,
                action: { [self] in await self.load() }
            )
        }
        isLoading = false
    }

    /// Marks a reminder done and cancels its notification.
    ///
    /// The notification is cancelled on the *client*, where it was
    /// scheduled: the server has no idea a notification exists, and a
    /// reminder that the user dismissed but that still pops up is worse
    /// than one that was never set.
    ///
    /// The cancel runs on the **success** path only, and that is
    /// deliberate. If the server refused the dismissal, the row is still
    /// active and the panel still shows it as waiting — so cancelling
    /// the notification there would leave a reminder that is on the list,
    /// looks armed, and never rings. The failure is reported instead,
    /// and the reconciliation pass picks up the case where the server
    /// applied the dismissal but the answer never arrived.
    private func dismiss(_ reminder: Reminder) async {
        guard let accountId = accounts.accountId else { return }
        busyId = reminder.id
        defer { busyId = nil }
        do {
            _ = try await api.dismissReminder(
                id: reminder.id,
                dismissed: true,
                accountId: accountId
            )
            MailNotificationService.shared.cancelReminder(id: reminder.id)
            await load()
        } catch {
            errorBanner = ErrorBanner(
                severity: .error,
                title: l10n.reminderTitle,
                detail: l10n.reminderDismissFailed + error.lagoonUIMessage,
                actionLabel: l10n.retry,
                action: { [self] in await self.dismiss(reminder) }
            )
        }
    }

    /// Brings a dismissed reminder back, and re-arms its notification.
    private func restore(_ reminder: Reminder) async {
        guard let accountId = accounts.accountId else { return }
        busyId = reminder.id
        defer { busyId = nil }
        do {
            let updated = try await api.dismissReminder(
                id: reminder.id,
                dismissed: false,
                accountId: accountId
            )
            // Only re-arm if it is still in the future: scheduling a
            // notification for a moment that has passed would fire it
            // immediately, which is a pop-up nobody asked for.
            if updated.dueAt > Date() {
                MailNotificationService.shared.scheduleReminder(
                    id: updated.id,
                    dueAt: updated.dueAt,
                    subject: updated.subject,
                    remoteId: updated.remoteId
                )
            }
            await load()
        } catch {
            errorBanner = ErrorBanner(
                severity: .error,
                title: l10n.reminderTitle,
                detail: l10n.reminderRestoreFailed + error.lagoonUIMessage,
                actionLabel: l10n.retry,
                action: { [self] in await self.restore(reminder) }
            )
        }
    }

    /// Removes a reminder outright.
    ///
    /// Different from 「完成」: this one is for the reminders the user set
    /// and then decided were never going to happen. A "done" keeps the row
    /// (so a mis-click can be undone); a delete does not.
    ///
    /// The cancel runs on the success path only, for the same reason as
    /// the dismissal: a reminder the server still holds is a reminder
    /// the panel still shows, and cancelling its notification would
    /// leave a row that looks armed and never rings.
    private func delete(_ reminder: Reminder) async {
        guard let accountId = accounts.accountId else { return }
        busyId = reminder.id
        defer { busyId = nil }
        do {
            try await api.deleteReminder(id: reminder.id, accountId: accountId)
            MailNotificationService.shared.cancelReminder(id: reminder.id)
            await load()
        } catch {
            errorBanner = ErrorBanner(
                severity: .error,
                title: l10n.reminderTitle,
                detail: l10n.reminderDeleteFailed + error.lagoonUIMessage,
                actionLabel: l10n.retry,
                action: { [self] in await self.delete(reminder) }
            )
        }
    }
}
