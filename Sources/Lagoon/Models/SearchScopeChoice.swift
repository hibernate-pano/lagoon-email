import Foundation
import LagoonKit

/// Which mailboxes the search covers, as the *user* chose it.
///
/// The wire form of a scope is `SearchScope` (LagoonKit, shared with the
/// server). This type is the client's own vocabulary for the same choice:
/// what the picker offers, and what it remembers between launches.
///
/// The two are deliberately separate. `SearchScope` names an account by id
/// — it is a *query*. `SearchScopeChoice` names a choice — "the mailbox I
/// am looking at" or "every mailbox" — and the client resolves it against
/// the live account list at the moment of the search. That distinction
/// matters when the active account changes: a stored "current account"
/// choice must follow the *new* current account, not the one it meant when
/// it was stored.
enum SearchScopeChoice: String, CaseIterable, Identifiable, Sendable {
    /// The mailbox the user is currently looking at.
    case active
    /// Every connected mailbox.
    case all

    var id: String { rawValue }

    /// The scope this choice resolves to, given the active account.
    ///
    /// With no active account there is no mailbox to narrow to, so the
    /// scope is "every mailbox" — which is also the honest answer before
    /// the Keychain read finishes.
    func scope(activeAccountId: UUID?) -> SearchScope {
        switch self {
        case .active:
            guard let activeAccountId else { return .allAccounts }
            return .account(activeAccountId)
        case .all:
            return .allAccounts
        }
    }
}
