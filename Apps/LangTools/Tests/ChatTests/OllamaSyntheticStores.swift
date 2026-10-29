import Foundation
@testable import Chat

/// Synthetic values only; never touches Security or the host credential stores.
final class OllamaMemorySecrets: KeychainSecretStoring {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func setSecret(_ value: String, forKey key: String) {
        lock.lock(); defer { lock.unlock() }; values[key] = value
    }
    func readSecret(forKey key: String) -> String? {
        lock.lock(); defer { lock.unlock() }; return values[key]
    }
    func removeSecret(forKey key: String) {
        lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: key)
    }
}

final class OllamaMemoryKeychainService: KeychainService {
    private let secrets = OllamaMemorySecrets()
    override func getApiKey(for service: APIService) -> String? { secrets.readSecret(forKey: service.rawValue) }
    override func saveApiKey(apiKey: String, for service: APIService) { secrets.setSecret(apiKey, forKey: service.rawValue) }
    override func deleteApiKey(for service: APIService) { secrets.removeSecret(forKey: service.rawValue) }
    override func readSecret(forKey key: String) throws -> String? { secrets.readSecret(forKey: key) }
    override func setSecret(_ value: String, forKey key: String) throws { secrets.setSecret(value, forKey: key) }
    override func removeSecret(forKey key: String) throws { secrets.removeSecret(forKey: key) }
    override func secret(forKey key: String) -> String? { secrets.readSecret(forKey: key) }
    override func saveSecret(_ value: String, forKey key: String) -> Bool {
        secrets.setSecret(value, forKey: key); return true
    }
    override func deleteSecret(forKey key: String) { secrets.removeSecret(forKey: key) }
}

final class OllamaMemoryHelperStore: MobileHelperCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: MobileHelperCredential] = [:]
    func load(helperID: String) throws -> MobileHelperCredential? {
        lock.lock(); defer { lock.unlock() }; return records[helperID]
    }
    func save(_ credential: MobileHelperCredential) throws {
        lock.lock(); defer { lock.unlock() }; records[credential.helperID] = credential
    }
    func remove(helperID: String) throws {
        lock.lock(); defer { lock.unlock() }; records.removeValue(forKey: helperID)
    }
}
