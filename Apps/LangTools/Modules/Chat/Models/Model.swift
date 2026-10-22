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
                guard !slug.isEmpty,
                      slug == slug.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
                self = .openAI(OpenAI.Model(rawValue: slug) ?? OpenAI.Model(customModelID: slug))
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

        let ollamaModels = OllamaEndpointConfiguration.shared.cachedModels().map { Model.ollama($0) }

        return standardModels + ollamaModels
    }

    public static var chatModels: [Model] {
        OpenAI.Model.chatModels.map { .openAI($0) }
        + Anthropic.Model.allCases.map { .anthropic($0) }
        + XAI.Model.allCases.map { .xAI($0) }
        + Gemini.Model.allCases.map { .gemini($0) }
        + OllamaEndpointConfiguration.shared.cachedModels().map { .ollama($0) }
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
    public let supportsTopP: Bool
    public let supportsFrequencyPenalty: Bool
    public let supportsPresencePenalty: Bool
    public let supportsTopK: Bool
    public let supportsSeed: Bool
    public let supportsStop: Bool
    /// The model's published context window size (input tokens). Nil when unknown or account-backed.
    public let contextWindowTokens: Int?
    public let unsupportedReason: String?

    public var supportsAnyOverride: Bool {
        maximumOutputField != nil || supportsTemperature || supportsTopP
            || supportsFrequencyPenalty || supportsPresencePenalty
            || supportsTopK || supportsSeed || supportsStop
    }

    public init(
        maximumOutputField: MaximumOutputField?,
        maximumOutputTokenBound: Int? = nil,
        maximumOutputWarning: String? = nil,
        supportsTemperature: Bool,
        supportsTopP: Bool = false,
        supportsFrequencyPenalty: Bool = false,
        supportsPresencePenalty: Bool = false,
        supportsTopK: Bool = false,
        supportsSeed: Bool = false,
        supportsStop: Bool = false,
        contextWindowTokens: Int? = nil,
        unsupportedReason: String? = nil
    ) {
        self.maximumOutputField = maximumOutputField
        self.maximumOutputTokenBound = maximumOutputTokenBound
        self.maximumOutputWarning = maximumOutputWarning
        self.supportsTemperature = supportsTemperature
        self.supportsTopP = supportsTopP
        self.supportsFrequencyPenalty = supportsFrequencyPenalty
        self.supportsPresencePenalty = supportsPresencePenalty
        self.supportsTopK = supportsTopK
        self.supportsSeed = supportsSeed
        self.supportsStop = supportsStop
        self.contextWindowTokens = contextWindowTokens
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
        case .anthropic(let model):
            guard let bound = Self.anthropicGenerationModelBounds[model.rawValue] else {
                return Self.unsupportedGenerationCapabilities
            }
            return .init(
                maximumOutputField: .anthropicMaxTokens,
                maximumOutputTokenBound: bound,
                supportsTemperature: true,
                supportsTopP: true,
                supportsTopK: true,
                supportsStop: true,
                contextWindowTokens: Self.anthropicContextWindows[model.rawValue]
            )
        case .ollama:
            return .init(
                maximumOutputField: .ollamaNumPredict,
                maximumOutputTokenBound: ChatGenerationSettings.tokenRange.upperBound,
                maximumOutputWarning: "The app guard is not a model limit. Ollama output capacity depends on the selected model and runtime configuration.",
                supportsTemperature: true,
                supportsTopP: true,
                supportsFrequencyPenalty: true,
                supportsPresencePenalty: true,
                supportsTopK: true,
                supportsSeed: true,
                supportsStop: true,
                contextWindowTokens: nil
            )
        case .gemini(let model):
            guard let bound = Self.geminiGenerationModelBounds[model.rawValue] else {
                return Self.unsupportedGenerationCapabilities
            }
            return .init(
                maximumOutputField: .openAIMaxTokens,
                maximumOutputTokenBound: bound,
                supportsTemperature: true,
                supportsTopP: true,
                supportsFrequencyPenalty: true,
                supportsPresencePenalty: true,
                supportsSeed: true,
                supportsStop: true,
                contextWindowTokens: Self.geminiContextWindows[model.rawValue]
            )
        case .xAI(let model):
            guard Self.xAIGenerationModels.contains(model.rawValue) else {
                return Self.unsupportedGenerationCapabilities
            }
            return .init(
                maximumOutputField: .openAIMaxTokens,
                maximumOutputTokenBound: ChatGenerationSettings.tokenRange.upperBound,
                maximumOutputWarning: "The app guard is not a model limit. xAI output capacity depends on the selected model.",
                supportsTemperature: true,
                supportsTopP: true,
                supportsFrequencyPenalty: true,
                supportsPresencePenalty: true,
                supportsSeed: true,
                supportsStop: true
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
                    supportsTemperature: true,
                    supportsTopP: true,
                    supportsFrequencyPenalty: true,
                    supportsPresencePenalty: true,
                    supportsSeed: true,
                    supportsStop: true,
                    contextWindowTokens: Self.openAIContextWindows[model.rawValue]
                )
            }
            if let bound = Self.openAIReasoningGenerationModelBounds[model.rawValue] {
                return .init(
                    maximumOutputField: .openAIMaxCompletionTokens,
                    maximumOutputTokenBound: bound,
                    supportsTemperature: false,
                    supportsTopP: true,
                    supportsStop: true,
                    contextWindowTokens: Self.openAIContextWindows[model.rawValue]
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

    // OpenAI model pages publish per-model maximum output tokens. In particular:
    // https://developers.openai.com/api/docs/models/o3
    // https://developers.openai.com/api/docs/models/gpt-5-pro
    private static let openAIReasoningGenerationModelBounds: [String: Int] = [
        "o1": 100_000, "o1-mini": 65_536, "o1-preview": 32_768,
        "o3": 100_000, "o3-pro": 100_000, "o3-mini": 100_000, "o4-mini": 100_000,
        "gpt-5": 128_000, "gpt-5-mini": 128_000, "gpt-5-nano": 128_000,
        "gpt-5-pro": 272_000, "gpt-5.1": 128_000, "gpt-5.2": 128_000,
        "gpt-5.2-pro": 128_000,
        // No public model page currently verifies a higher limit for this catalog ID.
        "gpt-5.3": 32_768,
        "gpt-5.4": 128_000,
        "gpt-5.4-pro": 128_000, "gpt-5.4-mini": 128_000, "gpt-5.4-nano": 128_000,
        "gpt-5.5": 128_000, "gpt-5.5-pro": 128_000,
    ]

    // Anthropic's model overview is the source for the 4.5 and 4.6 output limits.
    // Older IDs retain the existing conservative bound rather than inheriting a family limit.
    // https://platform.claude.com/docs/en/models/overview
    private static let anthropicGenerationModelBounds: [String: Int] = [
        "claude-opus-4-6": 128_000, "claude-opus-4-6-20260205": 128_000,
        "claude-sonnet-4-6": 128_000, "claude-sonnet-4-6-20260217": 128_000,
        "claude-opus-4-5-20251101": 64_000, "claude-sonnet-4-5-latest": 64_000,
        "claude-sonnet-4-5-20250929": 64_000, "claude-haiku-4-5-latest": 64_000,
        "claude-haiku-4-5-20251001": 64_000,
        "claude-opus-4-1-latest": 4_096, "claude-opus-4-1-20250805": 4_096,
        "claude-opus-4-20250514": 4_096, "claude-sonnet-4-20250514": 4_096,
        "claude-3-haiku-20240307": 4_096, "claude-3-7-sonnet-20250219": 4_096,
        "claude-3-5-haiku-20241022": 4_096, "claude-3-5-sonnet-latest": 4_096,
        "claude-3-5-sonnet-20241022": 4_096, "claude-3-5-sonnet-20240620": 4_096,
        "claude-3-opus-latest": 4_096, "claude-3-opus-20240229": 4_096,
        "claude-3-sonnet-20240229": 4_096,
    ]

    // Gemini model pages publish output token limits. Only exact documented 3 preview IDs
    // get the 65,536 bound; other 3.x IDs retain the existing conservative bound.
    // https://ai.google.dev/gemini-api/docs/models
    private static let geminiGenerationModelBounds: [String: Int] = [
        "gemini-3-pro-preview": 65_536, "gemini-3-flash-preview": 65_536,
        "gemini-2.5-flash": 65_536, "gemini-2.5-flash-lite": 65_536,
        "gemini-2.5-pro": 65_536,
        "gemini-2.0-flash": 8_192, "gemini-2.0-flash-lite": 8_192,
        "gemini-3-pro": 4_096, "gemini-3-flash": 4_096, "gemini-3.1-pro": 4_096,
        "gemini-1.5-flash": 4_096, "gemini-1.5-flash-8b": 4_096,
        "gemini-1.5-pro": 4_096, "gemini-1.0-pro": 4_096,
    ]

    // xAI documents limits per model, so recognized chat models use only the app guard.
    // https://docs.x.ai/developers/models
    private static let xAIGenerationModels: Set<String> = [
        "grok-4-1-fast-reasoning", "grok-4-1-fast-non-reasoning",
        "grok-4-fast-reasoning", "grok-4-fast-non-reasoning", "grok-4-0709",
        "grok-3", "grok-3-mini", "grok-code-fast-1", "grok-2-vision-1212",
        "grok-2-1212", "grok-beta",
    ]

    // Ollama's num_predict is runtime/model dependent, not a universal provider limit.
    // https://docs.ollama.com/modelfile

    // MARK: - Context windows

    /// Published context window sizes (input tokens). Nil = unknown / account-backed.
    /// Sources: provider model pages as linked above. Ollama is model-dependent.
    private static let openAIContextWindows: [String: Int] = [
        // Ordinary models
        "gpt-3.5-turbo": 16_385, "gpt-3.5-turbo-0301": 4_096,
        "gpt-3.5-turbo-1106": 16_385, "gpt-3.5-turbo-16k": 16_385,
        "gpt-4": 8_192, "gpt-4-turbo": 128_000, "gpt-4-0613": 8_192,
        "gpt-4-1106-preview": 128_000, "gpt-4-vision-preview": 128_000,
        "gpt-4-32k-0613": 32_768, "gpt-4o-2024-05-13": 128_000,
        "gpt-4o": 128_000, "gpt-4o-mini": 128_000,
        "gpt-4o-2024-08-06": 128_000, "gpt-4o-2024-11-20": 128_000,
        "gpt-4o-mini-2024-07-18": 128_000,
        "gpt-4.1": 1_000_000, "gpt-4.1-mini": 1_000_000, "gpt-4.1-nano": 1_000_000,
        // Reasoning models
        "o1": 200_000, "o1-mini": 128_000, "o1-preview": 128_000,
        "o3": 200_000, "o3-pro": 200_000, "o3-mini": 200_000, "o4-mini": 200_000,
        "gpt-5": 128_000, "gpt-5-mini": 128_000, "gpt-5-nano": 128_000,
        "gpt-5-pro": 272_000, "gpt-5.1": 128_000, "gpt-5.2": 128_000,
        "gpt-5.2-pro": 128_000, "gpt-5.3": 128_000,
        "gpt-5.4": 128_000, "gpt-5.4-pro": 128_000,
        "gpt-5.4-mini": 128_000, "gpt-5.4-nano": 128_000,
        "gpt-5.5": 128_000, "gpt-5.5-pro": 128_000,
    ]

    private static let anthropicContextWindows: [String: Int] = [
        "claude-opus-4-6": 200_000, "claude-opus-4-6-20260205": 200_000,
        "claude-sonnet-4-6": 200_000, "claude-sonnet-4-6-20260217": 200_000,
        "claude-opus-4-5-20251101": 200_000, "claude-sonnet-4-5-latest": 200_000,
        "claude-sonnet-4-5-20250929": 200_000, "claude-haiku-4-5-latest": 200_000,
        "claude-haiku-4-5-20251001": 200_000,
        "claude-opus-4-1-latest": 200_000, "claude-opus-4-1-20250805": 200_000,
        "claude-opus-4-20250514": 200_000, "claude-sonnet-4-20250514": 200_000,
        "claude-3-haiku-20240307": 200_000, "claude-3-7-sonnet-20250219": 200_000,
        "claude-3-5-haiku-20241022": 200_000, "claude-3-5-sonnet-latest": 200_000,
        "claude-3-5-sonnet-20241022": 200_000, "claude-3-5-sonnet-20240620": 200_000,
        "claude-3-opus-latest": 200_000, "claude-3-opus-20240229": 200_000,
        "claude-3-sonnet-20240229": 200_000,
    ]

    private static let geminiContextWindows: [String: Int] = [
        "gemini-3-pro-preview": 1_048_576, "gemini-3-flash-preview": 1_048_576,
        "gemini-3-pro": 1_048_576, "gemini-3-flash": 1_048_576,
        "gemini-3.1-pro": 1_048_576,
        "gemini-2.5-flash": 1_048_576, "gemini-2.5-flash-lite": 1_048_576,
        "gemini-2.5-pro": 1_048_576,
        "gemini-2.0-flash": 1_048_576, "gemini-2.0-flash-lite": 1_048_576,
        "gemini-1.5-flash": 1_048_576, "gemini-1.5-flash-8b": 1_048_576,
        "gemini-1.5-pro": 2_097_152, "gemini-1.0-pro": 32_768,
    ]
}
