//
//  Model.swift
//  LangTools_Example
//
//  Created by Reid Chatham on 9/29/24.
//
import Foundation
import OpenAI
import Anthropic
import XAI
import Gemini
import Ollama

public enum ModelRoute: String, Codable, Hashable {
    case openAI = "openai"
    case codex = "codex"
    case anthropic = "anthropic"
    case xAI = "xai"
    case gemini = "gemini"
    case ollama = "ollama"
}

public enum Model: Codable, RawRepresentable, Hashable, CaseIterable, Identifiable, Equatable {
    case openAI(OpenAI.Model)
    case codex(OpenAI.Model)
    case anthropic(Anthropic.Model)
    case xAI(XAI.Model)
    case gemini(Gemini.Model)
    case ollama(Ollama.Model)

    public init?(rawValue: String) {
        let components = rawValue.split(separator: "/", maxSplits: 1).map(String.init)
        if components.count == 2 {
            let route = components[0]
            let slug = components[1]
            switch route {
            case ModelRoute.openAI.rawValue:
                guard let model = OpenAI.Model(rawValue: slug) else { return nil }
                self = .openAI(model)
            case ModelRoute.codex.rawValue:
                guard let model = OpenAI.Model(rawValue: slug) else { return nil }
                self = .codex(model)
            case ModelRoute.anthropic.rawValue:
                guard let model = Anthropic.Model(rawValue: slug) else { return nil }
                self = .anthropic(model)
            case ModelRoute.xAI.rawValue:
                guard let model = XAI.Model(rawValue: slug) else { return nil }
                self = .xAI(model)
            case ModelRoute.gemini.rawValue:
                guard let model = Gemini.Model(rawValue: slug) else { return nil }
                self = .gemini(model)
            case ModelRoute.ollama.rawValue:
                guard let model = Ollama.Model(rawValue: slug) else { return nil }
                self = .ollama(model)
            default:
                return nil
            }
            return
        }

        if let model = OpenAI.Model(rawValue: rawValue) { self = .openAI(model) }
        else if let model = Anthropic.Model(rawValue: rawValue) { self = .anthropic(model) }
        else if let model = XAI.Model(rawValue: rawValue) { self = .xAI(model) }
        else if let model = Gemini.Model(rawValue: rawValue) { self = .gemini(model) }
        else if let model = Ollama.Model(rawValue: rawValue) { self = .ollama(model) }
        else { return nil }
    }

    public var rawValue: String {
        "\(route.rawValue)/\(slug)"
    }

    public var slug: String {
        switch self {
        case .openAI(let model), .codex(let model):
            return model.rawValue
        case .anthropic(let model):
            return model.rawValue
        case .xAI(let model):
            return model.rawValue
        case .gemini(let model):
            return model.rawValue
        case .ollama(let model):
            return model.rawValue
        }
    }

    public var route: ModelRoute {
        switch self {
        case .openAI:
            return .openAI
        case .codex:
            return .codex
        case .anthropic:
            return .anthropic
        case .xAI:
            return .xAI
        case .gemini:
            return .gemini
        case .ollama:
            return .ollama
        }
    }

    public var id: String { rawValue }

    public static var allCases: [Model] {
        let standardModels: [Model] = OpenAI.Model.allCases.map { .openAI($0) }
        + Anthropic.Model.allCases.map { .anthropic($0) }
        + XAI.Model.allCases.map { .xAI($0) }
        + Gemini.Model.allCases.map { .gemini($0) }

        let ollamaModels: [Model] = {
            if !OllamaService.shared.availableModels.isEmpty {
                return OllamaService.shared.availableModels
            }
            return cachedOllamaModels
        }().map { .ollama($0) }

        return standardModels + ollamaModels
    }

    public static var chatModels: [Model] {
        OpenAI.Model.chatModels.map { .openAI($0) }
        + Anthropic.Model.allCases.map { .anthropic($0) }
        + XAI.Model.allCases.map { .xAI($0) }
        + Gemini.Model.allCases.map { .gemini($0) }
        + cachedOllamaModels.map { .ollama($0) }
    }

    static var cachedOllamaModels: [Ollama.Model] {
        guard let modelNames = UserDefaults.standard.stringArray(forKey: "ollamaModels") else {
            return []
        }
        return modelNames.compactMap { Ollama.Model(rawValue: $0) }
    }

    static func updateCachedOllamaModels(_ models: [Ollama.Model]) {
        let modelNames = models.map { $0.rawValue }
        UserDefaults.standard.set(modelNames, forKey: "ollamaModels")
    }

    public var apiService: APIService {
        switch self {
        case .openAI, .codex: return .openAI
        case .anthropic: return .anthropic
        case .xAI: return .xAI
        case .gemini: return .gemini
        case .ollama: return .ollama
        }
    }

    public static func availableChatModels(accessManager: ProviderAccessManager = .shared) -> [Model] {
        accessManager.availableChatModels()
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(rawValue)
    }
}
