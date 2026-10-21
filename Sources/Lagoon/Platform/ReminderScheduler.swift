import Foundation
import SwiftUI
import LagoonKit

/// Keeps the system's notification queue in step with the app's own store.
///
/// ## Why this exists
///
/// A scheduled `UNNotificationRequest` lives in the system's queue, and
/// **the system forgets it**: a reboot, a logout, a reinstall, a crash —
/// and the reminder never fires. The user set it, the app said 「设好了」,
/// and the moment came and went in silence.
///
/// So the row in the app's own store is the truth, and the notification is
/// only the delivery. Every launch, the pending rows are read back and the
/// system's queue is rebuilt from them.
///
/// ## Why the queue is cleared first
///
/// `cancelAllReminders()` runs before the re-arm. The pending set in the
/// system is rebuilt from the store, so anything left over from a previous
/// launch that no longer has a row would otherwise fire — a notification
/// for a reminder the user deleted while the app was closed, at a moment
/// nobody agreed to.
///
/// ## Why this is not a view
///
/// The reminders have to be armed whether or not a window is open, and the
/// app's own poller (`MailboxMonitor`) is the thing that outlives the
/// window. This is a separate type rather than a method on the monitor
/// because the two have different triggers: the monitor polls on a timer,
/// this runs once per launch.
@MainActor
public final class ReminderScheduler: ObservableObject {
    public static let shared = ReminderScheduler()

    /// Whether the last arming attempt worked.
    ///
    /// Published so a view can show a "your reminders could not be
    /// scheduled" note — a silent failure here is exactly the failure
    /// this whole class exists to prevent, and it must not be silent.
    @Published public private(set) var lastError: String?

    /// The number of reminders armed on the last pass.
    @Published public private(set) var armedCount: Int = 0

    /// The number of reminders that were waiting but could **not** be
    /// armed, because the system cannot deliver a notification right now.
    ///
    /// This is the number the user needs: a reminder that is on the list
    /// but was never handed to the system is a row the user has to
    /// remember to look at, and the whole point of a reminder is that
    /// it comes to the user.
    @Published public private(set) var blockedCount: Int = 0

    /// Why the arming was blocked, when it was.
    ///
    /// The reason decides what the user can do about it — a switch they
    /// can flip is different from a permission the system has refused —
    /// so it is kept rather than flattened into a message.
    @Published public private(set) var blockedReason: MailNotificationService.ReminderDelivery?

    private let api: APIClient

    public init(api: APIClient = APIClient.shared) {
        self.api = api
    }

    /// Rebuilds the system's notification queue from the store.
    ///
    /// Called on every launch. Failures are recorded rather than thrown:
    /// a reminder that could not be scheduled is a problem to *show*, not
    /// a reason to take the app down at startup.
    @discardableResult
    public func armPending(accountId: UUID) async -> Int {
        let service = MailNotificationService.shared
        // The system's answer to "may this app post notifications?" is
        // not known until the system is asked, and the app only asks in
        // Settings — so on a fresh launch the answer reads "not
        // determined", which is not "allowed". Arming without this
        // refresh would schedule nothing, for a user who *had* turned
        // notifications on: the reminder would be on the list and would
        // never ring.
        //
        // Reading the system's answer is not the same as asking the user
        // for permission: `notificationSettings()` never prompts.
        await service.refreshAuthorization()
        do {
            let reminders = try await api.fetchReminders(accountId: accountId)
            // Rebuild from scratch: the system may hold requests for rows
            // that are gone.
            service.cancelAllReminders()
            var armed = 0
            var blocked = 0
            var blockedReason: MailNotificationService.ReminderDelivery?
            for reminder in reminders where reminder.isActive && reminder.dueAt > Date() {
                let outcome = service.scheduleReminder(
                    id: reminder.id,
                    dueAt: reminder.dueAt,
                    subject: reminder.subject,
                    remoteId: reminder.remoteId
                )
                switch outcome {
                case .scheduled:
                    armed += 1
                default:
                    // One reason is enough: they all have the same
                    // consequence, and the first one is the one that
                    // explains the rest.
                    blocked += 1
                    if blockedReason == nil { blockedReason = outcome }
                }
            }
            armedCount = armed
            blockedCount = blocked
            self.blockedReason = blockedReason
            lastError = nil
            return armed
        } catch {
            lastError = L10n.current.reminderArmFailed + error.lagoonUIMessage
            return 0
        }
    }
}
