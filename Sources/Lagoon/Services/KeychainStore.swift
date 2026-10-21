import Foundation
import Security

/// Typed keychain failures so callers can distinguish "not connected" from
/// "something is actually wrong".
public enum KeychainError: LocalizedError, Sendable {
    case unexpectedStatus(OSStatus)
    case corruptData

    public var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? L10n.current.unknownKeychainError
            return L10n.current.keychainError + "\(message) (\(status))"
        case .corruptData:
            return L10n.current.corruptAccountID
        }
    }
}

/// Where a keychain item lives.
///
/// ## Why there are two locations
///
/// macOS has two unrelated "keychains", and the difference decides whether
/// the app can read its own secrets after a rebuild:
///
/// * the **file-based** keychain (`login.keychain-db`) — the classic one.
///   An item stored there with the default ACL is bound to the *code
///   signature* of the process that created it. A rebuild mints a new
///   cdhash, the stored ACL no longer matches, and macOS then wants the
///   user to confirm the read. The confirmation is raised by a background
///   `SecurityAgent` that has no window, so from the app's side the call
///   simply never returns — the app hangs on the boot screen with the
///   "服务器启动中" spinner and no explanation.
/// * the **data-protection** keychain (`kSecUseDataProtectionKeychain`) —
///   the modern one. Its items are protected by the user's login and the
///   Secure Enclave, and are *not* bound to a code signature, so a
///   rebuilt binary reads them with no prompt at all.
///
/// The data-protection keychain is the right home for this app's secrets.
/// But it is a **different storage location**: an item that exists in one
/// does not exist in the other. So the store reads the new location first,
/// falls back to the old one, and moves the value across — carefully, and
/// never destructively.
public enum KeychainLocation: Sendable, Equatable {
    /// The data-protection keychain. Not bound to a code signature.
    case dataProtection
    /// The file-based keychain (`login.keychain-db`). Legacy.
    case file
}

/// The keychain access layer.
///
/// ## The rule this type exists to enforce
///
/// **A read that cannot be answered must never be reported as "there is
/// nothing there."** Every read returns a `KeychainRead`, whose `.missing`
/// and `.failed` are different values that no caller can confuse. The old
/// API returned `nil` for both (every call site used `try?`), and the
/// migration path then wrote `"{}"` over a stored environment it had never
/// actually read — destroying a real value on the strength of a failed
/// read.
///
/// ## Why a read can be slow, and what is done about it
///
/// `SecItemCopyMatching` with `kSecReturnData` on an item whose ACL does
/// not match the caller blocks forever: macOS wants the user to confirm,
/// and the confirmation is raised by a background agent with no window.
///
/// An **attributes-only** query does not have that problem: it returns the
/// item's metadata without decrypting the secret, and it never prompts.
/// That is the probe this store uses to answer "is there an item here?"
/// without risking a hang — so the app can say "there is a saved account,
/// but this build cannot read it" instead of freezing.
public enum KeychainStore {
    public static let defaultService = "lagoon.accountId"
    private static let account = "primary"

    /// The locations this app reads from, newest first.
    ///
    /// The data-protection keychain comes first because that is where new
    /// values are written. The file-based keychain comes second because
    /// that is where an existing install's values still live.
    static let searchOrder: [KeychainLocation] = [.dataProtection, .file]

    /// The location new values are written to.
    static let writeLocation: KeychainLocation = .dataProtection

    // MARK: - Queries

    private static func baseQuery(service: String, location: KeychainLocation) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if location == .dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    /// The query that identifies an item for deletion.
    ///
    /// Exposed (not `private`) because the migration deletes the old copy
    /// itself — and it must delete **exactly** the item it copied, at
    /// exactly the location it copied from.
    static func deleteQuery(service: String, location: KeychainLocation) -> [String: Any] {
        baseQuery(service: service, location: location)
    }

    // MARK: - Account id

    /// Stores the account id.
    public static func save(accountID: UUID, service: String = defaultService) throws {
        let data = Data(accountID.uuidString.utf8)
        try save(data: data, service: service)
    }

    /// Reads the account id.
    ///
    /// Returns `nil` only when no item exists in any location. A location
    /// that could not be read is a **failure**, and is reported as one:
    /// see `KeychainRead`.
    public static func load(service: String = defaultService) throws -> UUID? {
        switch readRaw(service: service) {
        case .missing:
            return nil
        case .failed(let failure):
            throw failure
        case .found(let data):
            guard let string = String(data: data, encoding: .utf8),
                  let uuid = UUID(uuidString: string)
            else { throw KeychainError.corruptData }
            return uuid
        }
    }

