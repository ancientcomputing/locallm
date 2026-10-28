import Foundation
import Security

/// API keys for remote Jev providers, in the login Keychain. Never written to disk or logs.
///
/// All keys live in **one** Keychain item (a small JSON object keyed by account), read once per
/// launch and cached, so macOS asks for the Keychain password at most once per launch rather than
/// once per hosted backend. (An ad-hoc-signed build counts as a new app after every rebuild, so
/// "Always Allow" doesn't carry over; one item keeps that to one prompt.) Keys saved by earlier
/// versions, one item per backend, are moved into it the first time each is read.
enum Keychain {
    #if MAS_BUILD
    /// The Mac App Store build's own items, so with both builds installed it never finds (and makes
    /// macOS ask about) the DMG build's keys.
    private static let service = "ai.thisbrain.jevdk"
    #else
    private static let service = "JevDK"
    #endif
    /// The one item holding every key.
    private static let bundleAccount = "keys"

    private static let lock = NSLock()
    private static var cache: [String: String]?
    /// Accounts already checked for an old per-backend item this launch.
    private static var migrated: Set<String> = []

    static func get(_ account: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        var keys = loadLocked()
        if let v = keys[account] { return v }
        guard migrated.insert(account).inserted, let old = read(account), !old.isEmpty else { return nil }
        keys[account] = old
        if writeLocked(keys) { delete(account) }
        return old
    }

    static func set(_ value: String?, for account: String) {
        lock.lock(); defer { lock.unlock() }
        var keys = loadLocked()
        keys[account] = (value?.isEmpty ?? true) ? nil : value
        migrated.insert(account)
        _ = writeLocked(keys)
        delete(account)                       // an old per-backend item, if one is left
    }

    private static func loadLocked() -> [String: String] {
        if let cache { return cache }
        let keys = read(bundleAccount)
            .flatMap { try? JSONDecoder().decode([String: String].self, from: Data($0.utf8)) } ?? [:]
        cache = keys
        return keys
    }

    /// Replaces the item. Returns false (and keeps the cache unchanged) if the Keychain refused it.
    private static func writeLocked(_ keys: [String: String]) -> Bool {
        delete(bundleAccount)
        if !keys.isEmpty {
            guard let data = try? JSONEncoder().encode(keys) else { return false }
            let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                      kSecAttrAccount as String: bundleAccount, kSecValueData as String: data]
            guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { return false }
        }
        cache = keys
        return true
    }

    private static func read(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func delete(_ account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }
}
