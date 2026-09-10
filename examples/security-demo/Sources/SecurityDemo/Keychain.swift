import Foundation
import Security

// Keychain-backed string storage for this example's API keys. A credential belongs in the
// Keychain — encrypted at rest, access-controlled by the OS, scoped to this app's identity —
// not in `UserDefaults`, which is a plaintext plist anything in your home folder can read.
//
// The SDK's own `KeychainGenericPassword` is `internal`, so an example keeps its own tiny copy.
// This is the whole of it: a generic-password item per account, under one service string.

enum Keychain {
    private static let service = "lab.locallm.sdk.reference.securitydemo"

    static func string(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Store `value`, or pass `nil` to delete. Replaces any existing item for `account`.
    @discardableResult
    static func set(_ value: String?, for account: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)   // idempotent: fine if nothing was there

        guard let data = value?.data(using: .utf8) else { return true }   // nil ⇒ delete only

        var attributes = base
        attributes[kSecValueData as String] = data
        // Available whenever the Mac is unlocked; not synced to iCloud.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }
}
