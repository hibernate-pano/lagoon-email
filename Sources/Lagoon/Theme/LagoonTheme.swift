import SwiftUI
import LagoonKit

/// The single source of truth for Lagoon's colours.
///
/// ## What was wrong
///
/// The theme defined three colours and the app used **one** of them. The
/// other two were documented — `deepTeal` said in its own comment that it
/// was "used for the unread indicator dot in the message list" — but the dot
/// was drawn in `.tint`, and the four swipe actions were drawn in `.blue`,
/// `.green`, `.orange` and `.yellow`. The result was a window title bar in
/// Lagoon teal sitting next to four system-blue/green/orange/yellow accents:
/// two accent languages on one screen.
///
/// The severities were worse. "Sync is unstable" was orange in one place,
/// yellow in another, and orange again in a third — three palettes for one
/// concept, so a user could not learn "yellow means degraded".
///
/// ## What is here now
///
/// Two brand colours and one semantic marker, all of them used, plus one
/// severity scale that every surface reads from. A colour earns its place by
/// being *the* colour for one meaning; a second colour for the same meaning
/// is a bug, not a variation — which is why the pin's orange and the
/// "warning" alias were deleted rather than left to rot beside the scale
/// that already says what they mean.
enum LagoonTheme {
    // MARK: - Brand

    /// Signature accent — the same teal-blue as the icon's gradient
    /// bottom. Used for `.tint` on the root WindowGroup and as the
    /// sender-avatar accent stripe.
    static let brand = Color(red: 0.12, green: 0.43, blue: 0.52) // #1F6F84

    // MARK: - Severity

    /// The one severity scale.
    ///
    /// `.info` is deliberately *not* a success colour: a blue "Done" reads as
    /// a problem, which is the exact confusion the old `.info` severity
    /// caused (every successful archive and send was drawn as a blue
    /// `info.circle.fill`).
    ///
    /// Success is a separate case — see `ErrorBanner.Severity.success` and
    /// `LagoonTheme.severityColor(_:)`.
    public enum Severity: String, Equatable, Sendable {
        case info
        case success
        case warning
        case error

        /// The colour this severity is drawn in.
        public var color: Color {
            switch self {
            case .info: return .blue
            case .success: return .green
            case .warning: return .orange
            case .error: return .red
            }
        }

        /// The SF Symbol this severity is drawn with.
        ///
        /// The icon carries the meaning as well as the colour does, so the
        /// severity survives a colour-blind reader and a grayscale print.
        public var icon: String {
            switch self {
            case .info: return "info.circle.fill"
            case .success: return "checkmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .error: return "exclamationmark.octagon.fill"
            }
        }
    }

    /// The colour for a severity, from the one scale.
    public static func severityColor(_ severity: Severity) -> Color {
        severity.color
    }

    /// The symbol for a severity, from the one scale.
    public static func severityIcon(_ severity: Severity) -> String {
        severity.icon
    }

    // MARK: - Semantic colours

    /// The colour of an unread row's marker.
    ///
    /// ## Why it follows the appearance
    ///
    /// The marker is drawn on the row's own background, and that background
    /// is near-black in dark mode. The old fixed deep teal (#0E3A4A) was
    /// therefore *invisible* there — the one thing that says "unread" was
    /// the thing a dark-mode user could not see, and the comment above it
    /// claimed the opposite.
    ///
    /// So the light appearance keeps the icon's deep teal and the dark
    /// appearance gets a light teal that holds its contrast. The marker's
    /// *shape* (a 7pt dot) and the row's bold subject carry the state
    /// without colour, so the dot is the second signal, not the only one.
    static let unreadMarker = Color(nsColor: unreadMarkerColor)

    /// The unread marker's colour, as an `NSColor`.
    ///
    /// Kept beside the SwiftUI colour so the appearance resolver can hand
    /// the system the right value for the current appearance — and so a
    /// test can ask what the marker actually looks like in the dark.
    static let unreadMarkerColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(red: 0.45, green: 0.80, blue: 0.87, alpha: 1)
            : NSColor(red: 0.05, green: 0.23, blue: 0.29, alpha: 1)
    }

    /// The colour of a destructive action (彻底删除, 退订).
    ///
    /// Named rather than left to `role: .destructive` so the destructive
    /// buttons in the app all wear the same red — a destructive action that
    /// borrows the system accent colour is a destructive action the user
    /// cannot recognise.
    static let danger = Color.red

    // MARK: - Sync health

    /// The colour of a sync-health status dot.
    ///
    /// One mapping, used by every surface that shows the dot — the toolbar's
    /// account menu and the Settings window. The two used to disagree: the
    /// toolbar drew "degraded" yellow while Settings drew it orange, so a
    /// user had to learn two colours for one state, and neither of them
    /// was the colour the rest of the app used for "something is wrong but
    /// not broken".
    static func syncStatusColor(_ status: SyncHealth.Status) -> Color {
        switch status {
        case .ok: return Severity.success.color
        case .degraded: return Severity.warning.color
        case .error: return Severity.error.color
        case .needsReconnect: return Severity.error.color
        case .accountMissing: return Severity.error.color
        }
    }
}
