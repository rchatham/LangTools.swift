//
//  KeychainService.swift
//
//  Created by Reid Chatham on 1/20/23.
//

import Foundation
import KeychainAccess

public class KeychainService {
    public static let shared = KeychainService()

    let keychain = Keychain(service: "com.reidchatham.LangTools_Example")

    public init() {}

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
}
