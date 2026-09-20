import SwiftUI

/// The single source of truth for Lagoon's brand colours. Each
/// constant exists in one place so that retuning the palette — e.g.,
/// matching a future icon redesign — is a one-line change.
///
/// Palette origin: matches the icon (`scripts/build-icon.py`) so the
/// in-app accent and the Dock icon tell the same visual story. The
/// colours are dark-mode-tolerant: tested against both `Color` schemes
/// in the macOS system appearance.
enum LagoonTheme {
    /// Signature accent — the same teal-blue as the icon's gradient
    /// bottom. Used for `.tint` on the root WindowGroup and as the
    /// sender-avatar accent stripe.
    static let brand = Color(red: 0.12, green: 0.43, blue: 0.52) // #1F6F84

    /// Deep teal from the icon's gradient top — used for the unread
    /// indicator dot in the message list, so it visibly anchors the
    /// "needs your attention" rows.
    static let deepTeal = Color(red: 0.05, green: 0.23, blue: 0.29) // #0E3A4A

    /// Sundown orange from the icon's outermost ripple arc — used
    /// sparingly: destructive "archive" actions only, never for
    /// progress or status.
    static let accent = Color(red: 0.91, green: 0.64, blue: 0.36) // #E8A35C
}