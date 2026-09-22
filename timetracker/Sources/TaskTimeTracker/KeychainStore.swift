import Foundation
import Security

/// Stores the OpenAI API key in the macOS Keychain (not a plain file) —
/// this is the only piece of the app that talks to a network, and it does
/// nothing at all until you set a key here. No key set = the AI features
/// are completely inert.
enum KeychainStore {
    private static let service = "TaskTimeTracker"
    private static let account = "openai-api-key"

    static func getAPIKey() -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func setAPIKey(_ key: String) -> Bool {
        let data = Data(key.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if getAPIKey() != nil {
            let update: [String: Any] = [kSecValueData as String: data]
            return SecItemUpdate(base as CFDictionary, update as CFDictionary) == errSecSuccess
        } else {
            var add = base
            add[kSecValueData as String] = data
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
    }

    static func clearAPIKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
