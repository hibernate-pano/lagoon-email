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
/// Three brand colours, all used, plus one severity scale that every
/// surface reads from. A colour earns its place by being *the* colour for
/// one meaning; a second colour for the same meaning is a bug, not a
/// variation.
enum LagoonTheme {
    // MARK: - Brand

    /// Signature accent — the same teal-blue as the icon's gradient
    /// bottom. Used for `.tint` on the root WindowGroup and as the
    /// sender-avatar accent stripe.
    static let brand = Color(red: 0.12, green: 0.43, blue: 0.52) // #1F6F84

    /// Deep teal from the icon's gradient top — the **unread** marker.
    ///
    /// Not `.tint`: `.tint` follows the system accent colour, and in dark
    /// mode a light-blue dot on a dark row is close to invisible. This is a
    /// fixed dark teal that holds its contrast in both appearances.
    static let deepTeal = Color(red: 0.05, green: 0.23, blue: 0.29) // #0E3A4A

    /// Sundown orange from the icon's outermost ripple arc — the **pin**.
    ///
    /// A pin is a deliberate keep, not a warning, so it does not wear a
    /// severity colour. Orange is the one warm colour in the palette, and
    /// using it for exactly one meaning makes it legible at a glance.
    static let accent = Color(red: 0.91, green: 0.64, blue: 0.36) // #E8A35C

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

    /// The colour of an unread row's leading stripe and dot.
    ///
    /// `deepTeal` rather than `brand`: the stripe sits on a row background
    /// that is already carrying `brand` in the tint, so the two must differ
    /// to read as two things.
    static let unreadMarker = deepTeal

    /// The colour of a destructive action (彻底删除, 退订).
    static let danger = Color.red

    /// The colour of a warning action.
    static let warning = Color.orange

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
