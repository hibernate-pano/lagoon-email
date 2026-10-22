import SwiftUI
import Foundation

/// How a mail row is typeset.
///
/// ## Why this exists
///
/// The audit found **six different "email row" implementations** — the
/// Briefing row, the raw-list row, the dense row (twice), the conversation
/// row, the search-result row, the hover card and the sender-ranking row —
/// each with its own subject font, its own snippet font, its own spacing and
/// its own truncation rules. Two of them disagreed about a detail as small as
/// whether the snippet is drawn in `.secondary`; in a screenshot that
/// difference is visible, and it is the kind of visible difference that makes
/// a product look assembled rather than designed.
///
/// Six implementations of one concept is the actual bug. A row is a row, and
/// the differences between the Briefing and the raw list are *density*, not
/// typography.
///
/// ## How rows differ
///
/// The two surfaces differ in what they show (a reason line vs a snippet),
/// not in how they show it. So the shared tokens cover subject / sender /
/// snippet / time / spacing, and each surface picks the *density* variant of
/// the subject font from `ListDensity`.
enum LagoonTypography {
    /// The subject line — the one thing a triage tool must make readable.
    static let rowSubject: Font = .body
    /// The subject line in dense mode.
    ///
    /// One step down from `.body` and no further: `.callout` is where a
    /// subject stops being scannable, and dense mode is a *scanning* mode.
    static let rowSubjectDense: Font = .callout
    /// The sender — supporting identity, never the thing you read first.
    static let rowSender: Font = .caption
    /// The snippet / reason line.
    static let rowSnippet: Font = .caption2
    /// The timestamp.
    static let rowTime: Font = .caption2

    /// Vertical gap between the lines of a row.
    ///
    /// 4pt everywhere. The raw list used 2pt, which is tight enough that a
    /// three-line row reads as a wall of text rather than as three facts.
    ///
    /// It is the scale's smallest rung rather than a second name for 4pt:
    /// a row's spacing is a gap, and every gap in the app is a rung of the
    /// one scale.
    static let rowSpacing: CGFloat = LagoonMetrics.spaceXS

    /// How many lines of snippet a row shows.
    static let rowSnippetLines = 2

    /// How many lines of subject a row shows.
    ///
    /// One, always. A two-line subject turns a scannable list into a
    /// scrolling one, and the full subject is one click away in the reader.
    static let rowSubjectLines = 1

    /// The timestamp format, shared by every surface.
    ///
    /// ## Why the format is computed rather than fixed
    ///
    /// The Briefing showed "10月20日 14:30" and the raw list showed "14:30"
    /// — the same mailbox, two date conventions, and the user's eye had to
    /// re-learn the rule on every switch. Worse, "14:30" alone is ambiguous
    /// on a Tuesday: it does not say whether that is today or last Tuesday.
    ///
    /// The rule the two surfaces now share:
    /// - **Today** → the time only ("14:30"). The date is redundant when the
    ///   row is on screen today.
    /// - **This week** → the weekday ("周二 14:30"). Still recent enough that
    ///   the exact date is noise.
    /// - **Older** → the date ("10月13日").
    ///
    /// One function, one rule, two surfaces.
    static func rowTimestamp(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if let weekAgo = calendar.date(byAdding: .day, value: -7, to: now),
           date >= weekAgo {
            return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        }
        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}
