import Foundation
import LagoonKit

/// The strings for the "the account row cannot be found" state.
///
/// They live in their own file so the account-related copy can grow without
/// editing `L10n.swift`, which every other feature is also editing.
extension L10n {
    /// The headline for a mailbox this store cannot address.
    ///
    /// Deliberately **not** about the authorization code. The bug this
    /// describes was a store that could not find its own account row, and
    /// the app told the user their authorization code had expired — sending
    /// them to re-enter a code that was perfectly fine, into a form whose
    /// write went nowhere. The headline names the real problem instead, and
    /// names it in terms the user can act on.
    public var healthAccountMissing: String {
        pick("找不到这个邮箱账户 —— 本地数据与账户不一致。",
             "This mailbox account cannot be found — the local data does not match the account.")
    }

    /// The detail for the same state.
    ///
    /// The old banner said "your authorization code expired" — a claim about
    /// the code, made when the code was fine and the row was unreachable.
    /// The detail therefore says where the problem actually is (the local
    /// data, not the code) and what does help: reconnecting rebuilds the
    /// row's state instead of repeating the lookup that failed.
    public var reasonAccountMissing: String {
        pick("问题出在本地账户数据，不是授权码。重新连接可以从邮箱重建这个账户。",
             "The problem is in the local account data, not the authorization code. Reconnecting rebuilds this account from the mailbox.")
    }

    /// The status text for the account list.
    public var syncStatusAccountMissing: String {
        pick("账户丢失", "Account missing")
    }

    /// The capability row for the archive role.
    ///
    /// Lives here rather than in `L10n.swift` for the same reason as the
    /// copy above: it is about a role this store has to negotiate, and the
    /// negotiation is what failed.
    public var archiveSupported: String { pick("归档", "Archive") }

    /// The one-line status name for every `SyncHealth.Status`.
    ///
    /// Moved here from `L10n.swift` because it is a switch over the status
    /// enum: every new case has to be added to it, and adding a case is an
    /// account-shaped change. Keeping it beside the account copy means the
    /// person adding a status edits one file, not two.
    public func healthStatusText(_ status: SyncHealth.Status) -> String {
        switch status {
        case .ok: return pick("同步正常", "Syncing")
        case .degraded: return pick("同步不稳定", "Sync degraded")
        case .needsReconnect: return pick("需要重新连接", "Reconnect needed")
        case .accountMissing: return pick("账户丢失", "Account missing")
        case .error: return pick("同步失败", "Sync failed")
        }
    }
}
