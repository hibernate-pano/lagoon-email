import Foundation
import LagoonKit

@MainActor
public final class AccountStore: ObservableObject {
    @Published public private(set) var accountId: UUID?
    @Published public private(set) var lastSync: SyncResponse?
    @Published public private(set) var loadError: String?

    private let service: String

    public init(service: String = KeychainStore.defaultService) {
        self.service = service
        do {
            self.accountId = try KeychainStore.load(service: service)
        } catch {
            self.accountId = nil
            self.loadError = L10n.current.readSavedAccountFailed + error.localizedDescription
        }
    }

    /// Persists first, then updates state. If the keychain write fails the
    /// in-memory account stays unchanged and the error propagates to the view.
    public func set(accountId: UUID) throws {
        try KeychainStore.save(accountID: accountId, service: service)
        self.accountId = accountId
    }

    public func setLastSync(_ resp: SyncResponse) {
        self.lastSync = resp
    }

    /// Surfaces keychain failures instead of silently ignoring them. State is
    /// only cleared after the keychain delete succeeds.
    public func clear() throws {
        try KeychainStore.clear(service: service)
        self.accountId = nil
        self.lastSync = nil
    }
}
