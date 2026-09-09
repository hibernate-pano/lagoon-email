import Foundation
import LagoonKit

@MainActor
public final class AccountStore: ObservableObject {
    @Published public private(set) var accountId: UUID?
    @Published public private(set) var lastSync: SyncResponse?

    public init() {
        self.accountId = KeychainStore.load()
    }

    public func set(accountId: UUID) {
        try? KeychainStore.save(accountID: accountId)
        self.accountId = accountId
    }

    public func setLastSync(_ resp: SyncResponse) {
        self.lastSync = resp
    }

    public func clear() {
        KeychainStore.clear()
        self.accountId = nil
        self.lastSync = nil
    }
}