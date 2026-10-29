//
//  Model.swift
//  LangTools_Example
//
//  Created by Reid Chatham on 9/29/24.
//
import Foundation
import OpenAI
import OpenAICompatible
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
    // OpenAI-compatible providers; raw values match each `displayName`.
    case openRouter = "OpenRouter"
    case vercel = "Vercel AI Gateway"
    case groq = "Groq"
    case mistral = "Mistral"
    case deepseek = "DeepSeek"
    case cerebras = "Cerebras"
    case together = "Together AI"
    case fireworks = "Fireworks AI"
    case cohere = "Cohere"
    case perplexity = "Perplexity"
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
    /// A model on an OpenAI-compatible provider, such as OpenRouter or Groq. Its raw value
    /// is `<provider>/<model-id>`, e.g. `openrouter/anthropic/claude-sonnet-4.5`, so it never
    /// falls through to the Ollama case, which accepts any string.
    case compatible(CompatibleProvider, String)

    /// The configured providers' chat catalogs, filled by `NetworkClient.fetchCompatibleModels()`
    /// in the background while the UI reads them, so access is serialized.
    static var compatibleCatalogs: [CompatibleProvider: [OpenAICompatibleModelInfo]] {
        get { catalogLock.lock(); defer { catalogLock.unlock() }; return _compatibleCatalogs }
        set { catalogLock.lock(); defer { catalogLock.unlock() }; _compatibleCatalogs = newValue }
    }
    private static let catalogLock = NSLock()
    private static var _compatibleCatalogs: [CompatibleProvider: [OpenAICompatibleModelInfo]] = [:]

    init?(rawValue: String) {
        if let provider = CompatibleProvider.allCases.first(where: { rawValue.hasPrefix($0.prefix) }) {
            guard let id = CompatibleProvider.validModelID(String(rawValue.dropFirst(provider.prefix.count))) else { return nil }
            self = .compatible(provider, id)
        }
        else if let model = OpenAI.Model(rawValue: rawValue) { self = .openAI(model) }
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
        case .compatible(let provider, let id): return provider.prefix + id
        }
    }

    var id: String { rawValue }

    static var allCases: [Model] {
        return OpenAI.Model.allCases.map { .openAI($0) }
        + Anthropic.Model.allCases.map { .anthropic($0) }
        + XAI.Model.allCases.map { .xAI($0) }
        + Gemini.Model.allCases.map { .gemini($0) }
        + Ollama.Model.allCases.map { .ollama($0) }
        + compatibleChatModels
    }

    static var chatModels: [Model] {
        return OpenAI.Model.chatModels.map { .openAI($0) }
        + Anthropic.Model.allCases.map { .anthropic($0) }
        + XAI.Model.allCases.map { .xAI($0) }
        + Gemini.Model.allCases.map { .gemini($0) }
        + Ollama.Model.allCases.map { .ollama($0) }
        + compatibleChatModels
    }

    private static var compatibleChatModels: [Model] {
        let catalogs = compatibleCatalogs
        return CompatibleProvider.allCases.flatMap { provider in
            (catalogs[provider] ?? []).map { .compatible(provider, $0.id) }
        }
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
        case .compatible(let provider, _): return provider.category
        }
    }

    var capabilities: ModelCapabilities {
        switch self {
        case .anthropic, .openAI, .xAI, .gemini:
            return ModelCapabilities(
                supportsTools: true,
                toolReliability: .recommended,
                supportsStreaming: true,
                supportsStructuredOutput: true
            )
        case .ollama:
            return ModelCapabilities(
                supportsTools: true,
                toolReliability: .limited,
                supportsStreaming: true,
                supportsStructuredOutput: false
            )
        case .compatible(let provider, let id):
            // Catalogs that report tool support decide; otherwise tools are assumed.
            let info = Self.compatibleCatalogs[provider]?.first { $0.id == id }
            let supportsTools = info?.supportsTools ?? true
            return ModelCapabilities(
                supportsTools: supportsTools,
                toolReliability: supportsTools ? .recommended : .unavailable,
                supportsStreaming: true,
                supportsStructuredOutput: info?.metadata["supported_parameters"]?.arrayValue?.contains("structured_outputs") ?? false
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
