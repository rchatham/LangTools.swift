//
//  UserDefaults+Extensions.swift
//
//  Created by Reid Chatham on 2/13/23.
//

import SwiftUI

extension UserDefaults {
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

extension UserDefaults {
    private static let apiKeyPrefix = "apiKey_"
    
    static func getApiKey(for service: LLMAPIService) -> String? {
        return standard.string(forKey: apiKeyPrefix + service.rawValue)
    }
    
    static func setApiKey(_ apiKey: String, for service: LLMAPIService) {
        standard.set(apiKey, forKey: apiKeyPrefix + service.rawValue)
    }
    
    static func removeApiKey(for service: LLMAPIService) {
        standard.removeObject(forKey: apiKeyPrefix + service.rawValue)
    }
}
