import Foundation
import LagoonKit

/// Records that the user acted on a suggestion.
///
/// ## Why this exists
///
/// `AdviceDecision.accepted` is the learning loop the constitution describes
/// (Phase 4): accepted and rejected suggestions accumulate as **read-only**
/// preferences, used to improve later suggestions. Until something writes
/// that column it is empty — and an empty column is not a learning loop, it
/// is a log nobody reads. The `dismissed` half had a write path all along;
/// this is the other half.
///
/// ## The rule
///
/// A verdict is recorded only when the action the user actually performed
/// **is** the action the suggestion advised. Two things that keeps honest:
///
/// * A *dismissed* suggestion is never re-decided. The user already said
///   "no"; overwriting that with a "yes" they never gave would be the
///   opposite of learning.
/// * A mismatched action is not an acceptance. The user archiving a message
///   the AI said to *reply* to is not agreeing with the AI — they are doing
///   something else. Counting it would teach the model that "reply" means
///   "archive".
///
/// ## Why the write is best-effort
///
/// The mail action already happened by the time this runs, and for
/// `.unsubscribe` it is irreversible (the publisher has already been told).
/// Failing the user's action because a *preference* could not be written
/// would trade a real thing for a bookkeeping detail. So a failure is
/// returned to the caller — which shows it — and logged; it never undoes
/// the action.
enum AdviceAcceptance {
    /// The verdict to record after the user performed `performedAction`, or
    /// nil when nothing should be recorded.
    static func verdict(
        for advice: AdviceRecord?,
        performedAction: AdvisedAction
    ) -> AdviceDecision? {
        guard let advice else { return nil }
        guard advice.decision == .pending else { return nil }
        guard advice.advice.action == performedAction else { return nil }
        return .accepted
    }
}

/// Writes the `accepted` verdict for a suggestion the user acted on.
///
/// A thin wrapper over `APIClient.setAdviceDecision` that owns the
/// best-effort contract: it returns the failure instead of throwing, so no
/// call site can accidentally let a preference write take the mail action
/// down with it.
enum AdviceAcceptanceRecorder {
    /// Records the acceptance. Returns the failure, or nil on success — and
    /// nil also when there was nothing to record.
    @discardableResult
    static func record(
        advice: AdviceRecord?,
        performedAction: AdvisedAction,
        accountId: UUID,
        api: APIClient = .shared
    ) async -> Error? {
        guard let advice,
              AdviceAcceptance.verdict(
                for: advice, performedAction: performedAction
              ) == .accepted
        else { return nil }
        do {
            _ = try await api.setAdviceDecision(
                id: advice.id, decision: .accepted, accountId: accountId
            )
            return nil
        } catch {
            // Logged *and* returned. The mail action already succeeded, so
            // this must not fail it — but it must not disappear either: a
            // preference that silently stops being written is exactly how the
            // learning loop looked before this existed.
            NSLog(
                "lagoon: advice %lld was acted on but the acceptance could not be recorded: %@",
                advice.id,
                String(describing: error)
            )
            return error
        }
    }
}
