import Foundation

/// The monthly AI cost cap: what counts as a usable number, and how it
/// becomes the integer the budget enforces.
///
/// ## Why the conversion lives here
///
/// The cap is stored in micro-USD so the arithmetic is exact — and
/// `Int64(value * 1_000_000)` **traps** on a non-finite value. A cap of
/// "inf" typed into the settings panel was therefore not a rejected
/// number but a process kill: the server died, and the app with it. The
/// conversion has one home, and it refuses what it cannot express.
///
/// ## Why the client and the server share it
///
/// The client validates the field before it is stored, and the server
/// validates it again before it is applied. Two definitions of "usable"
/// would be free to disagree, and the disagreement would show up as a
/// save that the server refuses for no reason the user can see. One
/// definition, two callers.
public enum AIBudget {
    /// The largest monthly cap that can be stored and enforced.
    ///
    /// A million dollars a month is already far past anything real. The
    /// bound exists so the number has a ceiling that both sides of the
    /// wire can check.
    public static let maximumCapUSD: Double = 1_000_000

    /// Whether a cap is usable: a real number, not negative, and within
    /// the ceiling.
    public static func isValidCap(_ value: Double) -> Bool {
        value.isFinite && value >= 0 && value <= maximumCapUSD
    }

    /// The cap in micro-USD, or nil when the value is not a usable cap.
    ///
    /// The conversion is the one that used to trap, so it is the one that
    /// checks first — and an unusable cap reads as "no cap" rather than a
    /// crash.
    public static func micros(_ value: Double) -> Int64? {
        guard isValidCap(value) else { return nil }
        return Int64((value * 1_000_000).rounded())
    }
}
