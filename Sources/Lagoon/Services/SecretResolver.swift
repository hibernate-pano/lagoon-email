import Foundation
import Security

/// The failures a secret resolution can report.
public enum DeferredSecretError: LocalizedError, Equatable, Sendable {
    /// The secret did not arrive in time.
    ///
    /// Almost always means the Keychain is waiting for an authorization
    /// that the user cannot see.
    case timedOut
    /// The secret could not be resolved at all.
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .timedOut:
            return L10n.current.secretResolutionTimedOut
        case .unavailable:
            return L10n.current.keychainAuthorizationRequired
        }
    }
}

/// The value the server uses for a key that has not been resolved yet.
///
/// A distinct, obviously-fake 32-byte key. It is deliberately *not* a
/// plausible-looking random key: `Data(count: 32)` of zeros is
/// unmistakable as a placeholder, whereas a plausible key that fails to
/// decrypt reads as "the database is corrupted" — a completely wrong
/// diagnosis, and one that sends the user hunting for a problem that is
/// not there.
public enum PlaceholderSecret {
    /// The 32 bytes used for a key that has not resolved yet.
    public static let bytes = Data(repeating: 0, count: 32)

    /// The base64 form the runtime configuration carries.
    public static let keyBase64 = bytes.base64EncodedString()

    /// Whether a base64 string is the placeholder.
    ///
    /// The runtime uses this to tell "still resolving" apart from "the
    /// user has a genuinely wrong key", so the two get different answers.
    public static func isPlaceholder(_ value: String) -> Bool {
        value == keyBase64
    }
}
