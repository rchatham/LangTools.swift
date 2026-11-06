//
//  SecretVault.swift
//
//  A process-wide, in-memory cached store for the app's secrets that keeps
//  Keychain access (and therefore Keychain access prompts) to the minimum.
//

import Foundation
#if canImport(Security)
import Security
#endif

/// One entry from an attributes-only Keychain listing.
public struct SecretVaultItem: Equatable, Sendable {
    public let account: String
    public let comment: String?

    public init(account: String, comment: String?) {
        self.account = account
        self.comment = comment
    }
}

/// Raw storage beneath a `SecretVault`.
public protocol SecretVaultBackend: AnyObject {
    /// Lists stored items using attributes only. It never reads secret data,
    /// so it never causes a Keychain access prompt.
    func inventory() -> [SecretVaultItem]
    /// Reads one item's secret data. This is the only call that can prompt.
    func read(account: String) throws -> Data?
    func write(account: String, data: Data, comment: String) throws
    func delete(account: String) throws
}

public enum SecretVaultError: LocalizedError, Equatable {
    case keychain(Int32)
    case corruptVault

    public var errorDescription: String? {
        switch self {
        case .keychain(let status):
            return "Keychain operation failed (OSStatus \(status))."
        case .corruptVault:
            return "The stored secrets could not be decoded."
        }
    }
}

/// Keeps every secret for one Keychain service in a single Keychain item and
/// caches it for the life of the process.
///
/// The Keychain is touched only when it has to be:
/// - Whether a secret exists is answered from an attributes-only listing (the
///   vault item's comment holds the secret names, never their values), so
///   checking which providers are configured never prompts.
/// - Secret data is read at most once per process, and only when a value is
///   actually needed. Every secret lives in one item, so that is at most one
///   Keychain access prompt per launch rather than one per secret per read.
/// - Writes that would not change anything are skipped.
/// - On macOS the vault lives in the data protection Keychain when the app is
///   signed with entitlements that allow it; those items never show the legacy
///   "wants to use your confidential information" dialog.
///
/// Secrets saved by earlier versions as one Keychain item per secret are
/// migrated into the vault the first time each one is needed.
public final class SecretVault: @unchecked Sendable {
    /// The Keychain account that holds the vault.
    public static let vaultAccount = "LangTools.secretVault.v1"

    private static let registryLock = NSLock()
    private static var registry: [String: SecretVault] = [:]

    /// The vault for a Keychain service. Every caller that stores secrets in
    /// the same service shares one instance and therefore one cache.
    public static func shared(service: String) -> SecretVault {
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = registry[service] { return existing }
        #if canImport(Security)
        let vault = SecretVault(backend: KeychainSecretVaultBackend(service: service))
        #else
        let vault = SecretVault(backend: InMemorySecretVaultBackend())
        #endif
        registry[service] = vault
        return vault
    }

    private struct Inventory {
        var vaultExists: Bool
        /// Names held by the vault; nil when the vault exists but its index is
        /// unreadable, in which case the vault itself must be read to answer.
        var vaultKeys: Set<String>?
        /// Items saved one per secret by earlier versions, not yet migrated.
        var legacyKeys: Set<String>
    }

    private let backend: SecretVaultBackend
    private let lock = NSRecursiveLock()
    private var inventory: Inventory?
    /// The decoded vault; nil until it has been needed.
    private var secrets: [String: String]?

    public init(backend: SecretVaultBackend) {
        self.backend = backend
    }

    /// Whether a secret is stored for `key`. Never reads secret data.
    public func contains(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let secrets, secrets[key] != nil { return true }
        let inventory = inventoryLocked()
        if inventory.legacyKeys.contains(key) { return true }
        guard inventory.vaultExists else { return false }
        if let vaultKeys = inventory.vaultKeys { return vaultKeys.contains(key) }
        // The index is missing, so only the vault itself can answer.
        return ((try? loadVaultLocked()) ?? [:])[key] != nil
    }

    /// The secret stored for `key`, reading the Keychain only if it holds one
    /// that has not been read yet in this process.
    public func value(forKey key: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let secrets, let value = secrets[key] { return value }
        let inventory = inventoryLocked()
        if inventory.vaultExists, inventory.vaultKeys?.contains(key) ?? true {
            if let value = try loadVaultLocked()[key] { return value }
        }
        if inventory.legacyKeys.contains(key) {
            return try migrateLegacyLocked(key)
        }
        return nil
    }

    public func setValue(_ value: String, forKey key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var next = try loadVaultLocked()
        let hasLegacyCopy = inventoryLocked().legacyKeys.contains(key)
        guard next[key] != value || hasLegacyCopy else { return }
        next[key] = value
        try writeVaultLocked(next)
        if hasLegacyCopy { deleteLegacyLocked(key) }
    }

