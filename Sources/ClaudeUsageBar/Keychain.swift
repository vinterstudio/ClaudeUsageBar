import Foundation

/// Read-only access to the Claude Code OAuth credentials stored in the macOS
/// login keychain under the generic-password service "Claude Code-credentials".
/// This is the same item Claude Code itself uses. We only ever read it — Claude
/// Code is the sole writer/refresher, so the item's access list never gets reset.
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
}
