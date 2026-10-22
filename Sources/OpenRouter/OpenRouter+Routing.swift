//
//  OpenRouter+Routing.swift
//  LangTools
//
//  Typed access to OpenRouter's routing fields. They travel in the request's
//  `additionalParameters`; other OpenRouter fields can be set there directly.
//

import Foundation
import LangTools
import OpenAI
import OpenAICompatible

extension OpenRouter {
    /// Controls which upstream providers serve a request (the `provider` field).
    public struct ProviderPreferences: Codable, Equatable, Sendable {
        /// Providers to try first, in order, such as `["anthropic", "openai"]`.
        public var order: [String]?
        /// Whether other providers may serve the request when the preferred ones
        /// fail. OpenRouter defaults to `true`.
        public var allowFallbacks: Bool?
        /// Only route to providers that support every parameter in the request.
        public var requireParameters: Bool?
        /// Whether providers that store or train on data may be used.
        public var dataCollection: DataCollection?
        /// Restrict routing to these providers.
        public var only: [String]?
        /// Never route to these providers.
        public var ignore: [String]?
        /// Rank providers by price, throughput, or latency instead of load balancing.
        public var sort: Sort?
        /// Restrict routing to zero-data-retention endpoints.
        public var zeroDataRetention: Bool?
        /// Allowed quantization levels, such as `["fp8", "bf16"]`.
        public var quantizations: [String]?

        public init(order: [String]? = nil, allowFallbacks: Bool? = nil, requireParameters: Bool? = nil, dataCollection: DataCollection? = nil, only: [String]? = nil, ignore: [String]? = nil, sort: Sort? = nil, zeroDataRetention: Bool? = nil, quantizations: [String]? = nil) {
            self.order = order
            self.allowFallbacks = allowFallbacks
            self.requireParameters = requireParameters
            self.dataCollection = dataCollection
            self.only = only
            self.ignore = ignore
            self.sort = sort
            self.zeroDataRetention = zeroDataRetention
            self.quantizations = quantizations
        }

        public enum DataCollection: String, Codable, Sendable {
            case allow, deny
        }

        public enum Sort: String, Codable, Sendable {
            case price, throughput, latency
        }

        private enum CodingKeys: String, CodingKey {
            case order, only, ignore, sort, quantizations
            case allowFallbacks = "allow_fallbacks"
            case requireParameters = "require_parameters"
            case dataCollection = "data_collection"
            case zeroDataRetention = "zdr"
        }

        /// The wire form, containing only the fields that are set.
        public var json: JSON {
            var object: [String: JSON] = [:]
            if let order { object[CodingKeys.order.rawValue] = .array(order.map(JSON.string)) }
            if let allowFallbacks { object[CodingKeys.allowFallbacks.rawValue] = .bool(allowFallbacks) }
            if let requireParameters { object[CodingKeys.requireParameters.rawValue] = .bool(requireParameters) }
            if let dataCollection { object[CodingKeys.dataCollection.rawValue] = .string(dataCollection.rawValue) }
            if let only { object[CodingKeys.only.rawValue] = .array(only.map(JSON.string)) }
            if let ignore { object[CodingKeys.ignore.rawValue] = .array(ignore.map(JSON.string)) }
            if let sort { object[CodingKeys.sort.rawValue] = .string(sort.rawValue) }
            if let zeroDataRetention { object[CodingKeys.zeroDataRetention.rawValue] = .bool(zeroDataRetention) }
            if let quantizations { object[CodingKeys.quantizations.rawValue] = .array(quantizations.map(JSON.string)) }
            return .object(object)
        }
    }
}

extension OpenAI.ChatCompletionRequest {
    /// Returns a copy with OpenRouter routing options merged into
    /// `additionalParameters`. A nil argument leaves that field unchanged.
    ///
    /// - Parameters:
    ///   - provider: Upstream provider preferences (the `provider` field).
    ///   - fallbackModels: Models to try in order if the primary model is
    ///     unavailable (the `models` field).
    public func routing(provider: OpenRouter.ProviderPreferences? = nil, fallbackModels: [OpenRouter.Model]? = nil) -> Self {
        var request = self
        var parameters = request.additionalParameters ?? [:]
        if let provider { parameters["provider"] = provider.json }
        if let fallbackModels { parameters["models"] = .array(fallbackModels.map { .string($0.rawValue) }) }
        request.additionalParameters = parameters.isEmpty ? request.additionalParameters : parameters
        return request
    }

    public init(model: OpenRouter.Model, messages: [Message], temperature: Double? = nil, top_p: Double? = nil, n: Int? = nil, stream: Bool? = nil, stream_options: StreamOptions? = nil, stop: Stop? = nil, max_tokens: Int? = nil, max_completion_tokens: Int? = nil, presence_penalty: Double? = nil, frequency_penalty: Double? = nil, logit_bias: [String: Double]? = nil, logprobs: Bool? = nil, top_logprobs: Int? = nil, user: String? = nil, response_type: ResponseType? = nil, seed: Int? = nil, tools: [Tool]? = nil, tool_choice: ToolChoice? = nil, parallel_tool_calls: Bool? = nil, reasoning_effort: ReasoningEffort? = nil, provider: OpenRouter.ProviderPreferences? = nil, fallbackModels: [OpenRouter.Model]? = nil, choose: @escaping ([Response.Choice]) -> Int = { _ in 0 }, toolEventHandler: @escaping (LangToolsToolEvent) -> Void = { _ in }) {
        self.init(model: model.openAIModel, messages: messages, temperature: temperature, top_p: top_p, n: n, stream: stream, stream_options: stream_options, stop: stop, max_tokens: max_tokens, max_completion_tokens: max_completion_tokens, presence_penalty: presence_penalty, frequency_penalty: frequency_penalty, logit_bias: logit_bias, logprobs: logprobs, top_logprobs: top_logprobs, user: user, response_type: response_type, seed: seed, tools: tools, tool_choice: tool_choice, parallel_tool_calls: parallel_tool_calls, reasoning_effort: reasoning_effort, choose: choose, toolEventHandler: toolEventHandler)
        self = routing(provider: provider, fallbackModels: fallbackModels)
    }
}