    public func removeValue(forKey key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let inventory = inventoryLocked()
        if inventory.legacyKeys.contains(key) {
            try backend.delete(account: key)
            self.inventory?.legacyKeys.remove(key)
        }
        guard inventory.vaultExists, inventory.vaultKeys?.contains(key) ?? true else { return }
        var next = try loadVaultLocked()
        guard next.removeValue(forKey: key) != nil else { return }
        try writeVaultLocked(next)
    }

    /// Drops everything cached so the next call starts from the Keychain.
    public func invalidateCache() {
        lock.lock()
        defer { lock.unlock() }
        inventory = nil
        secrets = nil
    }

    // MARK: - Private

    private func inventoryLocked() -> Inventory {
        if let inventory { return inventory }
        var vaultItem: SecretVaultItem?
        var legacyKeys = Set<String>()
        for item in backend.inventory() {
            if item.account == Self.vaultAccount {
                vaultItem = item
            } else {
                legacyKeys.insert(item.account)
            }
        }
        let inventory = Inventory(
            vaultExists: vaultItem != nil,
            vaultKeys: vaultItem.flatMap { Self.decodeIndex($0.comment) },
            legacyKeys: legacyKeys
        )
        self.inventory = inventory
        return inventory
    }

    private func loadVaultLocked() throws -> [String: String] {
        if let secrets { return secrets }
        guard inventoryLocked().vaultExists else {
            secrets = [:]
            return [:]
        }
        let loaded: [String: String]
        if let data = try backend.read(account: Self.vaultAccount) {
            guard let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
                throw SecretVaultError.corruptVault
            }
            loaded = decoded
        } else {
            loaded = [:]
        }
        secrets = loaded
        inventory?.vaultExists = !loaded.isEmpty
        inventory?.vaultKeys = Set(loaded.keys)
        return loaded
    }

    private func writeVaultLocked(_ next: [String: String]) throws {
        if next.isEmpty {
            try backend.delete(account: Self.vaultAccount)
        } else {
            let data = try JSONEncoder().encode(next)
            try backend.write(account: Self.vaultAccount, data: data, comment: Self.encodeIndex(next.keys))
        }
        secrets = next
        inventory?.vaultExists = !next.isEmpty
        inventory?.vaultKeys = Set(next.keys)
    }

    private func migrateLegacyLocked(_ key: String) throws -> String? {
        guard let data = try backend.read(account: key) else {
            inventory?.legacyKeys.remove(key)
            return nil
        }
        guard let value = String(data: data, encoding: .utf8) else { return nil }
        do {
            var next = try loadVaultLocked()
            next[key] = value
            try writeVaultLocked(next)
            deleteLegacyLocked(key)
        } catch {
            // Keep the legacy item; the value is still usable for this run.
            NSLog("Unable to move a stored secret into the vault: %@", error.localizedDescription)
            secrets?[key] = value
        }
        return value
    }

    private func deleteLegacyLocked(_ key: String) {
        do {
            try backend.delete(account: key)
            inventory?.legacyKeys.remove(key)
        } catch {
            // The vault copy wins on every later read, so a leftover legacy
            // item is harmless; removing the secret deletes it again.
            NSLog("Unable to remove a migrated Keychain item: %@", error.localizedDescription)
        }
    }

    private static func encodeIndex<Keys: Sequence>(_ keys: Keys) -> String where Keys.Element == String {
        let data = (try? JSONEncoder().encode(keys.sorted())) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private static func decodeIndex(_ comment: String?) -> Set<String>? {
        guard let data = comment?.data(using: .utf8),
              let keys = try? JSONDecoder().decode([String].self, from: data) else { return nil }
        return Set(keys)
    }
}

/// A non-persistent backend, used where the Keychain is unavailable and in tests.
public final class InMemorySecretVaultBackend: SecretVaultBackend {
    private var items: [String: (data: Data, comment: String?)] = [:]
    private let lock = NSLock()
    public private(set) var readCount = 0
    public private(set) var writeCount = 0
    public private(set) var inventoryCount = 0

    public init() {}

    public func inventory() -> [SecretVaultItem] {
        lock.lock(); defer { lock.unlock() }
        inventoryCount += 1
        return items.map { SecretVaultItem(account: $0.key, comment: $0.value.comment) }
    }

    public func read(account: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        readCount += 1
        return items[account]?.data
    }

    public func write(account: String, data: Data, comment: String) throws {
        lock.lock(); defer { lock.unlock() }
        writeCount += 1
        items[account] = (data, comment)
    }

    public func delete(account: String) throws {
        lock.lock(); defer { lock.unlock() }
        items.removeValue(forKey: account)
    }

    /// Seeds an item the way earlier versions stored one secret per item.
    public func seedLegacy(_ value: String, account: String) {
        lock.lock(); defer { lock.unlock() }
        items[account] = (Data(value.utf8), nil)
    }
}

