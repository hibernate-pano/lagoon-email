import Foundation
import SwiftUI

/// The bridge between the app's menu bar and the window that has to act on it.
///
/// ## Why this object exists
///
/// A macOS app's commands live in the **menu bar**, not in the window. The
/// user reaches for 邮件 → 新邮件 without ever looking at the toolbar, and a
/// command that only exists as a toolbar button is invisible to anyone who
/// explores the app the way macOS users explore apps.
///
/// The problem is that SwiftUI's `CommandMenu` is declared on the `App`, and
/// the `App` has no access to the `WindowGroup`'s view state. So the menu
/// cannot set `RootView`'s `showCompose = true` directly.
///
/// This router is the seam. The menu **sends** a command; the window
/// **receives** it and turns it into the state change it already knows how
/// to make. One direction only, and the window stays the single owner of
/// "what is on screen".
///
/// ## Why a slot rather than a queue
///
/// A bool loses a command that arrives while another is still pending
/// ("new message" while "about" is still open). A single slot with an
/// identity token does not: a second command while one is in flight
/// replaces it, and the window picks up the newest state. That is the
/// behaviour a menu should have — the last thing you clicked is the thing
/// that happens.
@MainActor
public final class AppCommandRouter: ObservableObject {
    /// The commands the menu bar (and the URL scheme) can raise.
    public enum Command: Equatable, Sendable {
        case newMessage
        /// Open the search panel. Carries a pre-filled query when the link
        /// supplied one.
        case search(query: String?)
        case toggleSurface
        /// Re-read the list from the server — what is already fetched.
        case refresh
        /// Ask the server to pull from IMAP, then re-read.
        ///
        /// A separate command from `refresh` because they are different
        /// verbs with different latencies: `refresh` is a local re-read and
        /// returns in milliseconds, `getNewMail` is a network round trip to
        /// the mail server and can take seconds. A menu that offered one
        /// key for both would make the fast one look broken.
        case getNewMail
        case cycleDensity
        case showShortcuts
        case showAbout
        case showUsage
        case showAdvice
        /// Open the reminders the user set for themselves.
        case showReminders
        case showActionHistory
        case showSenderRanking
        case showAISettings
        case showCommandPalette
        /// Open one message, by its remote id. Carries a payload because
        /// "open this mail" is not expressible without one.
        case showMessage(remoteId: String)
        /// Go to the unread lens.
        case showUnread
    }

    /// The command the window has not acted on yet.
    ///
    /// `nil` means "nothing pending". A non-nil value is a *request*, and the
    /// window clears it once it has acted — which is what makes the same
    /// command raisable twice in a row.
    @Published public private(set) var pending: Command?

    /// Raises a command.
    public func send(_ command: Command) {
        pending = command
    }

    /// Takes the pending command, if any.
    ///
    /// The window calls this from `.onChange(of: router.pending)`, so the
    /// command is delivered exactly once.
    public func take() -> Command? {
        defer { pending = nil }
        return pending
    }

    public static let shared = AppCommandRouter()
}
