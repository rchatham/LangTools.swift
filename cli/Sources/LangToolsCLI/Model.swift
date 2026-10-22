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
import OpenRouter

/// Provider categories for grouping models in the UI
enum Provider: String, CaseIterable {
    case anthropic = "Anthropic"
    case openAI = "OpenAI"
    case xAI = "XAI"
    case gemini = "Gemini"
    case ollama = "Ollama"
    case openRouter = "OpenRouter"
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
    /// An OpenRouter model slug (e.g. "anthropic/claude-sonnet-4.5"). Its raw
    /// value carries an `openrouter/` prefix so it never falls through to the
    /// Ollama case, which accepts any string.
    case openRouter(OpenRouter.Model)

    static let openRouterPrefix = "openrouter/"

    /// The OpenRouter catalog, populated at runtime by
    /// `NetworkClient.fetchOpenRouterModels()` once an API key is configured.
    /// The fetch runs in a background task while the UI reads the catalog, so
    /// access is serialized.
    static var openRouterCatalog: [OpenRouter.ModelInfo] {
        get { openRouterCatalogLock.lock(); defer { openRouterCatalogLock.unlock() }; return _openRouterCatalog }
        set { openRouterCatalogLock.lock(); defer { openRouterCatalogLock.unlock() }; _openRouterCatalog = newValue }
    }
    private static let openRouterCatalogLock = NSLock()
    private static var _openRouterCatalog: [OpenRouter.ModelInfo] = []

    init?(rawValue: String) {
        if rawValue.hasPrefix(Self.openRouterPrefix) {
            guard let model = Self.openRouterModel(fromPrefixed: rawValue) else { return nil }
            self = .openRouter(model)
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
        case .openRouter(let model): return Self.openRouterPrefix + model.rawValue
        }
    }

    /// Parses `openrouter/<slug>`. OpenRouter slugs normally contain a slash
    /// (`creator/model`); a bare remainder such as `auto` is OpenRouter's own
    /// `openrouter/auto` router, so the full string is kept as the slug.
    static func openRouterModel(fromPrefixed rawValue: String) -> OpenRouter.Model? {
        let slug = String(rawValue.dropFirst(openRouterPrefix.count))
        // Reject empty and whitespace-padded slugs, as the app does.
        guard !slug.isEmpty, slug == slug.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return OpenRouter.Model(rawValue: slug.contains("/") ? slug : rawValue)
    }

    var id: String { rawValue }

    static var allCases: [Model] {
        return OpenAI.Model.allCases.map { .openAI($0) }
        + Anthropic.Model.allCases.map { .anthropic($0) }
        + XAI.Model.allCases.map { .xAI($0) }
        + Gemini.Model.allCases.map { .gemini($0) }
        + Ollama.Model.allCases.map { .ollama($0) }
        + openRouterCatalog.map { .openRouter($0.model) }
    }

    static var chatModels: [Model] {
        return OpenAI.Model.chatModels.map { .openAI($0) }
        + Anthropic.Model.allCases.map { .anthropic($0) }
        + XAI.Model.allCases.map { .xAI($0) }
        + Gemini.Model.allCases.map { .gemini($0) }
        + Ollama.Model.allCases.map { .ollama($0) }
        + openRouterCatalog.map { .openRouter($0.model) }
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
        case .openRouter: return .openRouter
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
        case .openRouter(let model):
            // Support varies by model. The catalog says which models accept
            // tools; a model missing from it is assumed to.
            let info = Self.openRouterCatalog.first { $0.model == model }
            let supportsTools = info?.supportsTools ?? true
            return ModelCapabilities(
                supportsTools: supportsTools,
                toolReliability: supportsTools ? .recommended : .unavailable,
                supportsStreaming: true,
                supportsStructuredOutput: info?.supportsStructuredOutput ?? false
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
