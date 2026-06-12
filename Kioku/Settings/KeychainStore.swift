import Foundation
import Security

// Minimal Keychain-backed string storage for app secrets (API keys, bridge token).
// Secrets must not live in UserDefaults: its plist is unencrypted on disk and is
// captured by unencrypted device backups. Items are stored as generic passwords
// scoped to this app, accessible after first unlock so background features
// (bridge, scheduled work) can still read them.
//
// `nonisolated` because secret readers include free-standing actors (JimakuProvider)
// and the bridge server; the Security framework calls themselves are thread-safe.
nonisolated enum KeychainStore {
    private static let service = "app.kioku.secrets"

    // Reads the secret for the account, migrating any legacy UserDefaults value
    // on first access. Migration deletes the plaintext copy after the Keychain
    // write succeeds so the old value cannot linger in backups.
    static func string(forKey key: String, migratingFromUserDefaultsKey legacyKey: String? = nil) -> String? {
        if let existing = read(key) {
            return existing.isEmpty ? nil : existing
        }
        if let legacyKey,
           let legacyValue = UserDefaults.standard.string(forKey: legacyKey),
           legacyValue.isEmpty == false {
            if write(legacyValue, forKey: key) {
                UserDefaults.standard.removeObject(forKey: legacyKey)
            }
            return legacyValue
        }
        return nil
    }

    // Stores or clears the secret. An empty/nil value removes the item entirely
    // so "clearing a key" in the UI leaves nothing behind in the Keychain.
    @discardableResult
    static func setString(_ value: String?, forKey key: String) -> Bool {
        guard let value, value.isEmpty == false else {
            return delete(key)
        }
        return write(value, forKey: key)
    }

    // MARK: - Security framework plumbing

    // Builds the class/service/account triple every Keychain call starts from.
    private static func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    // Fetches the stored UTF-8 string for the account, nil when absent.
    private static func read(_ key: String) -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // Adds the item, falling back to an in-place update when it already exists.
    private static func write(_ value: String, forKey key: String) -> Bool {
        let data = Data(value.utf8)
        var attributes = baseQuery(for: key)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            let update: [String: Any] = [kSecValueData as String: data]
            return SecItemUpdate(baseQuery(for: key) as CFDictionary, update as CFDictionary) == errSecSuccess
        }
        return addStatus == errSecSuccess
    }

    // Removes the item; "not found" counts as success so clears are idempotent.
    @discardableResult
    private static func delete(_ key: String) -> Bool {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
