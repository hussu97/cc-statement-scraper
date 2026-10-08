import Foundation
import Security
import Supabase

/// Supabase's auth session, kept in a keychain access group the app, the App
/// Intent and the Share Extension all hold — so the intent can post an SMS
/// while the app is not running.
///
/// Accessibility is `afterFirstUnlock`: a Shortcuts automation fires on a
/// locked phone, and the intent must still read the session then.
///
/// If the access group is not in the binary's entitlements (an unsigned
/// simulator build reports `errSecMissingEntitlement`), the item is stored
/// without one so the app still works on its own.
public final class SharedKeychainStorage: AuthLocalStorage, @unchecked Sendable {
    private let service: String
    private let accessGroup: String?
    private let lock = NSLock()
    private var groupUnavailable = false

    public init(service: String = "ledger.supabase.auth", accessGroup: String?) {
        self.service = service
        self.accessGroup = accessGroup
    }

    public func store(key: String, value: Data) throws {
        try withGroupFallback { group in
            let query = baseQuery(key: key, group: group)
            let update: [String: Any] = [
                kSecValueData as String: value,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            if status == errSecItemNotFound {
                var add = query
                add.merge(update) { $1 }
                status = SecItemAdd(add as CFDictionary, nil)
            }
            return status
        }
    }

    public func retrieve(key: String) throws -> Data? {
        var result: Data?
        try withGroupFallback { group in
            var query = baseQuery(key: key, group: group)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecItemNotFound { return errSecSuccess }
            result = item as? Data
            return status
        }
        return result
    }

    public func remove(key: String) throws {
        try withGroupFallback { group in
            let status = SecItemDelete(baseQuery(key: key, group: group) as CFDictionary)
            return status == errSecItemNotFound ? errSecSuccess : status
        }
    }

    // MARK: -

    public struct KeychainError: Error, CustomStringConvertible {
        public let status: OSStatus
        public var description: String { "Keychain error \(status)" }
    }

    private func baseQuery(key: String, group: String?) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        #if os(macOS)
        q[kSecUseDataProtectionKeychain as String] = true
        #endif
        if let group { q[kSecAttrAccessGroup as String] = group }
        return q
    }

    private func withGroupFallback(_ body: (String?) -> OSStatus) throws {
        lock.lock()
        let useGroup = groupUnavailable ? nil : accessGroup
        lock.unlock()
        var status = body(useGroup)
        if status == errSecMissingEntitlement, useGroup != nil {
            lock.lock()
            groupUnavailable = true
            lock.unlock()
            status = body(nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }
}
