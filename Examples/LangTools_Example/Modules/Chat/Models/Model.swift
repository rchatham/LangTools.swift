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

public enum Model: Codable, RawRepresentable, Hashable, CaseIterable, Identifiable, Equatable {
    case openAI(OpenAI.Model)
    case anthropic(Anthropic.Model)
    case xAI(XAI.Model)
    case gemini(Gemini.Model)
    case ollama(Ollama.Model)

    public init?(rawValue: String) {
        if let model = OpenAI.Model(rawValue: rawValue) { self = .openAI(model) }
        else if let model = Anthropic.Model(rawValue: rawValue) { self = .anthropic(model) }
        else if let model = XAI.Model(rawValue: rawValue) { self = .xAI(model) }
        else if let model = Gemini.Model(rawValue: rawValue) { self = .gemini(model) }
        else if let model = Ollama.Model(rawValue: rawValue) { self = .ollama(model) }
        else { return nil }
    }

    public var rawValue: String {
        switch self {
        case .openAI(let model): return model.rawValue
        case .anthropic(let model): return model.rawValue
        case .xAI(let model): return model.rawValue
        case .gemini(let model): return model.rawValue
        case .ollama(let model): return model.rawValue
        }
    }

    public var id: String { rawValue }

    public static var allCases: [Model] {
        let standardModels: [Model] = OpenAI.Model.allCases.map { .openAI($0) }
        + Anthropic.Model.allCases.map { .anthropic($0) }
        + XAI.Model.allCases.map { .xAI($0) }
        + Gemini.Model.allCases.map { .gemini($0) }

        // Get locally cached Ollama models from UserDefaults or from OllamaService if available
        let ollamaModels: [Model] = {
            if !OllamaService.shared.availableModels.isEmpty {
                return OllamaService.shared.availableModels
            }
            return cachedOllamaModels
        }().map { .ollama($0) }

        return standardModels + ollamaModels
    }

    public static var chatModels: [Model] {
        return OpenAI.Model.chatModels.map { .openAI($0) }
        + Anthropic.Model.allCases.map { .anthropic($0) }
        + XAI.Model.allCases.map { .xAI($0) }
        + Gemini.Model.allCases.map { .gemini($0) }
        + cachedOllamaModels.map { .ollama($0) }
    }

    // Get Ollama models from UserDefaults
    static var cachedOllamaModels: [Ollama.Model] {
        guard let modelNames = UserDefaults.standard.stringArray(forKey: "ollamaModels") else {
            return []
        }
        return modelNames.compactMap { Ollama.Model(rawValue: $0) }
    }

    // Update the cached Ollama models
    static func updateCachedOllamaModels(_ models: [Ollama.Model]) {
        let modelNames = models.map { $0.rawValue }
        UserDefaults.standard.set(modelNames, forKey: "ollamaModels")
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(rawValue)
    }
}
