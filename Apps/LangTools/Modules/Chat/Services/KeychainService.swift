//
//  KeychainService.swift
//
//  Created by Reid Chatham on 1/20/23.
//

import Foundation
import KeychainAccess

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

public class KeychainService: KeychainSecretStoring {
    public static let shared = KeychainService()

    /// Stable service identifier retained so existing credentials remain accessible.
    /// Public so the initializer default argument can reference it without drift.
    public static let serviceIdentifier = "com.reidchatham.LangTools_Example"

    let keychain: Keychain

    public init(keychain: Keychain = Keychain(service: KeychainService.serviceIdentifier)) {
        self.keychain = keychain
    }

    public func saveApiKey(apiKey: String, for service: APIService) {
        do { try keychain.set(apiKey, key: "\(service.rawValue):apiKey")}
        catch { print("Error saving API key to keychain: \(error)")}
    }

    public func getApiKey(for service: APIService) -> String? {
        do { return try keychain.getString("\(service.rawValue):apiKey") }
        catch { print("Error fetching API key from keychain: \(error)"); return nil}
    }

    public func deleteApiKey(for service: APIService) {
        do { try keychain.remove("\(service.rawValue):apiKey")}
        catch { print("Error deleting API key from keychain: \(error)")}
    }

    public func setSecret(_ value: String, forKey key: String) throws {
        try keychain.set(value, key: key)
    }

    public func readSecret(forKey key: String) throws -> String? {
        try keychain.getString(key)
    }

    public func removeSecret(forKey key: String) throws {
        try keychain.remove(key)
    }

    @discardableResult
    public func saveSecret(_ value: String, forKey key: String) -> Bool {
        do {
            try keychain.set(value, key: key)
            return true
        } catch {
            print("Error saving secret to keychain: \(error)")
            return false
        }
    }

    public func secret(forKey key: String) -> String? {
        do { return try keychain.getString(key) }
        catch { print("Error fetching secret from keychain: \(error)"); return nil }
    }

    public func deleteSecret(forKey key: String) {
        do { try keychain.remove(key) }
        catch { print("Error deleting secret from keychain: \(error)") }
    }
}
