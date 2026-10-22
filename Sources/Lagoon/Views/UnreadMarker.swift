import SwiftUI

/// The unread marker on a mail row.
///
/// ## Why it is its own view
///
/// The audit found **six different "email row" implementations**, each
/// drawing its own unread dot — at 6pt, 7pt and 8pt, in the system accent
/// colour and in a fixed teal, some with a VoiceOver label and some
/// without. A marker that each surface draws differently is the same defect
/// one level down from the row itself, so the marker is defined once here.
///
/// The size comes from `LagoonMetrics.unreadDotSize` and the colour from
/// `LagoonTheme.unreadMarker`, which follows the appearance: a fixed dark
/// teal is invisible on a dark row, and the marker that says "unread" is
/// the one thing a dark-mode user must not fail to see.
///
/// ## Why the column is always there
///
/// The marker occupies its column whether the row is unread or not, so the
/// subject text does not shift sideways every time a row changes state. A
/// marker that appears and disappears moves the whole column, and a list
/// whose text jitters is a list nobody can scan.
struct UnreadMarker: View {
    /// Whether the row is unread.
    let isUnread: Bool

    @Environment(\.l10n) private var l10n

    var body: some View {
        Circle()
            .fill(isUnread ? LagoonTheme.unreadMarker : .clear)
            .frame(
                width: LagoonMetrics.unreadDotSize,
                height: LagoonMetrics.unreadDotSize
            )
            // A read row has no marker to describe. An unread row has one,
            // and it is the only thing on the row that says so — bold text
            // is a shape the eye reads and a screen reader does not.
            .accessibilityHidden(!isUnread)
            .accessibilityLabel(l10n.unreadDotLabel)
    }
}
