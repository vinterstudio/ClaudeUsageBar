import Foundation

/// Read-only access to the Claude Code OAuth credentials stored in the macOS
/// login keychain under the generic-password service "Claude Code-credentials".
/// This is the same item Claude Code itself uses. We only ever read it — Claude
/// Code is the sole writer/refresher, so the item's access list never gets reset.
enum Keychain {
    static let service = "Claude Code-credentials"

    /// When the item was last written, or nil if absent.
    ///
    /// This is an attributes-only query: it does NOT request the secret, so the
    /// keychain access-control list is never consulted and the user is never
    /// prompted. Probed 2026-09-09 — an unsigned binary gets OSStatus 0 and the
    /// date with no dialog. That lets us detect a token rotation for free and
    /// read the secret only when there is actually something new to read.
    static func modificationDate() -> Date? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let attrs = item as? [String: Any]
        else { return nil }
        return attrs[kSecAttrModificationDate as String] as? Date
    }

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
