import Foundation
import Security

/// Thin wrapper over the login keychain (from Cued). Holds each account's OAuth
/// refresh token — the only long-lived secret in the app.
enum Keychain {

    /// Values already read this launch.
    ///
    /// Every `SecItemCopyMatching` on an ad-hoc-signed build can raise the
    /// "wants to use your confidential information" panel, because the item's
    /// ACL was written against a code identity that no longer matches. Reading
    /// once per launch turns a stream of prompts into at most one.
    private nonisolated(unsafe) static var cache: [String: String] = [:]
    private static let cacheLock = NSLock()

    static func set(_ value: String, for account: String) {
        cacheLock.lock()
        cache[account] = value
        cacheLock.unlock()
        write(value, for: account)
    }

    private static func write(_ value: String, for account: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Config.keychainService,
            kSecAttrAccount as String: account
        ]
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        // Delete then add — never `SecItemUpdate` on its own.
        //
        // An update changes the stored value but *keeps the item's existing
        // access list*. So an item first written by a differently signed build
        // — an unsigned `swift run`, an ad-hoc build — goes on asking for the
        // login-keychain password forever, however many times you sign in
        // again, because every re-authorisation only ever updated it.
        // Re-creating the item binds its access list to the app doing the
        // writing, which is what stops the prompts.
        SecItemDelete(query as CFDictionary)
        if SecItemAdd(insert as CFDictionary, nil) != errSecSuccess {
            // Should not happen straight after a delete, but never leave the
            // token missing: an update matches nothing once the item is
            // gone, so the add is simply tried again.
            if SecItemAdd(insert as CFDictionary, nil) != errSecSuccess {
                NSLog("Postline: keychain add failed twice for \(account)")
                lastWriteFailed = true
                return
            }
        }
        lastWriteFailed = false
    }

    /// True when the most recent `write` could not store the item.
    private static var lastWriteFailed = false

    /// Set once the stored token has been re-created under this app's
    /// signature. Persisted, so the repair is one delete-and-add in the app's
    /// lifetime rather than one on every launch — the window between the
    /// delete and the add is the only moment the token could be lost.
    private static let reboundKey = "keychain.acl.rebound.v1"

    /// Re-creates an item that an older, differently signed build left behind.
    ///
    /// Costs one last password prompt — the read that gets us the value — and
    /// then the item belongs to this app and macOS stops asking.
    private static func rebindIfNeeded(_ value: String, for account: String) {
        guard !UserDefaults.standard.bool(forKey: reboundKey) else { return }
        write(value, for: account)
        // Marked done only once the item is really back under this app's
        // signature; a failed rebind is retried next time instead of being
        // recorded as finished.
        if !lastWriteFailed { UserDefaults.standard.set(true, forKey: reboundKey) }
    }

    static func get(_ account: String) -> String? {
        cacheLock.lock()
        if let cached = cache[account] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let value = read(account)
        if let value {
            cacheLock.lock()
            cache[account] = value
            cacheLock.unlock()
            rebindIfNeeded(value, for: account)
        }
        return value
    }

    private static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Config.keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ account: String) {
        cacheLock.lock()
        cache.removeValue(forKey: account)
        cacheLock.unlock()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Config.keychainService,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