#if canImport(Security)
/// Generic-password Keychain storage for one service, written against the
/// Security framework directly so every query is explicit about whether it
/// reads secret data.
public final class KeychainSecretVaultBackend: SecretVaultBackend {
    private let service: String
    #if os(macOS)
    private var dataProtectionAvailable: Bool?
    /// Accounts found in the legacy file-based Keychain by the last inventory.
    private var fileKeychainAccounts = Set<String>()
    #endif

    public init(service: String) {
        self.service = service
    }

    public func inventory() -> [SecretVaultItem] {
        var items: [String: SecretVaultItem] = [:]
        var dataProtectionAccounts = Set<String>()
        var fileAccounts = Set<String>()
        // The file-based Keychain first so data protection entries win.
        for dataProtection in locations.reversed() {
            for item in listItems(dataProtection: dataProtection) {
                items[item.account] = item
                if dataProtection {
                    dataProtectionAccounts.insert(item.account)
                } else {
                    fileAccounts.insert(item.account)
                }
            }
        }
        #if os(macOS)
        // Only accounts seen solely in the file-based Keychain are treated as
        // living there, so cleaning up a file copy can never remove the data
        // protection item.
        fileKeychainAccounts = fileAccounts.subtracting(dataProtectionAccounts)
        #else
        _ = (dataProtectionAccounts, fileAccounts)
        #endif
        return Array(items.values)
    }

    private func listItems(dataProtection: Bool) -> [SecretVaultItem] {
        var query = baseQuery(dataProtection: dataProtection)
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        // Attributes only: no kSecReturnData, so this never prompts.
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let rows = result as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let account = row[kSecAttrAccount as String] as? String else { return nil }
            return SecretVaultItem(account: account, comment: row[kSecAttrComment as String] as? String)
        }
    }

    public func read(account: String) throws -> Data? {
        for dataProtection in locations {
            var query = baseQuery(dataProtection: dataProtection)
            query[kSecAttrAccount as String] = account
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            query[kSecReturnData as String] = true
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            switch status {
            case errSecSuccess:
                return result as? Data
            case errSecItemNotFound:
                continue
            default:
                throw SecretVaultError.keychain(status)
            }
        }
        return nil
    }

    public func write(account: String, data: Data, comment: String) throws {
        let dataProtection = locations.first ?? false
        #if os(macOS)
        if dataProtection {
            do {
                try write(account: account, data: data, comment: comment, dataProtection: true)
            } catch SecretVaultError.keychain(errSecMissingEntitlement) {
                // The probe was optimistic; this build cannot use it after all.
                dataProtectionAvailable = false
                try write(account: account, data: data, comment: comment, dataProtection: false)
            }
            return
        }
        #endif
        try write(account: account, data: data, comment: comment, dataProtection: dataProtection)
    }

    private func write(account: String, data: Data, comment: String, dataProtection: Bool) throws {
        var query = baseQuery(dataProtection: dataProtection)
        query[kSecAttrAccount as String] = account
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrComment as String: comment,
        ]
        // Update in place first; only add when nothing is there. This avoids a
        // separate existence read before every write.
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            attributes.forEach { add[$0.key] = $0.value }
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw SecretVaultError.keychain(status) }
        #if os(macOS)
        // A copy left in the file-based Keychain by an unsigned build is now
        // stale; remove it so it cannot shadow the new value later.
        if dataProtection, fileKeychainAccounts.contains(account) {
            deleteItem(account: account, dataProtection: false)
            fileKeychainAccounts.remove(account)
        }
        #endif
    }

    public func delete(account: String) throws {
        for dataProtection in locations {
            #if os(macOS)
            if !dataProtection, dataProtectionAvailable == true, !fileKeychainAccounts.contains(account) { continue }
            #endif
            let status = deleteItem(account: account, dataProtection: dataProtection)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw SecretVaultError.keychain(status)
            }
        }
        #if os(macOS)
        fileKeychainAccounts.remove(account)
        #endif
    }

    @discardableResult
    private func deleteItem(account: String, dataProtection: Bool) -> OSStatus {
        var query = baseQuery(dataProtection: dataProtection)
        query[kSecAttrAccount as String] = account
        return SecItemDelete(query as CFDictionary)
    }

    /// Where to look, in priority order: `true` is the data protection Keychain.
    private var locations: [Bool] {
        #if os(macOS)
        return isDataProtectionAvailable ? [true, false] : [false]
        #else
        return [false]
        #endif
    }

    #if os(macOS)
    /// The data protection Keychain needs a signed app with an application
    /// identifier; unsigned and ad-hoc builds fall back to the file Keychain.
    private var isDataProtectionAvailable: Bool {
        if let dataProtectionAvailable { return dataProtectionAvailable }
        var query = baseQuery(dataProtection: true)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnAttributes as String] = true
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        let available = status == errSecSuccess || status == errSecItemNotFound
        dataProtectionAvailable = available
        return available
    }
    #endif

    private func baseQuery(dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        #if os(macOS)
        if dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        #endif
        return query
    }
}
#endif
