import Foundation
import LagoonKit

/// Client-side account directory (the M1.5 multi-account surface).
///
/// `GET /api/accounts` is the source of truth for which mailboxes exist and how
/// each one's sync is doing; this store polls it and performs activate/delete
/// mutations. Exactly one account is active; every other account is dormant.
@MainActor
public final class DirectoryStore: ObservableObject {
    @Published public private(set) var accounts: [ConnectedAccount] = []
    @Published public private(set) var loadError: String?
    /// Global AI degraded signal (V2 C1), refreshed with the directory.
    /// Nil before the first poll or when the poll fails — unknown, not down.
    @Published public private(set) var aiStatus: AIStatus?

    /// RootView re-polls on this cadence while the window is open. The server
    /// writes health from its active sync loop, so a slow poll is enough.
    public static let refreshInterval: Duration = .seconds(30)

    private let api: APIClient

    public init(api: APIClient = APIClient()) {
        self.api = api
    }

    /// The server's active account. The fallback keeps the UI usable during the
    /// brief interval before reconciliation or before a fresh account is shown.
    public var active: ConnectedAccount? {
        accounts.first(where: \.isActive) ?? accounts.first
    }

    /// True when a health problem is worth a banner for the viewed account.
    public var needsAttention: Bool {
        guard let active else { return false }
        return active.syncHealth.status != .ok
    }

    public func refresh() async {
        do {
            accounts = try await api.fetchAccounts()
            loadError = nil
        } catch {
            loadError = L10n.current.checkConnectionFailed + error.lagoonUIMessage
        }
        // Best-effort sidecar: a failed status poll keeps the last known
        // value instead of flashing the banner off and on.
        if let status = try? await api.fetchAIStatus() {
            aiStatus = status
        }
    }

    /// Records a status the client already knows — the AI settings sheet
    /// gets one back from the reload it just performed.
    ///
    /// Without this the banner would keep saying "AI 未配置" until the
    /// next poll (up to 30 seconds), so the app would contradict itself a
    /// moment after telling the user the key was live.
    public func applyAIStatus(_ status: AIStatus) {
        aiStatus = status
    }

    /// Select the one account that owns the provider connection. Refresh only
    /// after the server confirms, so the client never shows a switch that did
    /// not actually happen.
    public func activate(_ account: ConnectedAccount) async throws {
        guard !account.isActive else { return }
        do {
            try await api.activateAccount(id: account.id)
            await refresh()
        } catch {
            loadError = L10n.current.activateAccountFailed + error.lagoonUIMessage
            throw error
        }
    }

    /// Remove an account (server cascades its messages/pins/drafts).
    ///
    /// **Throws** instead of recording the failure in `loadError`.
    ///
    /// `loadError` feeds the "the mail list could not be loaded" banner, so
    /// a removal failure parked there would be announced under the wrong
    /// headline — and, worse, it would appear *twice*: once as that banner
    /// and once as the removal's own error, because the removal is a
    /// distinct thing the user did and deserves its own report. Spec
    /// INV-6: one banner at a time, and the right one.
    public func remove(_ account: ConnectedAccount) async throws {
        do {
            try await api.deleteAccount(id: account.id)
            await refresh()
        } catch {
            // A failed removal must not leave the directory stale: the
            // account is still there, and the list has to keep saying so.
            await refresh()
            throw error
        }
    }
}
