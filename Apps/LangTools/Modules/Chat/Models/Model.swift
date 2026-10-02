//
//  Model.swift
//  LangToolsApp
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
    case claudeCode = "claude-code"
    case xAI = "xai"
    case gemini = "gemini"
    case ollama = "ollama"
}

public enum Model: Codable, RawRepresentable, Hashable, CaseIterable, Identifiable, Equatable {
    case openAI(OpenAI.Model)
    case codex(OpenAI.Model)
    case anthropic(Anthropic.Model)
    case claudeCode(Anthropic.Model)
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
            case ModelRoute.claudeCode.rawValue:
                guard let model = Anthropic.Model(rawValue: slug) else { return nil }
                self = .claudeCode(model)
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
        case .anthropic(let model), .claudeCode(let model):
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
        case .claudeCode:
            return .claudeCode
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
        case .anthropic, .claudeCode: return .anthropic
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

public struct ChatGenerationCapabilities: Equatable, Sendable {
    public enum MaximumOutputField: Equatable, Sendable {
        case openAIMaxTokens
        case openAIMaxCompletionTokens
        case anthropicMaxTokens
        case ollamaNumPredict
    }

    public let maximumOutputField: MaximumOutputField?
    public let maximumOutputTokenBound: Int?
    public let maximumOutputWarning: String?
    public let supportsTemperature: Bool
    public let unsupportedReason: String?

    public var supportsAnyOverride: Bool {
        maximumOutputField != nil || supportsTemperature
    }

    public init(
        maximumOutputField: MaximumOutputField?,
        maximumOutputTokenBound: Int? = nil,
        maximumOutputWarning: String? = nil,
        supportsTemperature: Bool,
        unsupportedReason: String? = nil
    ) {
        self.maximumOutputField = maximumOutputField
        self.maximumOutputTokenBound = maximumOutputTokenBound
        self.maximumOutputWarning = maximumOutputWarning
        self.supportsTemperature = supportsTemperature
        self.unsupportedReason = unsupportedReason
    }
}

public extension Model {
    var generationCapabilities: ChatGenerationCapabilities {
        switch self {
        case .codex, .claudeCode:
            return .init(
                maximumOutputField: nil,
                supportsTemperature: false,
                unsupportedReason: "Account-backed transport does not support advanced generation parameters."
            )
        case .anthropic:
            return .init(
                maximumOutputField: .anthropicMaxTokens,
                maximumOutputTokenBound: 4_096,
                supportsTemperature: true
            )
        case .ollama:
            return .init(
                maximumOutputField: .ollamaNumPredict,
                maximumOutputTokenBound: 32_768,
                maximumOutputWarning: "32,768 is an app ceiling, not a guarantee that the selected Ollama model supports that output length.",
                supportsTemperature: true
            )
        case .gemini:
            return .init(
                maximumOutputField: .openAIMaxTokens,
                maximumOutputTokenBound: 4_096,
                supportsTemperature: true
            )
        case .xAI(let model):
            guard Self.xAIGenerationModels.contains(model.rawValue) else {
                return Self.unsupportedGenerationCapabilities
            }
            return .init(
                maximumOutputField: .openAIMaxTokens,
                maximumOutputTokenBound: 4_096,
                supportsTemperature: true
            )
        case .openAI(let model):
            switch model.rawValue {
            case "gpt-3.5-turbo-instruct":
                return Self.unsupportedGenerationCapabilities(
                    "This completion-only model does not support chat generation parameters."
                )
            case "gpt-5.3-codex-spark":
                return Self.unsupportedGenerationCapabilities(
                    "This Codex-only model is not supported on the direct OpenAI chat route."
                )
            case "chatgpt-4o-latest":
                return Self.unsupportedGenerationCapabilities(
                    "This mutable model alias has no reliable output limit; advanced parameters are unavailable."
                )
            default:
                break
            }
            if let bound = Self.openAIOrdinaryGenerationModelBounds[model.rawValue] {
                return .init(
                    maximumOutputField: .openAIMaxTokens,
                    maximumOutputTokenBound: bound,
                    supportsTemperature: true
                )
            }
            if Self.openAIReasoningGenerationModels.contains(model.rawValue) {
                return .init(
                    maximumOutputField: .openAIMaxCompletionTokens,
                    maximumOutputTokenBound: 32_768,
                    supportsTemperature: false
                )
            }
            return Self.unsupportedGenerationCapabilities
        }
    }

    private static var unsupportedGenerationCapabilities: ChatGenerationCapabilities {
        unsupportedGenerationCapabilities("The selected model does not support these advanced generation parameters.")
    }

    private static func unsupportedGenerationCapabilities(_ reason: String) -> ChatGenerationCapabilities {
        .init(maximumOutputField: nil, supportsTemperature: false, unsupportedReason: reason)
    }

    private static let openAIOrdinaryGenerationModelBounds: [String: Int] = [
        "gpt-3.5-turbo": 4_096, "gpt-3.5-turbo-0301": 4_096,
        "gpt-3.5-turbo-1106": 4_096, "gpt-3.5-turbo-16k": 4_096,
        "gpt-4": 4_096, "gpt-4-turbo": 4_096, "gpt-4-0613": 4_096,
        "gpt-4-1106-preview": 4_096, "gpt-4-vision-preview": 4_096,
        "gpt-4-32k-0613": 4_096, "gpt-4o-2024-05-13": 4_096,
        "gpt-4o": 16_384, "gpt-4o-mini": 16_384,
        "gpt-4o-2024-08-06": 16_384, "gpt-4o-2024-11-20": 16_384,
        "gpt-4o-mini-2024-07-18": 16_384,
        "gpt-4.1": 32_768, "gpt-4.1-mini": 32_768, "gpt-4.1-nano": 32_768,
    ]

    private static let openAIReasoningGenerationModels: Set<String> = [
        "o1", "o1-mini", "o1-preview", "o3", "o3-pro", "o3-mini", "o4-mini",
        "gpt-5", "gpt-5-mini", "gpt-5-nano", "gpt-5-pro", "gpt-5.1",
        "gpt-5.2", "gpt-5.2-pro", "gpt-5.3", "gpt-5.4", "gpt-5.4-pro",
        "gpt-5.4-mini", "gpt-5.4-nano", "gpt-5.5", "gpt-5.5-pro",
    ]

    private static let xAIGenerationModels: Set<String> = [
        "grok-4-1-fast-reasoning", "grok-4-1-fast-non-reasoning",
        "grok-4-fast-reasoning", "grok-4-fast-non-reasoning", "grok-4-0709",
        "grok-3", "grok-3-mini", "grok-code-fast-1", "grok-2-vision-1212",
        "grok-2-1212", "grok-beta",
    ]

}
