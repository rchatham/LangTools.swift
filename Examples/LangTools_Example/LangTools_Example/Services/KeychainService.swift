//
//  KeychainService.swift
//
//  Created by Reid Chatham on 1/20/23.
//

import Foundation
import KeychainAccess

enum APIKeychainService: String {
    case openAI, anthropic
}

class KeychainService {
    let keychain = Keychain(service: "com.reidchatham.LangTools_Example")

    func saveApiKey(apiKey: String, for service: APIKeychainService) {
        do { try keychain.set(apiKey, key: "\(service.rawValue):apiKey")}
        catch { print("Error saving API key to keychain: \(error)")}
    }

    func getApiKey(for service: APIKeychainService) -> String? {
        do { return try keychain.getString("\(service.rawValue):apiKey") }
        catch { print("Error fetching API key from keychain: \(error)"); return nil}
    }

    func deleteApiKey(for service: APIKeychainService) {
        do { try keychain.remove("\(service.rawValue):apiKey")}
        catch { print("Error deleting API key from keychain: \(error)")}
    }
}