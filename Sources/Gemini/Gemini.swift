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

// CaseIterable is declared in the extension below rather than here to allow
// @available(*, deprecated) on individual cases without breaking synthesis.
public enum GeminiModel: String {
    // MARK: - Gemini 3.x Models - Active
    case gemini3Pro = "gemini-3-pro"
    case gemini3ProPreview = "gemini-3-pro-preview"
    case gemini3Flash = "gemini-3-flash"
    case gemini3FlashPreview = "gemini-3-flash-preview"
    case gemini31Pro = "gemini-3.1-pro"

    // MARK: - Gemini 2.5 Models (Retiring June 17, 2026)
    @available(*, deprecated, message: "Retiring June 17, 2026. Use gemini3Flash instead.")
    case gemini25Flash = "gemini-2.5-flash"
    @available(*, deprecated, message: "Retiring June 17, 2026. Use gemini3Flash instead.")
    case gemini25FlashLite = "gemini-2.5-flash-lite"
    @available(*, deprecated, message: "Retiring June 17, 2026. Use gemini3Pro instead.")
    case gemini25Pro = "gemini-2.5-pro"

    // MARK: - Gemini 2.0 Models (Retiring June 1, 2026)
    @available(*, deprecated, message: "Retiring June 1, 2026. Use gemini3Flash instead.")
    case gemini2Flash = "gemini-2.0-flash"

    @available(*, deprecated, message: "Retiring June 1, 2026. Use gemini3FlashLite instead.")
    case gemini2FlashLite = "gemini-2.0-flash-lite"

    // MARK: - Retired Models (return 404 errors)
    @available(*, deprecated, message: "Retired: Returns 404. Use gemini3Flash instead.")
    case gemini15Flash = "gemini-1.5-flash"
    @available(*, deprecated, message: "Retired: Returns 404. Use gemini3Flash instead.")
    case gemini15Flash8B = "gemini-1.5-flash-8b"
    @available(*, deprecated, message: "Retired: Returns 404. Use gemini3Pro instead.")
    case gemini15Pro = "gemini-1.5-pro"
    @available(*, deprecated, message: "Retired: Returns 404. Use gemini3Pro instead.")
    case gemini10Pro = "gemini-1.0-pro"

    var openAIModel: OpenAIModel { OpenAIModel(customModelID: rawValue) }
}

// MARK: - Model Lifecycle
extension GeminiModel {
    /// Returns `true` if this model is deprecated (still functional but retiring soon).
    /// Uses rawValue comparison to avoid triggering deprecation warnings internally.
    public var isDeprecated: Bool {
        let deprecatedRawValues: Set<String> = [
            "gemini-2.5-flash",
            "gemini-2.5-flash-lite",
            "gemini-2.5-pro",
            "gemini-2.0-flash",
            "gemini-2.0-flash-lite",
        ]
        return deprecatedRawValues.contains(rawValue)
    }

    /// Returns `true` if this model has been retired (returns 404 errors).
    /// Uses rawValue comparison to avoid triggering deprecation warnings internally.
    public var isRetired: Bool {
        let retiredRawValues: Set<String> = [
            "gemini-1.5-flash",
            "gemini-1.5-flash-8b",
            "gemini-1.5-pro",
            "gemini-1.0-pro",
        ]
        return retiredRawValues.contains(rawValue)
    }
}

// MARK: - CaseIterable
// Manual implementation required: @available(*, deprecated) on enum cases
// breaks synthesized CaseIterable conformance in Swift.
extension GeminiModel: CaseIterable {
    public static var allCases: [GeminiModel] {
        let active: [GeminiModel] = [
            .gemini3Pro, .gemini3ProPreview, .gemini3Flash, .gemini3FlashPreview, .gemini31Pro,
        ]
        // Use rawValue init to include deprecated/retired cases without re-triggering warnings.
        let legacy = [
            "gemini-2.5-flash", "gemini-2.5-flash-lite", "gemini-2.5-pro",
            "gemini-2.0-flash", "gemini-2.0-flash-lite",
            "gemini-1.5-flash", "gemini-1.5-flash-8b", "gemini-1.5-pro", "gemini-1.0-pro",
        ].compactMap(GeminiModel.init(rawValue:))
        return active + legacy
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
