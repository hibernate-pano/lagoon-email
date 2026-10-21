import SwiftUI

/// Every spacing, radius and size in the app, in one place.
///
/// ## Why this file exists
///
/// The audit counted **28 different spacing values** and **45 distinct design
/// numbers** across the view layer, and six "email row" layouts that each
/// spelled out their own metrics. That is not a style preference — it is the
/// reason the app reads as several apps stapled together: two rows that should
/// look like siblings do not, because one of them used 2pt where the other
/// used 4pt.
///
/// The precedent is already in the repo: `ColumnLayoutMetrics` (in
/// `Views/ColumnLayout/LagoonColumn.swift`) holds every window-geometry
/// number and has **zero hardcoded literals** in the five files that use it.
/// This is that pattern, extended to the rest of the UI.
///
/// The rule the tokens encode: **a number that appears in more than one place
/// is a decision, and decisions live here.** A number that appears once can
/// stay local — moving every literal into a token file is churn without
/// benefit.
enum LagoonMetrics {
    // MARK: - Spacing

    /// 4pt. Between two elements of the same row (label and value, dot and
    /// text) — the tightest gap that still reads as two objects.
    static let spaceXS: CGFloat = 4
    /// 8pt. Between two controls (buttons in a toolbar, chips in a row).
    static let spaceSM: CGFloat = 8
    /// 12pt. Inside a group of related content.
    static let spaceMD: CGFloat = 12
    /// 16pt. Between blocks of content.
    static let spaceLG: CGFloat = 16
    /// 24pt. Page padding — the margin of a sheet or a padded section.
    static let spaceXL: CGFloat = 24
    /// 32pt. Between major sections, and the outer margin of a sheet.
    static let spaceXXL: CGFloat = 32

    // MARK: - Radii

    /// 4pt. Small chips and tags.
    static let radiusSmall: CGFloat = 4
    /// 6pt. Text fields and inputs.
    static let radiusMedium: CGFloat = 6
    /// 8pt. Cards and panels.
    static let radiusLarge: CGFloat = 8

    // MARK: - Status markers

    /// 8pt. A status dot: the account menu's sync state, the AI config state.
    ///
    /// One size for every status dot. The audit found three (6 / 7 / 8) for
    /// two different meanings — a size that varies with context stops being a
    /// signal.
    static let statusDotSize: CGFloat = 8

    /// 7pt. The unread dot on a mail row.
    ///
    /// Smaller than a status dot on purpose: the unread dot is a *quiet*
    /// marker that repeats down a column, and a column of 8pt dots reads as
    /// noise rather than as "these need you".
    static let unreadDotSize: CGFloat = 7

    /// 2pt. The accent stripe down the leading edge of an unread row.
    ///
    /// This is the non-colour half of the unread signal: a stripe reads in
    /// grayscale, in dark mode, and to a colour-blind user, which a dot
    /// cannot.
    static let unreadStripeWidth: CGFloat = 2

    // MARK: - Avatars and rows

    /// 28pt. The sender avatar in the Briefing feed.
    static let avatarSize: CGFloat = 28

    /// The default width of the reading pane's text column.
    ///
    /// Capped so a line of body text does not run past the point where the
    /// eye can find the next line; a 1400pt-wide paragraph is measurably
    /// harder to read than a 900pt one.
    static let readingColumnWidth: CGFloat = 900
}
