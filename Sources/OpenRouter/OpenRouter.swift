//
//  OpenRouter.swift
//  LangTools
//
//  OpenRouter is a gateway to models from many vendors, serving OpenAI's chat
//  format and Anthropic's Messages format. Its requests carry the OpenRouter
//  provider tag, so they never collide with another provider serving the same
//  `creator/model` slugs.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LangTools
import OpenAI
import OpenAICompatible
import Anthropic
import AnthropicCompatible

public final class OpenRouter: OpenAICompatibleProvider, AnthropicCompatibleProvider {
    public typealias Model = OpenRouterModel
    public typealias ErrorResponse = OpenRouterErrorResponse

    public static let providerID = LangToolsProviderID(rawValue: "openrouter")
    public static let displayName = "OpenRouter"
    public static let defaultBaseURL = URL(string: "https://openrouter.ai/api/v1/")!
    public static let apiKeyEnvironmentVariable = "OPENROUTER_API_KEY"
    /// The catalog is too large and changes too often to list; use `listModels()`.
    public static var knownModels: [Model] { [.auto] }

    public let openAI: OpenAI
    public let anthropic: Anthropic
    public let additionalHeaders: [String: String]
    // OpenRouter accepts the key as a bearer token on every format.
    public var anthropicAuthentication: AnthropicCompatibleAuthentication { .bearer }

    /// - Parameters:
    ///   - appURL: Sent as `HTTP-Referer`, which identifies your app in OpenRouter's rankings.
    ///   - appTitle: Sent as `X-OpenRouter-Title`, the app's display name there.
    public init(baseURL: URL = OpenRouter.defaultBaseURL, apiKey: String, appURL: URL? = nil, appTitle: String? = nil, session: URLSession = URLSession(configuration: .default, delegate: nil, delegateQueue: nil), logger: LangToolsLogger? = nil) {
        additionalHeaders = ["HTTP-Referer": appURL?.absoluteString, "X-OpenRouter-Title": appTitle.flatMap { $0.isEmpty ? nil : $0 }].compactMapValues { $0 }
        openAI = Self.makeClient(baseURL: baseURL, apiKey: apiKey, session: session, logger: logger)
        anthropic = Anthropic(baseURL: baseURL, apiKey: apiKey, session: session, logger: logger)
    }

    public var session: URLSession { openAI.session }
    public var logger: LangToolsLogger? { openAI.logger }
    public static var requestValidators: [(any LangToolsRequest) -> Bool] { compatibleRequestValidators + anthropicRequestValidators }

    public func prepare(request: some LangToolsRequest) throws -> URLRequest {
        guard request is Anthropic.MessageRequest else { return try prepareCompatible(request: request) }
        var urlRequest = try prepareAnthropicCompatible(request: request)
        try OpenAICompatibleHeaders.apply(additionalHeaders, to: &urlRequest)
        return urlRequest
    }

    /// An Anthropic `Model` builds a Messages request; an OpenRouter `Model`, a chat completion request.
    public static func chatRequest(model: any RawRepresentable, messages: [any LangToolsMessage], tools: [any LangToolsTool]?, responseSchema: JSONSchema?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) throws -> any LangToolsChatRequest {
        if let model = model as? Anthropic.Model {
            return try anthropicChatRequest(model: model, messages: messages, tools: tools, responseSchema: responseSchema, toolEventHandler: toolEventHandler)
        }
        guard let model = model as? Model else { throw LangToolsError.invalidArgument("Unsupported model \(model)") }
        return try compatibleChatRequest(model: model, messages: messages, tools: tools, responseSchema: responseSchema, toolEventHandler: toolEventHandler)
    }

    /// Which upstream providers serve a request (the `provider` field).
    public struct ProviderPreferences: Codable, Equatable, Sendable {
        /// Providers to try first, in order, such as `["anthropic", "openai"]`; `allowFallbacks`
        /// (default true) lets others serve the request when they fail.
        public var order: [String]?, allowFallbacks: Bool?
        /// Only providers supporting every request parameter; whether providers that store data may be used.
        public var requireParameters: Bool?, dataCollection: DataCollection?
        /// Providers to restrict routing to, or to skip.
        public var only: [String]?, ignore: [String]?
        /// Rank by price, throughput, or latency instead of load balancing.
        public var sort: Sort?
        /// Zero-data-retention endpoints only; allowed quantizations such as `["fp8"]`.
        public var zeroDataRetention: Bool?, quantizations: [String]?

        public init(order: [String]? = nil, allowFallbacks: Bool? = nil, requireParameters: Bool? = nil, dataCollection: DataCollection? = nil, only: [String]? = nil, ignore: [String]? = nil, sort: Sort? = nil, zeroDataRetention: Bool? = nil, quantizations: [String]? = nil) {
            (self.order, self.allowFallbacks, self.requireParameters, self.dataCollection, self.only) = (order, allowFallbacks, requireParameters, dataCollection, only)
            (self.ignore, self.sort, self.zeroDataRetention, self.quantizations) = (ignore, sort, zeroDataRetention, quantizations)
        }

        public enum DataCollection: String, Codable, Sendable { case allow, deny }
        public enum Sort: String, Codable, Sendable { case price, throughput, latency }

        private enum CodingKeys: String, CodingKey {
            case order, only, ignore, sort, quantizations, allowFallbacks = "allow_fallbacks", requireParameters = "require_parameters", dataCollection = "data_collection", zeroDataRetention = "zdr"
        }

        /// The wire form, with only the fields that are set.
        public var json: JSON { (try? JSONDecoder().decode(JSON.self, from: JSONEncoder().encode(self))) ?? .object([:]) }
    }
}

extension OpenAI.ChatCompletionRequest {
    /// A copy with OpenRouter's `provider` preferences and fallback `models` merged into
    /// `additionalParameters`; a nil argument leaves that field unchanged.
    public func routing(provider: OpenRouter.ProviderPreferences? = nil, fallbackModels: [OpenRouter.Model]? = nil) -> Self {
        var request = self
        var parameters = request.additionalParameters ?? [:]
        if let provider { parameters["provider"] = provider.json }
        if let fallbackModels { parameters["models"] = .array(fallbackModels.map { .string($0.rawValue) }) }
        request.additionalParameters = parameters.isEmpty ? request.additionalParameters : parameters
        return request
    }
}

/// `{"error": {"code": 402, "message": ...}}`; the Messages endpoint's error body decodes the same way.
public struct OpenRouterErrorResponse: Error, Codable, LocalizedError {
    public let error: OpenAI.ChatCompletionResponse.ResponseError
    public init(error: OpenAI.ChatCompletionResponse.ResponseError) { self.error = error }
    public var errorDescription: String? { error.errorDescription }
}

/// An OpenRouter slug such as `"anthropic/claude-sonnet-4.5"`, optionally with a variant such as `":free"`.
public typealias OpenRouterModel = OpenAICompatibleModel<OpenRouter>

extension OpenAICompatibleModel where Provider == OpenRouter {
    /// OpenRouter's router, which picks a model for each prompt.
    public static var auto: OpenRouterModel { "openrouter/auto" }
}
