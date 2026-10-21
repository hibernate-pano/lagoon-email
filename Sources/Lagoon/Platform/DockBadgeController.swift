import AppKit
import Foundation

/// The unread count on the Dock icon.
///
/// ## Why this is not a decoration
///
/// A mail client that runs in the Dock but shows no badge is a mail client
/// that has to be watched. The badge is the cheapest possible answer to
/// "is there anything new", and it is the answer macOS users already expect
/// from every other mail app they have ever used — so its absence reads as
/// "this app does not know what it is doing" rather than as a design choice.
///
/// ## Why it lives in a controller rather than in a view
///
/// The Dock tile belongs to the application, not to a window. A badge driven
/// by a view would stop updating the moment that view was torn down — and the
/// one moment the badge matters most is when the user has closed the window
/// and is waiting for mail to arrive. So the controller is a process-lifetime
/// object, and the views hand it a number.
@MainActor
public final class DockBadgeController {
    public static let shared = DockBadgeController()

    /// The count currently shown.
    ///
    /// Kept so a redundant update does not redraw the tile: `NSApp.dockTile`
    /// redraws on every assignment, and a redraw per poll (every 30s) is a
    /// visible flicker on the Dock icon.
    private var current: Int = 0

    /// The number the badge shows for a given unread count.
    ///
    /// Zero shows no badge at all — a "0" on a Dock icon reads as "there is
    /// mail, and it is unread", which is the opposite of the truth.
    public static func label(for unread: Int) -> String? {
        guard unread > 0 else { return nil }
        // The Dock tile is 128pt at @2x; a three-digit badge already crowds
        // it, and anything past that would be truncated by the system anyway.
        return unread > 999 ? "999+" : String(unread)
    }

    /// Updates the badge. Safe to call with the same value repeatedly.
    public func update(unread: Int) {
        guard unread != current else { return }
        current = unread
        NSApp.dockTile.badgeLabel = Self.label(for: unread)
    }

    /// Clears the badge. Used when the account is disconnected — a badge for
    /// a mailbox that is no longer connected is a lie.
    public func clear() {
        guard current != 0 else { return }
        current = 0
        NSApp.dockTile.badgeLabel = nil
    }

    private init() {}
}
