//
//  KeychainService.swift
//
//  Created by Reid Chatham on 1/20/23.
//

import Foundation
import KeychainAccess
import ToolKit

public protocol KeychainSecretStoring {
    func setSecret(_ value: String, forKey key: String) throws
    func readSecret(forKey key: String) throws -> String?
    func removeSecret(forKey key: String) throws
}

public enum CodexHelperTokenStoreError: LocalizedError, Equatable {
    case verificationFailed

    public var errorDescription: String? {
        "The Codex helper token could not be verified after updating Keychain."
    }
}

public final class CodexHelperTokenStore {
    public static let key = "codexHelperToken"

    private let defaults: UserDefaults
    private let keychain: KeychainSecretStoring

    public init(defaults: UserDefaults = .standard, keychain: KeychainSecretStoring = KeychainService.shared) {
        self.defaults = defaults
        self.keychain = keychain
    }

    public func token() -> String {
        do {
            return try loadToken()
        } catch {
            // Fail closed: if secure storage is unavailable, do not return the
            // legacy plaintext token as a usable credential. Retain the legacy
            // value in UserDefaults so a future migration can retry, but expose
            // no usable token until Keychain persistence succeeds.
            NSLog("Unable to migrate the Codex helper token to Keychain: %@", error.localizedDescription)
            return ""
        }
    }

    public func loadToken() throws -> String {
        if let stored = try keychain.readSecret(forKey: Self.key) {
            return stored
        }
        guard let legacy = defaults.string(forKey: Self.key), legacy.isEmpty == false else {
            return ""
        }

        try replaceKeychainValue(with: legacy)
        defaults.removeObject(forKey: Self.key)
        return legacy
    }

    public func setToken(_ value: String) throws {
        try replaceKeychainValue(with: value.isEmpty ? nil : value)
        defaults.removeObject(forKey: Self.key)
    }

    private func replaceKeychainValue(with value: String?) throws {
        let previous = try keychain.readSecret(forKey: Self.key)
        do {
            if let value {
                try keychain.setSecret(value, forKey: Self.key)
            } else {
                try keychain.removeSecret(forKey: Self.key)
            }
            guard try keychain.readSecret(forKey: Self.key) == value else {
                throw CodexHelperTokenStoreError.verificationFailed
            }
        } catch {
            if let previous {
                try keychain.setSecret(previous, forKey: Self.key)
            } else {
                try keychain.removeSecret(forKey: Self.key)
            }
            throw error
        }
    }
}

/// Stores API keys and other app secrets.
///
/// All secrets for a Keychain service live in one cached `SecretVault`, so
/// the Keychain is read at most once per launch, only when a secret's value is
/// actually needed, and presence checks (`hasApiKey`, `hasSecret`) never read
/// secret data at all. See `SecretVault` for details.
public class KeychainService: KeychainSecretStoring {
    /// Returns the shared instance. When a validated fixture environment is
    /// active the instance uses the fixture-isolated Keychain service;
    /// otherwise it uses the ordinary app service.
    public static var shared: KeychainService {
        if ChatUITestEnvironment.isFixtureActive {
            return fixtureInstance
        }
        return ordinaryInstance
    }

    /// The ordinary app Keychain service — never changed by fixture state.
    private static let ordinaryInstance = KeychainService(
        keychain: Keychain(service: "com.reidchatham.LangTools_Example")
    )

    /// The fixture-isolated Keychain service. Lazily created so the fixture
    /// namespace is never touched during normal app runs.
    private static let fixtureInstance = KeychainService(
        keychain: Keychain(service: ChatUITestEnvironment.fixtureKeychainService)
    )

    /// Identifies the Keychain service. Secrets are read and written through
    /// `vault`, never through this object directly.
    let keychain: Keychain
    let vault: SecretVault

    /// `vault` defaults to the process-wide vault for `keychain`'s service;
    /// tests pass their own to count Keychain access.
    public init(keychain: Keychain = Keychain(service: "com.reidchatham.LangTools_Example"), vault: SecretVault? = nil) {
        self.keychain = keychain
        self.vault = vault ?? SecretVault.shared(service: keychain.service)
    }

    private static func apiKeyAccount(for service: APIService) -> String {
        "\(service.rawValue):apiKey"
    }

    public func saveApiKey(apiKey: String, for service: APIService) {
        // An empty key is no key: presence checks must not report it as set.
        guard !apiKey.isEmpty else { return deleteApiKey(for: service) }
        do { try vault.setValue(apiKey, forKey: Self.apiKeyAccount(for: service)) }
        catch { print("Error saving API key to keychain: \(error)") }
    }

    public func getApiKey(for service: APIService) -> String? {
        do { return try vault.value(forKey: Self.apiKeyAccount(for: service)) }
        catch { print("Error fetching API key from keychain: \(error)"); return nil }
    }

    /// Whether an API key is stored, without reading it from the Keychain.
    public func hasApiKey(for service: APIService) -> Bool {
        vault.contains(Self.apiKeyAccount(for: service))
    }

    public func deleteApiKey(for service: APIService) {
        do { try vault.removeValue(forKey: Self.apiKeyAccount(for: service)) }
        catch { print("Error deleting API key from keychain: \(error)") }
    }

    public func setSecret(_ value: String, forKey key: String) throws {
        try vault.setValue(value, forKey: key)
    }

    public func readSecret(forKey key: String) throws -> String? {
        try vault.value(forKey: key)
    }

    /// Whether a secret is stored, without reading it from the Keychain.
    public func hasSecret(forKey key: String) -> Bool {
        vault.contains(key)
    }

    public func removeSecret(forKey key: String) throws {
        try vault.removeValue(forKey: key)
    }

    @discardableResult
    public func saveSecret(_ value: String, forKey key: String) -> Bool {
        do {
            try vault.setValue(value, forKey: key)
            return true
        } catch {
            print("Error saving secret to keychain: \(error)")
            return false
        }
    }

    public func secret(forKey key: String) -> String? {
        do { return try vault.value(forKey: key) }
        catch { print("Error fetching secret from keychain: \(error)"); return nil }
    }

    public func deleteSecret(forKey key: String) {
        do { try vault.removeValue(forKey: key) }
        catch { print("Error deleting secret from keychain: \(error)") }
    }
}
