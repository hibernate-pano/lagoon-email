import Foundation

/// The "this list is shorter than the mailbox" caveat, as one decision.
///
/// ## Why this is a type and not a private computed property in each sheet
///
/// Both bulk sheets had their own copy of the same guard:
///
/// ```swift
/// guard let total = serverTotalCount, total > messages.count else { return nil }
/// return l10n.listTruncated(messages.count, total)
/// ```
///
/// which is exactly the shape that drifts. `SenderSheet` defaulted `totalCount`
/// to `messages.count` on load while `StackMailSheet` kept it optional, and the
/// list-side number had to be compared against the *loaded* rows rather than the
/// filtered view — two different notions of "shown" in the same sentence.
///
/// And because the rule lived inside a `private var`, the test that claimed to
/// guard it could only **reimplement** it — at which point changing the
/// production threshold left the test green. That is the "验证替身" failure this
/// project has now paid for three times: a test that restates the rule can only
/// ever catch a change to the restatement.
///
/// Extracting it means the production sheets and the test execute *the same
/// function*, so a regression in the threshold turns the test red.
///
/// ## The rule
///
/// Non-nil exactly when the server reported a total larger than the rows on
/// screen. An unknown total is not a truncation — a nil `total` means the
/// server declined to say, and inventing a number there is the same lie as
/// claiming a partial list is complete.
enum ListTruncationNotice {
    /// - Parameters:
    ///   - shown: rows the user can actually see and act on.
    ///   - total: the server's count for the same filter, or nil if unknown.
    static func text(shown: Int, total: Int?, l10n: L10n) -> String? {
        guard let total, total > shown else { return nil }
        return l10n.listTruncated(shown, total)
    }
}
