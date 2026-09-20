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
    public func remove(_ account: ConnectedAccount) async {
        do {
            try await api.deleteAccount(id: account.id)
            await refresh()
        } catch {
            loadError = L10n.current.deleteAccountFailed + error.lagoonUIMessage
        }
    }
}
