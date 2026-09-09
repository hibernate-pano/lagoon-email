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
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown keychain error"
            return "Keychain error: \(message) (\(status))"
        case .corruptData:
            return "Keychain error: stored account id is not a valid UUID."
        }
    }
}

public enum KeychainStore {
    public static let defaultService = "lagoon.accountId"
    private static let account = "primary"

    private static func baseQuery(service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    public static func save(accountID: UUID, service: String = defaultService) throws {
        let data = Data(accountID.uuidString.utf8)
        let query = baseQuery(service: service)
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

    /// Returns `nil` only when no item exists. Any other failure or a corrupt
    /// (non-UUID) payload throws `KeychainError`.
    public static func load(service: String = defaultService) throws -> UUID? {
        var query = baseQuery(service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let string = String(data: data, encoding: .utf8),
                  let uuid = UUID(uuidString: string)
            else { throw KeychainError.corruptData }
            return uuid
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public static func clear(service: String = defaultService) throws {
        let status = SecItemDelete(baseQuery(service: service) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
