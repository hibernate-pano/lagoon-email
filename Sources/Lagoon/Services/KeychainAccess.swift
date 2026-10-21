import Foundation
import Security

/// The outcome of a Keychain read, with the one distinction that matters.
///
/// ## Why the distinction is not optional
///
/// The old API answered a single question: "did you get a value?" — and a
/// *failure* and a *missing item* both arrived as `nil` (because every call
/// site used `try?`). Those two answers are opposites:
///
/// * **missing** — the user has never connected an account. The right
///   answer is to show the connect screen.
/// * **failed** — the item is *there*, but this process may not read it.
///   The right answer is to tell the user their Keychain needs attention.
///   Showing the connect screen here would tell a user with a working
///   mailbox to re-enter their QQ auth code, and then *overwrite* the
///   stored credentials on the way in.
///
/// The second one also had teeth in the migration path: `migrateLegacyEnvIfNeeded`
/// treated a failed read as "not migrated yet" and wrote `"{}"` over the
/// stored environment — a real value, destroyed by a read that never
/// succeeded. `KeychainRead` makes that impossible to write by accident:
/// the "failed" case is a distinct value that no caller can mistake for
/// "absent".
public enum KeychainRead<Value> {
    /// The item does not exist. This is a normal state, not a failure.
    case missing
    /// The item was read successfully.
    case found(Value)
    /// The item may exist, but this process could not read it.
    ///
    /// "May exist" is the honest wording: a failed read cannot tell the
    /// difference between "not there" and "there but not allowed" — but it
    /// can tell the difference between "not there" and "not readable", and
    /// that is the distinction the callers need.
    case failed(KeychainFailure)

    /// The value, or `nil` when it is missing or unreadable.
    public var value: Value? {
        if case .found(let v) = self { return v }
        return nil
    }

    /// Whether the item is known to be absent.
    ///
    /// Only `true` for `.missing`. A failure is NOT absence: a caller that
    /// wants to write a default must check this, not `value == nil`.
    public var isMissing: Bool {
        if case .missing = self { return true }
        return false
    }

    /// Whether the read failed.
    public var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }

    /// The failure, if this is one.
    public var failure: KeychainFailure? {
        if case .failed(let f) = self { return f }
        return nil
    }
}

/// Equatable when the payload is, so a test can assert on a whole read
/// result in one line.
extension KeychainRead: Equatable where Value: Equatable {}

/// Why a Keychain operation failed, in terms the user can act on.
///
/// The `OSStatus` is kept for the log, never for the UI: a raw status like
/// `-25293` means nothing to a person, and the UI copy is localized.
public enum KeychainFailure: Error, Equatable, Sendable {
    /// The system refused to release the secret without the user's
    /// confirmation, and the confirmation could not be shown.
    ///
    /// This is the failure the ad-hoc-signed build hits on every launch: the
    /// item's ACL is bound to the code signature that created it, a rebuild
    /// mints a new cdhash, and macOS then wants the user to say "yes". The
    /// prompt is raised by a background `SecurityAgent` that has no window,
    /// so from the app's side the call simply never returns.
    case authorizationRequired

    /// The Keychain itself is unavailable (locked, or the daemon is not
    /// answering).
    case unavailable

    /// The stored value could not be decoded.
    case corrupt

    /// Some other failure, with the raw status for the log.
    case unexpected(OSStatus)

    /// Whether this failure is worth offering a "try again" for.
    ///
    /// A retry is only meaningful for the failures that a human can unblock
    /// by answering a dialog or unlocking the Keychain. A corrupt payload
    /// will fail again the same way, so offering a retry there would be
    /// offering a button that cannot work.
    public var isRetryable: Bool {
        switch self {
        case .authorizationRequired, .unavailable: return true
        case .corrupt, .unexpected: return false
        }
    }
}

/// Maps a `SecItem*` status onto a failure the UI can talk about.
///
/// The mapping matters more than it looks. `errSecItemNotFound` is the
/// *only* status that means "there is no item" — everything else means
/// "there might be an item and I could not get it". Collapsing them is
/// exactly the bug this file exists to prevent.
public func keychainFailure(for status: OSStatus) -> KeychainFailure {
    switch status {
    case errSecItemNotFound:
        // Callers check `isMissing` before they ever get here, so reaching
        // this function with "not found" means the caller asked for a
        // failure and the honest answer is "unavailable", not "missing".
        return .unavailable
    case errSecInteractionNotAllowed,
         errSecUserCanceled,
         errSecAuthFailed,
         errSecNotAvailable:
        return .authorizationRequired
    case errSecDecode, errSecInvalidData:
        return .corrupt
    default:
        return .unexpected(status)
    }
}

/// Whether a status means "the item is simply not there".
///
/// A single place, so that the "not there" decision is made once and every
/// caller agrees on it.
public func keychainStatusIsNotFound(_ status: OSStatus) -> Bool {
    status == errSecItemNotFound
}
