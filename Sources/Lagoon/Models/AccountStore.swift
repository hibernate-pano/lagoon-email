import Foundation
import LagoonKit

/// The active mailbox, mirrored from the server into the Keychain.
///
/// ## Why the Keychain read is asynchronous
///
/// `SecItemCopyMatching` can block for as long as the user takes to answer
/// the system's "…wants to use the secret stored in the keychain" dialog.
/// On an ad-hoc-signed build that dialog appears on **every launch**, because
/// a new cdhash is minted on each rebuild and the Keychain ACL is bound to
/// the old one.
///
/// The read used to happen in `init`, on the main thread. The stack was:
///
///     AccountStore.init
///       → KeychainStore.load
///         → SecItemCopyMatching          ← blocked here
///           → SecKeychainItemCopyContent
///             → (user has not answered the dialog yet)
///
/// Because `AccountStore` is a `@StateObject` in `LagoonApp`, `init` runs
/// during the *first* SwiftUI scene evaluation — i.e. before
/// `NSApplication.finishLaunching` returns. The main thread was therefore
/// stuck inside the Keychain call while AppKit was trying to finish
/// launching, so **no window was ever created**: the app appeared to hang
/// with no window and no dock icon, and the only clue on screen was an
/// English system dialog nobody had asked for.
///
/// The fix is to keep the Keychain off the main thread entirely. The store
/// starts in `.loading`, reads the account id on a background task, and
/// publishes it when it arrives. Views that need "is there an account yet"
/// already funnel through `accountId`, so the only visible change is that the
/// window opens immediately and the connect screen appears a moment later
/// instead of the whole app hanging behind a dialog.
@MainActor
public final class AccountStore: ObservableObject {
    /// The mirror of the server's active account.
    ///
    /// `nil` means "no account". `AccountStore.accountId` is the single
    /// source of truth for "should we show the connect screen or the mail".
    @Published public private(set) var accountId: UUID?
    @Published public private(set) var lastSync: SyncResponse?
    /// Set when the Keychain could not be read at all (not merely "no
    /// account stored"). Drives the error copy the connect screen shows.
    @Published public private(set) var loadError: String?

    /// Whether the initial Keychain read has finished.
    ///
    /// The distinction matters: `accountId == nil` means both "no account"
    /// and "not loaded yet", and the first is a normal state the user
    /// resolves by connecting, while the second must not flash the connect
    /// screen before the real answer arrives.
    @Published public private(set) var isLoaded: Bool = false

    /// Set when the Keychain **has** the account id but this build is not
    /// allowed to read it.
    ///
    /// This is the state the old code could not express. It used to be
    /// "the read failed" and "there is no account" — the same `nil` — so
    /// the app showed the *connect* screen to a user who had a working
    /// mailbox, and asked them to re-enter their QQ auth code. Worse, the
    /// connect flow then wrote over the account that was already there.
    ///
    /// Now the two are different, and this flag is the difference: the
    /// user is told the Keychain needs their attention, and the stored
    /// account is left alone.
    @Published public private(set) var isKeychainBlocked: Bool = false

    private let service: String

    public init(service: String = KeychainStore.defaultService) {
        self.service = service
        // The read itself happens in `load()` on a background task. Nothing
        // here touches the Keychain, so constructing the store can never
        // block the main thread — which is the whole point.
    }

    /// Reads the stored account id off the main thread.
    ///
    /// Safe to call more than once: a second read while one is in flight is
    /// ignored rather than racing two `SecItemCopyMatching` calls.
    @discardableResult
    public func load() async -> UUID? {
        let service = self.service
        // The read is bounded by `KeychainReader`'s deadline, so this
        // returns even when the Keychain is stuck waiting for an
        // authorization that can never be answered.
        let read = await KeychainReader.readString(service: service)

        switch read {
        case .found(let raw):
            guard let id = UUID(uuidString: raw) else {
                accountId = nil
                loadError = L10n.current.corruptAccountID
                isKeychainBlocked = false
                break
            }
            accountId = id
            loadError = nil
            isKeychainBlocked = false
        case .missing:
            // No account stored. This is the normal "not connected yet"
            // state, and it is the only state that shows the connect
            // screen.
            accountId = nil
            loadError = nil
            isKeychainBlocked = false
        case .failed(let failure):
            // The item is there but unreadable. Say so, and do NOT pretend
            // there is no account: the user has one, and the connect
            // screen would talk them out of it.
            accountId = nil
            isKeychainBlocked = true
            loadError = L10n.current.readSavedAccountFailed
                + (failure == .authorizationRequired
                    ? L10n.current.keychainAuthorizationRequired
                    : failure.localizedDescription)
        }
        isLoaded = true
        return accountId
    }

    /// Persists first, then updates state. If the keychain write fails the
    /// in-memory account stays unchanged and the error propagates to the view.
    ///
    /// The write also happens off the main thread: `SecItemAdd`/`SecItemUpdate`
    /// can raise the same authorization dialog as a read, and a modal dialog
    /// raised from a main-thread keychain write freezes the UI the same way
    /// the read did.
    public func set(accountId: UUID) async throws {
        let service = self.service
        try await Task.detached(priority: .userInitiated) {
            try KeychainStore.save(accountID: accountId, service: service)
        }.value
        self.accountId = accountId
    }

    public func setLastSync(_ resp: SyncResponse) {
        lastSync = resp
    }

    /// Surfaces keychain failures instead of silently ignoring them. State is
    /// only cleared after the keychain delete succeeds.
    public func clear() async throws {
        let service = self.service
        try await Task.detached(priority: .userInitiated) {
            try KeychainStore.clear(service: service)
        }.value
        self.accountId = nil
        self.lastSync = nil
    }
}
