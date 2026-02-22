//
//  Gemini.swift
//  LangTools
//
//  Created by Reid Chatham on 12/22/24.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LangTools
import OpenAI

public final class Gemini: LangTools {
    public typealias Model = GeminiModel
    public typealias ErrorResponse = GeminiErrorResponse

    public static var requestValidators: [(any LangToolsRequest) -> Bool] {
        [
            { ($0 as? OpenAI.ChatCompletionRequest).flatMap { OpenAIModel.geminiModels.contains($0.model) } ?? false },
        ]
    }

    public var session: URLSession { openAI.session }

    let openAI: OpenAI

    public init(baseURL: URL = URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/")!, apiKey: String, session: URLSession = URLSession(configuration: .default, delegate: nil, delegateQueue: nil)) {
        openAI = OpenAI(configuration: .init(baseURL: baseURL, apiKey: apiKey, session: session))
    }

    public func prepare(request: some LangToolsRequest) throws -> URLRequest {
        try openAI.prepare(request: request)
    }

    public static func chatRequest(model: any RawRepresentable, messages: [any LangToolsMessage], tools: [any LangToolsTool]?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) throws -> any LangToolsChatRequest {
        guard let model = model as? Model else { throw LangToolsError.invalidArgument("Unsupported model \(model)") }
        return try OpenAI.chatRequest(model: model.openAIModel, messages: messages, tools: tools, toolEventHandler: toolEventHandler)
    }
}

public struct GeminiErrorResponse: Error, Codable {
    public let type: String?
    public let error: APIError

    public struct APIError: Error, Codable {
        public let message: String
        public let type: String
        public let param: String?
        public let code: String?
    }
}

public enum GeminiModel: String, CaseIterable {
    // MARK: - Gemini 3.x Models (February 2026)
    case gemini3FlashPreview = "gemini-3-flash-preview"
    case gemini3ProImage = "gemini-3-pro-image"
    case gemini31Pro = "gemini-3.1-pro"

    // MARK: - Gemini 2.5 Models
    case gemini25Flash = "gemini-2.5-flash"
    case gemini25FlashLite = "gemini-2.5-flash-lite"

    // MARK: - Gemini 2.0 Models (Retiring March 31, 2026)
    /// Deprecated: Retiring March 31, 2026. Use gemini25Flash instead.
    case gemini2Flash = "gemini-2.0-flash-exp"
    /// Deprecated: Retiring March 31, 2026. Use gemini25Flash instead.
    case gemini2FlashThinking = "gemini-2.0-flash-thinking-exp"

    // MARK: - Gemini 1.5 Models
    case gemini15Flash = "gemini-1.5-flash"
    case gemini15Flash8B = "gemini-1.5-flash-8b"
    case gemini15Pro = "gemini-1.5-pro"

    // MARK: - Gemini 1.5 Versioned Models
    case gemini15FlashLatest = "gemini-1.5-flash-latest"
    case gemini15Flash001 = "gemini-1.5-flash-001"
    case gemini15Flash002 = "gemini-1.5-flash-002"
    case gemini15Flash8BLatest = "gemini-1.5-flash-8b-latest"
    case gemini15Flash8B001 = "gemini-1.5-flash-8b-001"
    case gemini15ProLatest = "gemini-1.5-pro-latest"
    case gemini15Pro001 = "gemini-1.5-pro-001"
    case gemini15Pro002 = "gemini-1.5-pro-002"

    // MARK: - Gemini 1.0 Models (Legacy)
    /// Deprecated: Use Gemini 1.5 or newer models for better performance.
    case gemini10Pro = "gemini-1.0-pro"

    var openAIModel: OpenAIModel { OpenAIModel(customModelID: rawValue) }

    /// Returns true if this model is deprecated or scheduled for retirement.
    public var isDeprecated: Bool {
        switch self {
        case .gemini2Flash, .gemini2FlashThinking, .gemini10Pro:
            return true
        default:
            return false
        }
    }
}

extension OpenAIModel {
    static let geminiModels = Gemini.Model.allCases.map { $0.openAIModel }
}

extension OpenAI.ChatCompletionRequest {
    public init(model: Gemini.Model, messages: [Message], temperature: Double? = nil, top_p: Double? = nil, n: Int? = nil, stream: Bool? = nil, stream_options: StreamOptions? = nil, stop: Stop? = nil, max_tokens: Int? = nil, presence_penalty: Double? = nil, frequency_penalty: Double? = nil, logit_bias: [String: Double]? = nil, logprobs: Bool? = nil, top_logprobs: Int? = nil, user: String? = nil, response_type: ResponseType? = nil, seed: Int? = nil, tools: [Tool]? = nil, tool_choice: ToolChoice? = nil, parallel_tool_calls: Bool? = nil, choose: @escaping ([Response.Choice]) -> Int = {_ in 0}) {
        self.init(model: model.openAIModel, messages: messages, temperature: temperature, top_p: top_p, n: n, stream: stream, stream_options: stream_options, stop: stop, max_tokens: max_tokens, presence_penalty: presence_penalty, frequency_penalty: frequency_penalty, logit_bias: logit_bias, logprobs: logprobs, top_logprobs: top_logprobs, user: user, response_type: response_type, seed: seed, tools: tools, tool_choice: tool_choice, parallel_tool_calls: parallel_tool_calls, choose: choose)
    }
}
