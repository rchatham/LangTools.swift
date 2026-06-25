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

/// Provider categories for grouping models in the UI
enum Provider: String, CaseIterable {
    case anthropic = "Anthropic"
    case openAI = "OpenAI"
    case xAI = "XAI"
    case gemini = "Gemini"
    case ollama = "Ollama"
}

enum ToolReliabilityTier: String {
    case recommended = "recommended"
    case limited = "limited"
    case unavailable = "unavailable"
}

struct ModelCapabilities: Equatable {
    let supportsTools: Bool
    let toolReliability: ToolReliabilityTier
    let supportsStreaming: Bool
    let supportsStructuredOutput: Bool

    var isRecommendedForTools: Bool {
        toolReliability == .recommended
    }

    var cautionText: String? {
        switch toolReliability {
        case .recommended:
            return nil
        case .limited:
            return "Local/Ollama models may be unreliable for tool-heavy tasks"
        case .unavailable:
            return "Tool calling is not currently available for this model in the CLI"
        }
    }

    var toolWarningText: String? {
        switch toolReliability {
        case .recommended:
            return nil
        case .limited:
            return "Warning: This model may be unreliable for tool-heavy tasks."
        case .unavailable:
            return "Warning: Tool calling is not currently available for this model in the CLI. Continuing without tools."
        }
    }
}

enum Model: Codable, RawRepresentable, Hashable, CaseIterable, Identifiable, Equatable {
    typealias RawValue = String
    case openAI(OpenAI.Model)
    case anthropic(Anthropic.Model)
    case xAI(XAI.Model)
    case gemini(Gemini.Model)
    /// A locally-served Ollama model (e.g. "llama3", "mistral", "phi3").
    case ollama(Ollama.Model)

    init?(rawValue: String) {
        if let model = OpenAI.Model(rawValue: rawValue) { self = .openAI(model) }
        else if let model = Anthropic.Model(rawValue: rawValue) { self = .anthropic(model) }
        else if let model = XAI.Model(rawValue: rawValue) { self = .xAI(model) }
        else if let model = Gemini.Model(rawValue: rawValue) { self = .gemini(model) }
        else if let model = Ollama.Model(rawValue: rawValue) { self = .ollama(model) }
        else { return nil }
    }

    var rawValue: String {
        switch self {
        case .openAI(let model): return model.rawValue
        case .anthropic(let model): return model.rawValue
        case .xAI(let model): return model.rawValue
        case .gemini(let model): return model.rawValue
        case .ollama(let model): return model.rawValue
        }
    }

    var id: String { rawValue }

    static var allCases: [Model] {
        return OpenAI.Model.allCases.map { .openAI($0) }
        + Anthropic.Model.allCases.map { .anthropic($0) }
        + XAI.Model.allCases.map { .xAI($0) }
        + Gemini.Model.allCases.map { .gemini($0) }
        + Ollama.Model.allCases.map { .ollama($0) }
    }

    static var chatModels: [Model] {
        return OpenAI.Model.chatModels.map { .openAI($0) }
        + Anthropic.Model.allCases.map { .anthropic($0) }
        + XAI.Model.allCases.map { .xAI($0) }
        + Gemini.Model.allCases.map { .gemini($0) }
        + Ollama.Model.allCases.map { .ollama($0) }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(rawValue)
    }

    /// The provider category for this model
    var provider: Provider {
        switch self {
        case .anthropic: return .anthropic
        case .openAI: return .openAI
        case .xAI: return .xAI
        case .gemini: return .gemini
        case .ollama: return .ollama
        }
    }

    var capabilities: ModelCapabilities {
        switch self {
        case .anthropic, .openAI, .xAI:
            return ModelCapabilities(
                supportsTools: true,
                toolReliability: .recommended,
                supportsStreaming: true,
                supportsStructuredOutput: true
            )
        case .gemini:
            return ModelCapabilities(
                supportsTools: false,
                toolReliability: .unavailable,
                supportsStreaming: true,
                supportsStructuredOutput: false
            )
        case .ollama:
            return ModelCapabilities(
                supportsTools: true,
                toolReliability: .limited,
                supportsStreaming: true,
                supportsStructuredOutput: false
            )
        }
    }

    /// Get all chat models for a specific provider
    static func chatModels(for provider: Provider) -> [Model] {
        chatModels.filter { $0.provider == provider }
    }

    /// Count of chat models per provider
    static func chatModelCount(for provider: Provider) -> Int {
        chatModels(for: provider).count
    }
}
