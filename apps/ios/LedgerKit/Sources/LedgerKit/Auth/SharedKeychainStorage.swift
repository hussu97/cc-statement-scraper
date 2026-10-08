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
/// supabase-swift swallows storage errors, so a failed write would leave the
/// UI "signed in" while every request goes out anonymous. This type records
/// the failure (`persistenceFailure`) for `SessionStore` to act on. In Debug
/// builds (`allowsMemoryFallback`) it also keeps the session in memory, and
/// retries without the access group when the entitlement is missing (an
/// unsigned simulator build); Release never silently drops the sharing the
/// App Intent and the Share Extension rely on.
public final class SharedKeychainStorage: AuthLocalStorage, @unchecked Sendable {
    private let service: String
    private let accessGroup: String?
    private let allowsMemoryFallback: Bool
    private let lock = NSLock()
    private var groupUnavailable = false
    private var memory: [String: Data] = [:]
    private var _persistenceFailure: KeychainError?

    public init(service: String = "ledger.supabase.auth", accessGroup: String?, allowsMemoryFallback: Bool = false) {
        self.service = service
        self.accessGroup = accessGroup
        self.allowsMemoryFallback = allowsMemoryFallback
    }

    /// The last keychain write failure, cleared by a successful write or a remove.
    public var persistenceFailure: KeychainError? { lock.withLock { _persistenceFailure } }

    /// True when the session lives only in this process's memory (Debug fallback).
    public var isUsingMemoryFallback: Bool { lock.withLock { !memory.isEmpty } }

    public func store(key: String, value: Data) throws {
        do {
            try storeInKeychain(key: key, value: value)
            lock.withLock {
                _persistenceFailure = nil
                memory[key] = nil
            }
        } catch let error as KeychainError {
            lock.withLock { _persistenceFailure = error }
            guard allowsMemoryFallback else { throw error }
            lock.withLock { memory[key] = value }
        }
    }

    private func storeInKeychain(key: String, value: Data) throws {
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
        if let cached = lock.withLock({ memory[key] }) { return cached }
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
        let hadMemory = lock.withLock {
            _persistenceFailure = nil
            return memory.removeValue(forKey: key) != nil
        }
        if hadMemory { try? removeFromKeychain(key: key); return }
        try removeFromKeychain(key: key)
    }

    private func removeFromKeychain(key: String) throws {
        try withGroupFallback { group in
            let status = SecItemDelete(baseQuery(key: key, group: group) as CFDictionary)
            return status == errSecItemNotFound ? errSecSuccess : status
        }
    }

    // MARK: -

    public struct KeychainError: Error, CustomStringConvertible, Equatable {
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
        if status == errSecMissingEntitlement, useGroup != nil, allowsMemoryFallback {
            lock.lock()
            groupUnavailable = true
            lock.unlock()
            status = body(nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }
}
