import Foundation

/// Reads and writes the Claude Code OAuth credentials stored in the macOS
/// login keychain under the generic-password service "Claude Code-credentials".
/// This is the same item Claude Code itself uses, so refreshed tokens stay in sync.
enum Keychain {
    static let service = "Claude Code-credentials"

    /// Raw JSON string stored in the keychain item, or nil if not present.
    static func readRaw() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Overwrites the keychain item's value, preserving the existing account name.
    @discardableResult
    static func writeRaw(_ json: String) -> Bool {
        guard let data = json.data(using: .utf8) else { return false }
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        let attrs: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(match as CFDictionary, attrs as CFDictionary)
        if status == errSecSuccess { return true }
        // If it doesn't exist yet, add it.
        if status == errSecItemNotFound {
            var add = match
            add[kSecValueData as String] = data
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return false
    }
}
