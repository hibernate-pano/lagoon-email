import Foundation

/// The three columns of the mail window, in layout order.
///
/// An enum rather than an `Int` index so the solver, the persistence keys and
/// the accessibility labels cannot disagree about which column is which — the
/// bug class this whole file exists to prevent.
enum LagoonColumn: Int, CaseIterable, Sendable {
    /// Folders, smart views and the user's own aggregation rules.
    case navigation = 0
    /// The message list. The scannable column.
    case list = 1
    /// The reading pane.
    case reader = 2
}

/// One column's width envelope.
///
/// `min` and `softMin` are deliberately different numbers, and the gap between
/// them is the whole degradation story:
///
/// * At or above the window floor the column never goes below `min`.
/// * Between the floor and `sum(min) + dividers` the column may be squeezed
///   down to `softMin` — the window is too narrow to honour every `min`, and
///   something has to give. Which something is decided by `weight`, not by
///   position.
/// * Below that the window is outside what the product promises, and the
///   solver clips rather than producing a negative width.
struct ColumnSpec: Sendable, Equatable {
    /// Never crossed while the window is wide enough to honour every `min`.
    let min: Double
    /// The floor the column may be squeezed to in a narrow window.
    let softMin: Double
    /// The reset target (double-click) and the first-run width.
    let ideal: Double
    /// Never crossed, however wide the window gets.
    let max: Double
    /// Share of the compensation when another column is dragged.
    ///
    /// Also the priority: **the largest weight is sacrificed first** when the
    /// window is too narrow to honour every `min`. The reader carries 3.0
    /// because a squeezed reading pane costs less than a squeezed folder list.
    let weight: Double

    /// Widths below zero are never a legal answer, whatever the window does.
    static let absoluteFloor: Double = 0
}

/// The measured values behind "顺滑", in one place.
///
/// Every number here is a decision, not a default: the divider's hit width
/// comes from the HIG range Finder and Mail use, the rubber-band curve is the
/// one that tracks the finger for the first few points and then decays, and
/// the window floor is `sum(min) + dividers` rounded up — the old 720 was a
/// leftover from the two-column layout and is arithmetically smaller than the
/// three columns' minimum, which is why it had to move.
enum ColumnLayoutMetrics {
    /// Visual separator. A hairline, not a bar.
    static let dividerThickness: Double = 1

    /// Pointer target for a separator. HIG and Finder/Mail both land in the
    /// 8–12pt band; below 8pt it is genuinely hard to catch on a Retina
    /// display.
    static let dividerHitWidth: Double = 10

    /// How far the target spills into each neighbouring column.
    ///
    /// Half the target is the visible line, the other half is tolerance: the
    /// user should not have to land on the exact pixel.
    static let dividerHitOverflow: Double = (dividerHitWidth - dividerThickness) / 2

    /// Rubber-band resistance scale. The curve is `over / (1 + over/150)`, so
    /// the first ~10pt tracks the pointer almost exactly and the rest decays.
    static let rubberBandScale: Double = 150

    /// Hard stop on the rubber band. Past this the divider simply does not
    /// move, which is what makes "there is no more room" legible instead of
    /// merely slow.
    static let rubberBandCap: Double = 40

    /// Spring-back duration on release. Fast enough to read as "that was the
    /// limit" rather than as an animation.
    static let reboundDuration: Double = 0.15

    /// One arrow-key press.
    static let keyboardStep: Double = 16

    /// One Page Up / Page Down press.
    static let keyboardPageStep: Double = 64

    /// `UserDefaults` prefix. One key per column, holding the width the user
    /// actually left the column at.
    static let storageKeyPrefix = "lagoon.column."

    /// The narrowest window the given columns can honour without breaking a
    /// single `min`: `sum(min) + separators` over the columns actually
    /// present.
    ///
    /// The one derivation of the floor (UX-11). It used to exist three times:
    /// a static `832` here under a "rounded up to the 8pt grid" comment that
    /// was wrong twice over (822 ceils to 824, not 832 — the number was a
    /// leftover), a computed three-column twin that nothing called, and a
    /// re-derivation inside `RootView` for the live column set. `RootView`
    /// and the solver tests both call this now.
    static func minimumWindowWidth(for columns: [LagoonColumn]) -> Double {
        columns.reduce(0) { $0 + spec(for: $1).min }
            + Double(max(0, columns.count - 1)) * dividerThickness
    }

    /// The three-column floor — the window's minimum once an account is
    /// connected. Derived from `specs`, never re-spelled: `ColumnSolverTests`
    /// asserts the solver honours every `min` at and above this value.
    static var windowMinimumWidth: Double {
        minimumWindowWidth(for: LagoonColumn.allCases)
    }

    /// The shortest window the three columns are usable in.
    ///
    /// A mail row is 28pt tall and the reader needs room for a signature and a
    /// quoted line without scrolling; below this the columns are technically
    /// legal and practically unusable, and macOS will happily let a user get
    /// there with the green button.
    static let windowMinimumHeight: CGFloat = 420

    /// The three columns' envelopes, in layout order.
    ///
    /// A mail list is a scannable column: wide enough for a subject and a
    /// snippet, narrow enough that the reader keeps the better half of the
    /// window. The weights are what make dragging one column feel like the
    /// other two are cooperating rather than resisting.
    static let specs: [ColumnSpec] = [
        ColumnSpec(min: 180, softMin: 150, ideal: 210, max: 300, weight: 1.0),
        ColumnSpec(min: 280, softMin: 240, ideal: 340, max: 460, weight: 2.0),
        ColumnSpec(min: 360, softMin: 300, ideal: 520, max: 900, weight: 3.0),
    ]

    /// The column a separator handle resizes.
    ///
    /// Handle `i` sits between column `i` and column `i + 1`, and dragging it
    /// right sets column `i` wider — so the handle owns the column on its
    /// left. Stated once because "which column does this handle move" is the
    /// one piece of this layout that is genuinely ambiguous.
    static func resizedColumn(forHandle index: Int) -> LagoonColumn? {
        LagoonColumn(rawValue: index)
    }

    /// `UserDefaults` key for a column's persisted width.
    static func storageKey(for column: LagoonColumn) -> String {
        storageKeyPrefix + String(column.rawValue)
    }

    /// One column's envelope. Traps on an unknown case rather than defaulting,
    /// because a silent zero width here would be the first symptom of a
    /// mismatch between this enum and the solver's arithmetic.
    static func spec(for column: LagoonColumn) -> ColumnSpec {
        specs[column.rawValue]
    }
}
