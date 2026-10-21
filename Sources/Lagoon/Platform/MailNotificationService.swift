import Foundation
import UserNotifications
import AppKit

/// System notifications for new mail.
///
/// ## Why the user has to opt in
///
/// `UNUserNotificationCenter` prompts for permission the first time it is
/// asked, and a prompt that appears out of nowhere — before the user has
/// done anything — is the fastest way to get a notification permanently
/// refused. So the app never asks on its own at launch: the switch in
/// Settings asks, and the answer is remembered.
///
/// The one exception is the moment the user asks to be reminded about
/// something. That is not "out of nowhere" — the user has just said "tell
/// me about this later", and the system prompt that follows is the only
/// way that promise can be kept. See `ReminderSheet`.
///
/// ## Why there is a bundle-identifier guard
///
/// `UNUserNotificationCenter.current()` **crashes** in a process with no
/// bundle identifier (`bundleProxyForCurrentProcess is nil`). The app is
/// normally a real `.app` bundle, but it is also runnable as
/// `swift run Lagoon` during development, and a crash on launch in the
/// developer's own terminal is not an acceptable price for a notification.
/// Every entry point here therefore checks for a bundle first and no-ops
/// without one.
@MainActor
public final class MailNotificationService: ObservableObject {
    public static let shared = MailNotificationService()

    /// UserDefaults key: has the user answered the system prompt?
    public static let enabledDefaultsKey = "lagoon.notifications.enabled"

