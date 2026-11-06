//
//  KeychainService.swift
//
//  Created by Reid Chatham on 1/20/23.
//

import Foundation
import ToolKit

/// Reads and writes through the same cached `SecretVault` as the Chat module,
/// so the agents never cause Keychain reads of their own.
class KeychainService {
    private let vault = SecretVault.shared(service: "com.reidchatham.LangTools_Example")

    private static func account(for service: APIService) -> String {
        "\(service.rawValue):apiKey"
    }

    func saveApiKey(apiKey: String, for service: APIService) {
        do { try vault.setValue(apiKey, forKey: Self.account(for: service)) }
        catch { print("Error saving API key to keychain: \(error)")}
    }

    func getApiKey(for service: APIService) -> String? {
        do { return try vault.value(forKey: Self.account(for: service)) }
        catch { print("Error fetching API key from keychain: \(error)"); return nil}
    }

    /// Whether a key is stored, without reading it from the Keychain.
    func hasApiKey(for service: APIService) -> Bool {
        vault.contains(Self.account(for: service))
    }

    func deleteApiKey(for service: APIService) {
        do { try vault.removeValue(forKey: Self.account(for: service)) }
        catch { print("Error deleting API key from keychain: \(error)")}
    }
}

enum APIService: String, CaseIterable { case serper }
