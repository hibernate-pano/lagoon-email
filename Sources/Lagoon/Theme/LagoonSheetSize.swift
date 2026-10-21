import SwiftUI

/// The size of every sheet in the app, in four steps.
///
/// ## Why this exists
///
/// The audit counted **eight different sheet widths** (360 / 420 / 440 / 460
/// / 480 / 520 / 560 / 620 / 640) and **six different heights**. Two sheets
/// opened side by side had visibly different widths, which is the single
/// fastest way to look like hobby software — a professional app has one
/// modal width, like one type scale and one accent colour.
///
/// Four steps, not one: the About box has no business being 640pt wide, and
/// the search sheet has no business being 360pt. The rule is that a sheet
/// picks the *smallest* step that holds its content, so the sizes form a
/// ladder rather than a spread.
enum LagoonSheetSize {
    /// 360 × 360. A single-purpose dialog: About, a confirmation.
    static let compact = CGSize(width: 360, height: 360)

    /// 520 × 480. The workhorse: panels, lists with a column, forms.
    static let standard = CGSize(width: 520, height: 480)

    /// 640 × 560. Sheets that show a lot: search results, a sender's mail.
    static let wide = CGSize(width: 640, height: 560)

    /// 600 × 520. Anything with a text editor in it.
    ///
    /// A composer needs room to write, and it needs the Send button to sit
    /// next to the text rather than below a paragraph. It gets its own step
    /// because a composer is the one sheet where the *writing* area matters
    /// more than the chrome.
    static let composer = CGSize(width: 600, height: 520)
}