    public static func clear(service: String = defaultService) throws {
        for location in searchOrder {
            let status = SecItemDelete(baseQuery(service: service, location: location) as CFDictionary)
            // "Not entitled to this keychain" is not a failed delete on a
            // location that holds data — it is a location this build can
            // never have written to (its writes take the same status and
            // fall back). Treating it as an error would make Disconnect
            // throw on the first location and never reach the second,
            // leaving the user connected to an account they asked to
            // remove.
            if status == errSecMissingEntitlement, location == .dataProtection {
                continue
            }
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError.unexpectedStatus(status)
            }
        }
    }

    // MARK: - Generic string secrets (embedded runtime keys)

    /// Stores an arbitrary string secret (the AES key base64, the API token,
    /// the migrated AI environment). Same generic-password class, distinct
    /// service per secret.
    public static func saveString(_ value: String, service: String) throws {
        try save(data: Data(value.utf8), service: service)
    }

    /// Reads a string secret.
    ///
    /// `nil` means "no item exists". A failure throws — it never returns
    /// `nil`, because `nil` is the answer to a different question.
    public static func loadString(service: String) throws -> String? {
        switch readRaw(service: service) {
        case .missing:
            return nil
        case .failed(let failure):
            throw failure
        case .found(let data):
            guard let string = String(data: data, encoding: .utf8) else {
                throw KeychainError.corruptData
            }
            return string
        }
    }

    // MARK: - Raw read / write

    /// Reads the raw bytes for a service, searching both locations.
    ///
    /// The order is: data-protection first, then the file-based keychain.
    /// The first location that *has* the item wins; a location that could
    /// not be read is remembered and reported **only** if no location
    /// produced a value — because a failure in the first location is
    /// exactly the case where the caller must not conclude "there is
    /// nothing there".
    static func readRaw(service: String) -> KeychainRead<Data> {
        var firstFailure: KeychainFailure?
        for location in searchOrder {
            let result = readRaw(service: service, location: location)
            switch result {
            case .found(let data):
                return .found(data)
            case .missing:
                continue
            case .failed(let failure):
                if firstFailure == nil { firstFailure = failure }
                continue
            }
        }
        if let firstFailure {
            return .failed(firstFailure)
        }
        return .missing
    }

    /// Reads the raw bytes from one specific location.
    static func readRaw(service: String, location: KeychainLocation) -> KeychainRead<Data> {
        var query = baseQuery(service: service, location: location)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if keychainStatusIsNotFound(status) {
            return .missing
        }
        // `errSecMissingEntitlement` on the data-protection keychain means
        // *this build* may not use that keychain at all — an ad-hoc bundle
        // has no `keychain-access-groups`. Report it as "not here" rather
        // than as a failure: a failure would make a first launch look like
        // a broken Keychain and suppress the one-time key generation, and
        // no build that gets this status could have written an item there
        // (its writes take the same error and fall back to the file
        // keychain).
        if status == errSecMissingEntitlement, location == .dataProtection {
            return .missing
        }
        guard status == errSecSuccess else {
            return .failed(keychainFailure(for: status))
        }
        guard let data = item as? Data else {
            return .failed(.corrupt)
        }
        return .found(data)
    }

    /// Whether an item exists in a location — **without** reading it.
    ///
    /// This is the non-blocking probe. An attributes-only query returns the
    /// item's metadata without decrypting the secret, and it never raises
    /// the authorization prompt, so it cannot hang. It is how the app
    /// distinguishes "there is a saved account, but this build is not
    /// allowed to read it" from "there is no saved account" — a
    /// distinction the data-reading query cannot make, because asking for
    /// the data is what triggers the prompt.
    static func itemExists(service: String, location: KeychainLocation) -> Bool {
        var query = baseQuery(service: service, location: location)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return status == errSecSuccess
    }

    /// Writes the raw bytes to the app's write location, with one fallback.
    ///
    /// ## Why a fallback, and why only for this status
    ///
    /// The data-protection keychain needs the `keychain-access-groups`
    /// entitlement, and this bundle is ad-hoc signed — no team, no
    /// entitlement. On the machine that reported the hang, every
    /// data-protection write returned `-34018` (`errSecMissingEntitlement`),
    /// confirmed both from a bare binary and from inside an ad-hoc-signed
    /// `.app`. Without a fallback the first launch would fail to store the
    /// account at all, so a user who is *not* hitting the hang would still
    /// be unable to connect.
    ///
    /// The fallback is deliberately narrow. It fires only for "this process
    /// is not entitled to this keychain", which is a property of the build
    /// and is what the old location is for. A failure to *update* or a
    /// transient error still throws: silently moving a value to the weaker
    /// location on an unrelated error would be the wrong trade.
    private static func save(data: Data, service: String) throws {
        do {
            try save(data: data, service: service, location: writeLocation)
        } catch KeychainError.unexpectedStatus(errSecMissingEntitlement) where writeLocation != .file {
            try save(data: data, service: service, location: .file)
        }
    }

    /// Writes the raw bytes to a specific location (used by the migration).
    static func save(data: Data, service: String, location: KeychainLocation) throws {
        let query = baseQuery(service: service, location: location)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        // Update in place when the item exists; only add on the first save.
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.unexpectedStatus(updateStatus)
        }
    }
}
