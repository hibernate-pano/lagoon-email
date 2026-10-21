import Foundation
import SwiftUI
import AppKit
import LagoonKit

/// The app's one poller for account state, and the thing that drives the
/// Dock badge and the new-mail notification.
///
/// ## Why this is not a view
///
/// Two things the app must show — the unread count on the Dock icon, and the
/// system notification for new mail — have to keep working when **no window
/// is open**. That is the whole point of a Dock badge: the user closed the
/// app's window and still wants to know whether something came in.
///
/// A view-scoped poller dies with its view. So the polling lives here, at
/// the app level, and the views read what it publishes.
///
/// ## Why it is also the badge's source
///
/// The badge and the sidebar's unread number must be the same number. If
/// two components each poll the server and each decide what "unread" means,
/// the badge can say 12 while the sidebar says 11, and the user has no way
/// to tell which is right. One poller, one number, published once.
///
/// ## The throttled refresh
///
/// `refresh()` fetches only when the last fetch is more than
/// `refreshThrottle` old. The app has two pollers that want the same data
/// — this one (for the badge) and the view's own (for the list) — and a
/// throttle lets them coexist without doubling the request rate. `refreshNow()`
/// bypasses it, for the moments where the user just changed something and
/// the answer must be immediate.
@MainActor
public final class MailboxMonitor: ObservableObject {
    public static let shared = MailboxMonitor()

    /// The accounts, as the server last reported them.
    @Published public private(set) var accounts: [ConnectedAccount] = []

    /// The last fetch's error, if it failed.
    ///
    /// Kept rather than thrown: a failed poll must not take the app down,
    /// and the last known good state is still worth showing.
    @Published public private(set) var loadError: String?

    /// The server's active account.
    public var active: ConnectedAccount? {
        accounts.first(where: \.isActive) ?? accounts.first
    }

    /// How often the monitor polls on its own.
    public static let pollInterval: Duration = .seconds(30)

    /// Two refreshes closer together than this share one fetch.
    private static let refreshThrottle: TimeInterval = 2

    private let api: APIClient
    private var lastFetchAt: Date?
    private var pollTask: Task<Void, Never>?
    /// The unread count last seen, per account.
    ///
    /// Per account, not global: switching accounts changes the number for
    /// reasons that have nothing to do with new mail, and a global baseline
    /// would fire a notification for it.
    private var lastUnreadByAccount: [UUID: Int] = [:]
    /// Accounts seen at least once, so the first observation of a mailbox
    /// establishes a baseline instead of announcing everything in it.
    private var knownAccounts: Set<UUID> = []

    public init(api: APIClient = APIClient.shared) {
        self.api = api
    }

    // MARK: - Lifecycle

    /// Starts the background poll.
    ///
    /// Idempotent: calling it twice does not start two pollers.
    public func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshNow()
                // Sleep in small slices so a cancellation takes effect
                // promptly rather than after the full interval.
                try? await Task.sleep(for: Self.pollInterval)
                if Task.isCancelled { return }
            }
        }
    }

    /// Stops the background poll.
    public func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Refreshing

    /// Fetches the accounts if the last fetch is stale.
    ///
    /// The throttle is what lets the app's own poll and the views' polls
    /// share one request instead of two.
    public func refresh() async {
        if let lastFetchAt,
           Date().timeIntervalSince(lastFetchAt) < Self.refreshThrottle {
            return
        }
        await refreshNow()
    }

    /// Fetches the accounts now, whatever the throttle says.
    public func refreshNow() async {
        do {
            let fetched = try await api.fetchAccounts()
            lastFetchAt = Date()
            loadError = nil
            apply(fetched)
        } catch {
            loadError = L10n.current.checkConnectionFailed + error.lagoonUIMessage
        }
    }

    /// Publish a freshly fetched account list.
    private func apply(_ fetched: [ConnectedAccount]) {
        accounts = fetched
        updateBadge()
        announceNewMail(in: fetched)
    }

    // MARK: - Dock badge

    /// The unread count for the active account.
    private var activeUnread: Int {
        active?.unreadCount ?? 0
    }

    private func updateBadge() {
        let unread = activeUnread
        if unread > 0 {
            DockBadgeController.shared.update(unread: unread)
        } else {
            DockBadgeController.shared.clear()
        }
    }

    // MARK: - New mail notification

    /// Posts a notification when the active account's unread count grows.
    ///
    /// The count is the signal, and it is a good one: it grows when mail
    /// arrives and shrinks when the user reads — including in another client,
    /// which is exactly the case where a notification would be wrong.
    ///
    /// The first observation of an account only records a baseline. A fresh
    /// install with 400 unread messages must not announce 400 new messages
    /// the moment it launches.
    private func announceNewMail(in fetched: [ConnectedAccount]) {
        guard let account = fetched.first(where: \.isActive) ?? fetched.first else {
            // No account any more: the badge and the baseline both go.
            DockBadgeController.shared.clear()
            lastUnreadByAccount.removeAll()
            knownAccounts.removeAll()
            return
        }

        let current = account.unreadCount
        let previous = lastUnreadByAccount[account.id]

        if knownAccounts.contains(account.id), let previous, current > previous {
            let delta = current - previous
            Task { [weak self] in
                await self?.postNotification(delta: delta, account: account)
            }
        }

        lastUnreadByAccount[account.id] = current
        knownAccounts.insert(account.id)
    }

    /// Asks the server for the newest message, and notifies with it.
    ///
    /// The count alone ("12 new messages") is a number the user cannot act
    /// on. The sender and subject are what make the notification worth
    /// clicking, so they are fetched — but only when a notification is
    /// actually going to be posted, so the cost is one extra request per
    /// arrival rather than per poll.
    private func postNotification(delta: Int, account: ConnectedAccount) async {
        let service = MailNotificationService.shared
        guard service.isEnabled else { return }

        // A banner for mail the user is already looking at is noise, not
        // information. Mail.app behaves the same way: while the app is
        // frontmost, the mail is visible on screen and the notification
        // would say exactly what the window already says.
        //
        // `isActive` is "is this app frontmost", not "does it have a
        // window" — the badge still updates either way, which is the point:
        // the badge is a fact about the mailbox, the banner is a message to
        // a user who is looking elsewhere.
        guard !NSApp.isActive else { return }

        var sender: String?
        var subject: String?
        if let newest = try? await api.fetchMessages(
            accountId: account.id,
            limit: 1
        ).messages.first {
            sender = newest.fromName ?? newest.fromAddress
            subject = newest.subject
        }
        service.notifyNewMail(count: delta, sender: sender, subject: subject)
    }
}