    /// Whether the user wants new-mail notifications.
    ///
    /// This is the *preference*; the *authorization* is the system's answer
    /// to our prompt, and the two can disagree (the user turned the
    /// preference on, then said no to the system prompt). The switch in
    /// Settings shows the preference; the caption shows the authorization
    /// state, so a "on but not working" notification reads as a fact rather
    /// than as a bug.
    public var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledDefaultsKey) }
    }

    /// The system's answer to "may this app post notifications?".
    ///
    /// Published, because the answer changes without the app asking —
    /// the user can revoke the permission in System Settings while the
    /// app is running — and every surface that shows the answer has to
    /// redraw when it does.
    @Published public private(set) var authorization: UNAuthorizationStatus = .notDetermined

    /// Whether a notification would actually be delivered right now.
    public var canPost: Bool {
        authorization == .authorized || authorization == .provisional
    }

    /// Whether a reminder set right now would actually ring.
    ///
    /// The three conditions are separate on purpose. The *preference* is
    /// the user's switch; the *authorization* is the system's answer; a
    /// *bundle* is a fact about the process. A reminder that cannot ring
    /// because of any one of them is a promise the app cannot keep, and
    /// the call sites have to be able to ask this question before they
    /// tell the user the reminder is set.
    public var canDeliverReminder: Bool {
        isEnabled && canPost && Self.hasBundle
    }

    /// Refreshes the authorization state. Safe to call at any time.
    public func refreshAuthorization() async {
        guard Self.hasBundle else { return }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorization = settings.authorizationStatus
    }

    /// Asks the system for permission, and turns the preference on if the
    /// user says yes.
    ///
    /// The preference follows the system's answer rather than the other way
    /// round: if the user said no to the prompt, leaving the switch on would
    /// be a switch that lies.
    @discardableResult
    public func requestAuthorization() async -> Bool {
        guard Self.hasBundle else { return false }
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            await refreshAuthorization()
            if granted {
                isEnabled = true
            }
            return granted
        } catch {
            // A failed prompt is a "no", not a crash: the user simply keeps
            // the in-app banners, which have always worked.
            await refreshAuthorization()
            isEnabled = false
            return false
        }
    }

    /// Posts a "new mail" notification.
    ///
    /// `count` is the number of unread messages; `sender` and `subject` name
    /// the newest one, so the notification is specific rather than a bare
    /// "3 new messages" — a user who cannot tell which mail arrived cannot
    /// decide whether to open the app.
    public func notifyNewMail(count: Int, sender: String?, subject: String?) {
        guard isEnabled, canPost, Self.hasBundle else { return }
        let content = UNMutableNotificationContent()
        content.title = L10n.current.notificationNewMailTitle(count)
        if let sender, let subject, !subject.isEmpty {
            content.body = "\(sender) — \(subject)"
        } else if let sender {
            content.body = sender
        }
        content.sound = .default
        // Grouped under one identifier so ten new mails produce one stack in
        // Notification Center instead of ten separate cards.
        content.threadIdentifier = "lagoon.newmail"

        let request = UNNotificationRequest(
            identifier: "lagoon.newmail.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Whether this process has a bundle identifier.
    ///
    /// `Bundle.main.bundleIdentifier` is nil for a bare executable, and
    /// `UNUserNotificationCenter` traps on nil.
    static var hasBundle: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    /// Opens the system's notification settings for this app.
    ///
    /// The one place the URL lives. When the system has refused the
    /// permission, the app cannot ask again — the answer is final until
    /// the user changes it there — so a button that opens the pane is the
    /// only way forward, and it has to exist in more than one surface.
    public static func openSystemNotificationSettings() {
        // The pane's identifier is stable across macOS versions; the URL is
        // the documented way to reach it. If the URL somehow fails, the
        // button is a dead control — so it falls back to opening the app
        // itself, which at least gets the user to the right place.
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else {
            NSWorkspace.shared.open(URL(fileURLWithPath: Bundle.main.bundlePath))
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Reminders

    /// The identifier prefix every reminder notification shares.
    ///
    /// Grouped under one identifier so five reminders produce one stack in
    /// Notification Center instead of five separate cards — the same
    /// reasoning as the new-mail notifications.
    static let reminderIdentifierPrefix = "lagoon.reminder."

    /// The outcome of trying to schedule one reminder.
    ///
    /// A `Void` return would let a caller report "scheduled" without ever
    /// asking whether anything was scheduled — and every guard in
    /// `scheduleReminder` is a way for the answer to be "no". So the
    /// answer comes back, and the caller has to look at it.
    public enum ReminderDelivery: Equatable, Sendable {
        /// The system is holding the notification.
        case scheduled
        /// The user's preference is off.
        case notificationsDisabled
        /// The system has not granted permission, or has refused it.
        case notAuthorized
        /// The process has no bundle identifier, so there is no
        /// notification centre to talk to.
        case noBundle
        /// The reminder is due in the past, so there is no future moment
        /// to schedule it for.
        case dueInThePast
    }

    /// The reminders this app armed, and the mail each one is about.
    ///
    /// The system's queue is keyed by a numeric reminder id, which is no
    /// use to a caller that only knows the mail. This is the map between
    /// the two, and it is what makes "cancel the reminder about this mail"
    /// possible without a round trip to the server.
    private var armedRemoteIds: [Int64: String] = [:]

    /// Schedules the notification for one reminder.
    ///
    /// ## Why the notification is re-armed on every launch
    ///
    /// A scheduled `UNNotificationRequest` lives in the system's queue, and
    /// the system forgets it: a reboot, a logout, a reinstall, and the
    /// reminder never fires. The row in the app's own store is the truth,
    /// and the client re-arms the pending notifications from it every time
    /// it starts. So a reminder survives the machine going away — which is
    /// the only way a reminder can be trusted to be a reminder.
    ///
    /// A reminder already in the past is not scheduled at all: the system's
    /// trigger would be negative, and the notification would either fire
    /// immediately (a pop-up the user did not ask for) or never.
    ///
    /// ## Why the answer comes back
    ///
    /// Every guard below is a way for the promise "you will be reminded"
    /// to break. Returning the reason instead of nothing is what lets the
    /// sheet tell the user *now*, rather than the app discovering it at
    /// the due time and saying nothing at all.
    @discardableResult
    public func scheduleReminder(
        id: Int64,
        dueAt: Date,
        subject: String?,
        remoteId: String
    ) -> ReminderDelivery {
        guard isEnabled else { return .notificationsDisabled }
        guard canPost else { return .notAuthorized }
        guard Self.hasBundle else { return .noBundle }
        let interval = dueAt.timeIntervalSinceNow
        guard interval > 0 else { return .dueInThePast }

        let content = UNMutableNotificationContent()
        content.title = L10n.current.reminderNotificationTitle
        if let subject, !subject.isEmpty {
            content.body = subject
        } else {
            content.body = L10n.current.reminderNotificationBody
        }
        content.sound = .default
        content.threadIdentifier = Self.reminderIdentifierPrefix

        let request = UNNotificationRequest(
            identifier: "\(Self.reminderIdentifierPrefix)\(id)",
            content: content,
            // A `UNTimeIntervalNotificationTrigger` needs a non-zero
            // interval; the smallest one it accepts is a second, and the
            // guard above already dropped anything that is not in the
            // future.
            trigger: UNTimeIntervalNotificationTrigger(
                timeInterval: max(1, interval),
                repeats: false
            )
        )
        UNUserNotificationCenter.current().add(request)
        armedRemoteIds[id] = remoteId
        return .scheduled
    }

    /// Cancels the notification for one reminder.
    public func cancelReminder(id: Int64) {
        armedRemoteIds.removeValue(forKey: id)
        guard Self.hasBundle else { return }
        let identifier = "\(Self.reminderIdentifierPrefix)\(id)"
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [identifier]
        )
    }

    /// Cancels every reminder notification about one mail.
    ///
    /// A mail the user threw away must not still be able to ring. The
    /// server hides such a reminder from the list — a reminder about
    /// something the user deliberately got rid of is a nag — but the
    /// notification lives in the *system's* queue, and the system does not
    /// know the mail is gone. This is the client's half of that rule, and
    /// without it the notification fires for a mail sitting in the Trash.
    public func cancelReminders(forRemoteId remoteId: String) {
        let ids = armedRemoteIds.filter { $0.value == remoteId }.map(\.key)
        guard !ids.isEmpty else { return }
        for id in ids {
            armedRemoteIds.removeValue(forKey: id)
        }
        guard Self.hasBundle else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: ids.map { "\(Self.reminderIdentifierPrefix)\($0)" }
        )
    }

    /// Cancels every reminder notification.
    ///
    /// Used before re-arming: the pending set in the system is rebuilt from
    /// the store, so anything left over from a previous launch that no
    /// longer has a row would otherwise fire for a reminder that was
    /// deleted while the app was closed.
    public func cancelAllReminders() {
        armedRemoteIds.removeAll()
        guard Self.hasBundle else { return }
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
    }

    /// The reminders the system is actually holding a notification for.
    ///
    /// Read from the system rather than counted from the app's own
    /// bookkeeping: the system is what will ring, so it is what the number
    /// on screen has to describe.
    public func pendingReminderIDs() async -> Set<Int64> {
        guard Self.hasBundle else { return [] }
        let requests = await UNUserNotificationCenter.current().pendingNotificationRequests()
        var ids: Set<Int64> = []
        for request in requests {
            guard request.identifier.hasPrefix(Self.reminderIdentifierPrefix) else { continue }
            let suffix = request.identifier.dropFirst(Self.reminderIdentifierPrefix.count)
            guard let id = Int64(suffix) else { continue }
            ids.insert(id)
        }
        return ids
    }

    private init() {}
}
