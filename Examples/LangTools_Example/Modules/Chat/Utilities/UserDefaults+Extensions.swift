//
//  UserDefaults+Extensions.swift
//
//  Created by Reid Chatham on 2/13/23.
//

import SwiftUI

public extension UserDefaults {
    static var model: Model {
        get { standard.string(forKey: "model").flatMap(Model.init) ?? .openAI(.gpt35Turbo) }
        set { standard.set(newValue.rawValue, forKey: "model") }
    }
    
    static var maxTokens: Int {
        get { standard.integer(forKey: "max_tokens")}
        set { standard.set(newValue, forKey: "max_tokens")}
    }
    
    static var temperature: Double {
        get { return standard.double(forKey: "temperature")}
        set { standard.set(newValue, forKey: "temperature")}
    }
}

// UserDefaults extension for setting and getting the device token
extension UserDefaults {
    private static let deviceTokenKey = "kdeviceToken"
    private static let systemMessageKey = "systemMessage"
    private static let serperApiKeyKey = "serperApiKey"

    static var systemMessage: String {
        get {
            return UserDefaults.standard.string(forKey: systemMessageKey) ?? "You are a helpful AI assistant."
        }
        set {
            UserDefaults.standard.set(newValue, forKey: systemMessageKey)
        }
    }

    static var deviceToken: String? {
        get { standard.string(forKey: deviceTokenKey)}
        set { standard.setValue(newValue, forKey: deviceTokenKey)}
    }
    
    static var serperApiKey: String? {
        get { standard.string(forKey: serperApiKeyKey) }
        set { standard.setValue(newValue, forKey: serperApiKeyKey) }
    }
}
