import Foundation
import Security

public enum KeychainStore {
    public static func save(accountID: UUID) throws {
        let data = Data(accountID.uuidString.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "lagoon.accountId",
            kSecAttrAccount as String: "primary",
            kSecValueData as String: data
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: "lagoon.keychain", code: Int(status))
        }
    }

    public static func load() -> UUID? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "lagoon.accountId",
            kSecAttrAccount as String: "primary",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let s = String(data: data, encoding: .utf8),
              let uuid = UUID(uuidString: s)
        else { return nil }
        return uuid
    }

    public static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "lagoon.accountId",
            kSecAttrAccount as String: "primary"
        ]
        SecItemDelete(query as CFDictionary)
    }
}