import Foundation
import KeychainAccess

/// Native-only credential access. Constructing a store must not perform I/O.
public protocol ResearchCredentialStore {
    func readApiKey() throws -> String?
    func saveApiKey(_ apiKey: String) throws
}

public enum ResearchCredentialError: Error, Equatable, LocalizedError {
    case emptyKey
    case storageUnavailable

    public var errorDescription: String? {
        switch self {
        case .emptyKey: return "Enter a Serper API key in native settings."
        case .storageUnavailable: return "Research credentials are unavailable. Check native settings."
        }
    }
}

/// Compatibility with the existing ExampleAgents preference and Keychain entries.
/// Reads never migrate or synchronize credentials. Only explicit saves write.
public struct StoredResearchCredentials: ResearchCredentialStore {
    private let preferences: () -> UserDefaults
    private let readSecureKey: () throws -> String?
    private let saveSecureKey: (String) throws -> Void
    private static let preferenceKey = "serperApiKey"

    public init() {
        // Even creation of the live preferences/Keychain objects is deferred.
        self.preferences = { .standard }
        self.readSecureKey = {
            try Keychain(service: "com.reidchatham.LangTools_Example").getString("serper:apiKey")
        }
        self.saveSecureKey = {
            try Keychain(service: "com.reidchatham.LangTools_Example").set($0, key: "serper:apiKey")
        }
    }

    // Tests use isolated preferences and fake secure storage, never real Keychain.
    init(
        preferences: UserDefaults,
        readSecureKey: @escaping () throws -> String?,
        saveSecureKey: @escaping (String) throws -> Void
    ) {
        self.preferences = { preferences }
        self.readSecureKey = readSecureKey
        self.saveSecureKey = saveSecureKey
    }

    public func readApiKey() throws -> String? {
        if let key = preferences().string(forKey: Self.preferenceKey), !key.isEmpty {
            return key
        }
        do {
            guard let key = try readSecureKey(), !key.isEmpty else { return nil }
            return key
        } catch {
            throw ResearchCredentialError.storageUnavailable
        }
    }

    public func saveApiKey(_ apiKey: String) throws {
        guard !apiKey.isEmpty else { throw ResearchCredentialError.emptyKey }
        do {
            try saveSecureKey(apiKey)
        } catch {
            throw ResearchCredentialError.storageUnavailable
        }
        preferences().set(apiKey, forKey: Self.preferenceKey)
    }
}
