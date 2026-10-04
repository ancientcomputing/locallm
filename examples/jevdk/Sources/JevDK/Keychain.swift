import Foundation
import Security

/// API keys for remote Jev providers, in the login Keychain. Never written to disk or logs.
enum Keychain {
    private static let service = "JevDK"
    /// The app's earlier names (AskJev, then JevLab); keys saved under them move across on first read.
    private static let formerServices = ["JevLab", "AskJev"]

    static func get(_ account: String) -> String? {
        if let value = read(account, service: service) { return value }
        for former in formerServices {
            guard let old = read(account, service: former) else { continue }
            set(old, for: account)
            delete(account, service: former)
            return old
        }
        return nil
    }

    static func set(_ value: String?, for account: String) {
        delete(account, service: service)
        guard let value, !value.isEmpty else { return }
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                  kSecAttrAccount as String: account, kSecValueData as String: Data(value.utf8)]
        SecItemAdd(add as CFDictionary, nil)
    }

    private static func read(_ account: String, service: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func delete(_ account: String, service: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }
}
