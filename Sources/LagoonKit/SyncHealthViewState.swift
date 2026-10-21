import Foundation

/// UI-facing projection of `SyncHealth` (spec §4.1). Splits `status == .ok`
/// into two render states — `ok` (the user has at least one successful
/// sync) and `syncing` (the account exists but has never completed a
/// round) — so the banner can show a neutral "first sync in progress"
/// message instead of hiding the row entirely.
public enum SyncHealthViewState: Equatable, Sendable {
    case ok
    case syncing
    case degraded(reason: String)
    case error(reason: String)
    case needsReconnect(reason: String)
    /// The account row could not be found. A distinct state from
    /// `needsReconnect`, because the remedy is different: a code that is
    /// already wrong will not be fixed by entering it again.
    case accountMissing(reason: String)

    /// Map the wire model to the UI state. The reason is the server's
    /// `lastError` when present, or `"—"` so the banner always has
    /// something to show.
    public static func from(_ health: SyncHealth) -> SyncHealthViewState {
        switch health.status {
        case .ok where health.lastSyncAt == nil: return .syncing
        case .ok: return .ok
        case .degraded: return .degraded(reason: health.lastError ?? "—")
        case .error: return .error(reason: health.lastError ?? "—")
        case .needsReconnect: return .needsReconnect(reason: health.lastError ?? "—")
        case .accountMissing: return .accountMissing(reason: health.lastError ?? "—")
        }
    }
}
