import Foundation

/// The rubber band: what the divider does past the limit.
///
/// ## Shape
///
/// A drag that would take a column outside the range the window can honour is
/// not refused — it is *resisted*, and the resistance is visible in the
/// divider's own travel. The mapping is
///
/// ```
/// travel = over / (1 + over / 150)
/// ```
///
/// so the first ~10pt tracks the pointer almost exactly (you can still feel
/// that you moved) and everything past that decays: 50pt of overflow buys 29pt
/// of travel, 200pt buys 40pt. Capped at 40pt, past which the divider is
/// simply still.
///
/// ## What it is not
///
/// Not an `NSView` animation, not a spring, and not a timeline. The curve is
/// evaluated once per drag event and returns a number. Anything that
/// interpolates over time here would put the divider's position *behind* the
/// pointer, which is the exact "chasing the finger" lag the spec forbids.
enum RubberBand {
    /// The divider's own offset past the boundary it is resisting.
    ///
    /// `overflow` is positive past the upper bound and negative past the
    /// lower one, so the same curve serves both ends.
    static func travel(forOverflow overflow: Double, scale: Double = ColumnLayoutMetrics.rubberBandScale) -> Double {
        let magnitude = abs(overflow)
        guard magnitude > ColumnSolver.epsilon else { return 0 }
        let damped = magnitude / (1 + magnitude / scale)
        let capped = min(damped, ColumnLayoutMetrics.rubberBandCap)
        return overflow < 0 ? -capped : capped
    }

    /// Damped width for a raw drag target.
    ///
    /// Inside the range the target passes through untouched — the damping is a
    /// boundary behaviour, not a global handicap on the drag. Outside it, the
    /// excess is converted by `travel(forOverflow:)` and added to the bound
    /// the user was pushing against.
    ///
    /// - Parameters:
    ///   - raw: the width the pointer is asking for, pre-clamp.
    ///   - range: what the window can actually honour, from
    ///     `ColumnSolver.achievableRange(for:columns:totalWidth:)`.
    static func damped(
        _ raw: Double,
        range: ClosedRange<Double>
    ) -> Double {
        if raw > range.upperBound {
            return range.upperBound + travel(forOverflow: raw - range.upperBound)
        }
        if raw < range.lowerBound {
            return range.lowerBound - travel(forOverflow: range.lowerBound - raw)
        }
        return raw
    }

    /// The width to settle on when the pointer is released.
    ///
    /// Always a legal width: the band snaps back to the boundary it resisted,
    /// which is why `ColumnSolver.solve` is called with `permitsOvershoot:
    /// false` here even though the drag itself used `true`. Writing the
    /// over-limit width to `UserDefaults` would mean the next launch opened a
    /// window in a state the user never actually asked for.
    static func settled(
        damped: Double,
        range: ClosedRange<Double>
    ) -> Double {
        clamp(damped, to: range)
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        if range.isEmpty { return range.lowerBound }
        return Swift.min(Swift.max(value, range.lowerBound), range.upperBound)
    }
}
