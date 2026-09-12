//
//  UserDefaults+Extensions.swift
//
//  Created by Reid Chatham on 2/13/23.
//

import SwiftUI
import OpenAI
import Anthropic
import XAI
import Gemini
import Ollama

public extension UserDefaults {
    static var model: Model {
        get {
            let rawValue = standard.string(forKey: "model")
            let normalizedRawValue = normalizeLegacyModelID(rawValue)
            if normalizedRawValue != rawValue {
                standard.set(normalizedRawValue, forKey: "model")
            }
            return normalizedRawValue.flatMap(Model.init) ?? .openAI(.gpt4o_mini)
        }
        set { standard.set(newValue.rawValue, forKey: "model") }
    }

    static var maxTokens: Int {
        get { standard.integer(forKey: "max_tokens") }
        set { standard.set(newValue, forKey: "max_tokens") }
    }

    static var temperature: Double {
        get { standard.double(forKey: "temperature") }
        set { standard.set(newValue, forKey: "temperature") }
    }

    private static func normalizeLegacyModelID(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }

        switch rawValue {
        case "gpt-5.1-codex", "gpt-5.3-codex":
            return "codex/gpt-5.3-codex-spark"
        default:
            break
        }

        if rawValue.contains("/") {
            return rawValue
        }

        if let model = OpenAI.Model(rawValue: rawValue) {
            if OpenAI.Model.codex.contains(model) {
                return "codex/\(model.rawValue)"
            }
            return "openai/\(model.rawValue)"
        }

        if let model = Anthropic.Model(rawValue: rawValue) {
            return "anthropic/\(model.rawValue)"
        }

        if let model = XAI.Model(rawValue: rawValue) {
            return "xai/\(model.rawValue)"
        }

        if let model = Gemini.Model(rawValue: rawValue) {
            return "gemini/\(model.rawValue)"
        }

        if let model = Ollama.Model(rawValue: rawValue) {
            return "ollama/\(model.rawValue)"
        }

        return rawValue
    }
}

// UserDefaults extension for setting and getting the device token
extension UserDefaults {
    private static let deviceTokenKey = "kdeviceToken"
    private static let systemMessageKey = "systemMessage"
    private static let serperApiKeyKey = "serperApiKey"
    private static let accountBackendBaseURLKey = "accountBackendBaseURL"
    private static let codexHelperBaseURLKey = "codexHelperBaseURL"
    private static let codexHelperTokenKey = "codexHelperToken"

    static var systemMessage: String {
        get {
            UserDefaults.standard.string(forKey: systemMessageKey) ?? "You are a helpful AI assistant."
        }
        set {
            UserDefaults.standard.set(newValue, forKey: systemMessageKey)
        }
    }

    static var deviceToken: String? {
        get { standard.string(forKey: deviceTokenKey) }
        set { standard.setValue(newValue, forKey: deviceTokenKey) }
    }

    static var serperApiKey: String? {
        get { standard.string(forKey: serperApiKeyKey) }
        set { standard.setValue(newValue, forKey: serperApiKeyKey) }
    }

    public static var accountBackendBaseURL: URL {
        get {
            if let value = standard.string(forKey: accountBackendBaseURLKey),
               let url = URL(string: value) {
                return url
            }
            return URL(string: "http://localhost:8080")!
        }
        set {
            standard.setValue(newValue.absoluteString, forKey: accountBackendBaseURLKey)
        }
    }

    public static var codexHelperBaseURL: URL {
        get {
            if let value = standard.string(forKey: codexHelperBaseURLKey),
               let url = URL(string: value) {
                return url
            }
            return URL(string: "http://127.0.0.1:8765")!
        }
        set {
            standard.setValue(newValue.absoluteString, forKey: codexHelperBaseURLKey)
        }
    }

    public static var codexHelperToken: String {
        get {
            let keychain = KeychainService.shared
            if let token = keychain.secret(forKey: codexHelperTokenKey) {
                return token
            }
            guard let legacyToken = standard.string(forKey: codexHelperTokenKey), legacyToken.isEmpty == false else {
                return ""
            }
            if keychain.saveSecret(legacyToken, forKey: codexHelperTokenKey),
               keychain.secret(forKey: codexHelperTokenKey) == legacyToken {
                standard.removeObject(forKey: codexHelperTokenKey)
            }
            return legacyToken
        }
        set {
            standard.removeObject(forKey: codexHelperTokenKey)
            if newValue.isEmpty {
                KeychainService.shared.deleteSecret(forKey: codexHelperTokenKey)
            } else {
                KeychainService.shared.saveSecret(newValue, forKey: codexHelperTokenKey)
            }
        }
    }
}
