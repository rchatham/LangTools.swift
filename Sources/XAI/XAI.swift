//
//  XAI.swift
//  LangTools
//
//  Created by Reid Chatham on 12/22/24.
//

import Foundation
import LangTools
import OpenAI

public final class XAI: LangTools {
    public typealias Model = XAIModel
    public typealias ErrorResponse = XAIErrorResponse

    public static var requestValidators: [(any LangToolsRequest) -> Bool] {
        [
            { ($0 as? OpenAI.ChatCompletionRequest).flatMap { OpenAIModel.xAIModels.contains($0.model) } ?? false },
        ]
    }

    public private(set) lazy var session: URLSession = URLSession(configuration: .default, delegate: nil, delegateQueue: nil)

    let openAI: OpenAI

    public init(baseURL: URL = URL(string: "https://api.x.ai/v1/")!, apiKey: String) {
        openAI = OpenAI(configuration: .init(baseURL: baseURL, apiKey: apiKey))
    }

    internal func configure(testURLSessionConfiguration: URLSessionConfiguration) -> Self {
        session = URLSession(configuration: testURLSessionConfiguration, delegate: nil, delegateQueue: nil)
        return self
    }

    public func prepare(request: some LangToolsRequest) throws -> URLRequest {
        try openAI.prepare(request: request)
    }

    public static func chatRequest(model: Model, messages: [any LangToolsMessage], tools: [any LangToolsTool]?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) throws -> any LangToolsChatRequest {
        return try OpenAI.chatRequest(model: model.openAIModel, messages: messages, tools: tools, toolEventHandler: toolEventHandler)
    }
}

public struct XAIErrorResponse: Error, Codable {
    public let type: String?
    public let error: APIError

    public struct APIError: Error, Codable {
        public let message: String
        public let type: String
        public let param: String?
        public let code: String?
    }
}

public enum XAIModel: String, CaseIterable {
    case grok = "grok-2-1212"
    case grokVision = "grok-2-vision-1212"

    var openAIModel: OpenAIModel { OpenAIModel(customModelID: rawValue) }
}

extension OpenAIModel {
    static let xAIModels = XAI.Model.allCases.map { $0.openAIModel }
}

extension OpenAI.ChatCompletionRequest {
    public init(model: XAI.Model, messages: [Message], temperature: Double? = nil, top_p: Double? = nil, n: Int? = nil, stream: Bool? = nil, stream_options: StreamOptions? = nil, stop: Stop? = nil, max_tokens: Int? = nil, presence_penalty: Double? = nil, frequency_penalty: Double? = nil, logit_bias: [String: Double]? = nil, logprobs: Bool? = nil, top_logprobs: Int? = nil, user: String? = nil, response_type: ResponseType? = nil, seed: Int? = nil, tools: [Tool]? = nil, tool_choice: ToolChoice? = nil, parallel_tool_calls: Bool? = nil, choose: @escaping ([Response.Choice]) -> Int = {_ in 0}) {
        self.init(model: model.openAIModel, messages: messages, temperature: temperature, top_p: top_p, n: n, stream: stream, stream_options: stream_options, stop: stop, max_tokens: max_tokens, presence_penalty: presence_penalty, frequency_penalty: frequency_penalty, logit_bias: logit_bias, logprobs: logprobs, top_logprobs: top_logprobs, user: user, response_type: response_type, seed: seed, tools: tools, tool_choice: tool_choice, parallel_tool_calls: parallel_tool_calls, choose: choose)
    }
}
