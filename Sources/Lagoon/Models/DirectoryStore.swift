import Foundation
import LagoonKit

/// Client-side account directory (the M1.5 multi-account surface).
///
/// `GET /api/accounts` is the single source of truth for which mailboxes exist
/// and which one is active; this store polls it, exposes the active row for the
/// toolbar/health banner, and performs the activate/delete mutations. It is
/// deliberately separate from `AccountStore`, which only remembers the locally
/// chosen account id in the keychain.
@MainActor
public final class DirectoryStore: ObservableObject {
    @Published public private(set) var accounts: [ConnectedAccount] = []
    @Published public private(set) var loadError: String?

    /// RootView re-polls on this cadence while the window is open. The server
    /// writes health from its sync loop, so a slow poll is enough to notice.
    public static let refreshInterval: Duration = .seconds(30)

    private let api: APIClient

    public init(api: APIClient = APIClient()) {
        self.api = api
    }

    /// The one active account (server invariant: zero or one).
    public var active: ConnectedAccount? {
        accounts.first { $0.isActive }
    }

    /// True when a health problem is worth a banner.
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
    }

    /// Switch the active account. Errors surface as `loadError` rather than
    /// throwing: the menu is a fire-and-forget surface.
    public func activate(_ account: ConnectedAccount) async {
        guard !account.isActive else { return }
        do {
            try await api.activateAccount(id: account.id)
            await refresh()
        } catch {
            loadError = L10n.current.activateAccountFailed + error.lagoonUIMessage
        }
    }

    /// Remove an account (server cascades its messages/pins/drafts).
    public func remove(_ account: ConnectedAccount) async {
        do {
            try await api.deleteAccount(id: account.id)
            await refresh()
        } catch {
            loadError = L10n.current.deleteAccountFailed + error.lagoonUIMessage
        }
    }
}
