import Foundation

/// Which mailboxes a search covers.
///
/// ## Why this type exists
///
/// The search used to take a **required** `accountId`, which made it a
/// half-feature for anyone with more than one mailbox: the query could only
/// ever reach the active account, and a user who remembers a mail in their
/// other mailbox had no way to find it. Multi-account is a capability the
/// product advertises (add a mailbox, switch between them, sync them
/// concurrently), so "search only sees the mailbox you happen to be looking
/// at" is a promise the search broke.
///
/// ## The wire contract
///
/// The scope travels as one query parameter, `accountId`:
///
/// * a UUID — that mailbox only;
/// * the literal `all` — every connected mailbox;
/// * absent — every connected mailbox (the same as `all`).
///
/// A malformed value is a **bad request**, not a silent "all": a client that
/// sends garbage is a client bug, and answering it with a wide search would
/// hide the bug behind a plausible-looking result list.
///
/// Both the client (which builds the URL) and the server (which parses it)
/// read the contract from here, so the keyword `all` is written down once
/// instead of twice.
public enum SearchScope: Hashable, Sendable {
    /// One mailbox.
    case account(UUID)
    /// Every connected mailbox.
    case allAccounts

    /// The account to narrow to, or nil when the scope covers them all.
    public var accountId: UUID? {
        switch self {
        case .account(let id): return id
        case .allAccounts: return nil
        }
    }

    /// The value that travels in the `accountId` query parameter.
    public var queryValue: String {
        switch self {
        case .account(let id): return id.uuidString
        case .allAccounts: return "all"
        }
    }

    /// Parses the `accountId` query parameter.
    ///
    /// nil when the value is neither the `all` keyword nor a UUID. An absent
    /// parameter is also nil here — the caller decides what "absent" means
    /// (the route answers "every account").
    public static func parse(_ raw: String?) -> SearchScope? {
        guard let raw, !raw.isEmpty else { return nil }
        if raw == allKeyword { return .allAccounts }
        guard let id = UUID(uuidString: raw) else { return nil }
        return .account(id)
    }

    /// The keyword that means "every account".
    public static let allKeyword = "all"
}
