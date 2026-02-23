//
//  XAI.swift
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

public final class XAI: LangTools {
    public typealias Model = XAIModel
    public typealias ErrorResponse = XAIErrorResponse

    public static var requestValidators: [(any LangToolsRequest) -> Bool] {
        [
            { ($0 as? OpenAI.ChatCompletionRequest).flatMap { OpenAIModel.xAIModels.contains($0.model) } ?? false },
        ]
    }

    public var session: URLSession { openAI.session }

    let openAI: OpenAI

    public init(baseURL: URL = URL(string: "https://api.x.ai/v1/")!, apiKey: String) {
        openAI = OpenAI(configuration: .init(baseURL: baseURL, apiKey: apiKey))
    }

    public func prepare(request: some LangToolsRequest) throws -> URLRequest {
        try openAI.prepare(request: request)
    }

    public static func chatRequest(model: any RawRepresentable, messages: [any LangToolsMessage], tools: [any LangToolsTool]?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) throws -> any LangToolsChatRequest {
        guard let model = model as? Model else { throw LangToolsError.invalidArgument("Unsupported model \(model)") }
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

// CaseIterable is declared in the extension below rather than here to allow
// @available(*, deprecated) on individual cases without breaking synthesis.
public enum XAIModel: String {
    // MARK: - Grok 4.1 Models - Active
    case grok41FastReasoning = "grok-4-1-fast-reasoning"
    case grok41FastNonReasoning = "grok-4-1-fast-non-reasoning"

    // MARK: - Grok 4 Models - Active
    case grok4FastReasoning = "grok-4-fast-reasoning"
    case grok4FastNonReasoning = "grok-4-fast-non-reasoning"
    case grok4_0709 = "grok-4-0709"

    // MARK: - Grok 3 Models - Active
    case grok3 = "grok-3"
    case grok3_mini = "grok-3-mini"

    // MARK: - Grok Code Models - Active
    case grokCodeFast = "grok-code-fast-1"

    // MARK: - Grok 2 Models - Active
    case grok2Vision = "grok-2-vision-1212"
    case grok2Image = "grok-2-image-1212"

    // MARK: - Image Generation Models - Active
    case grokImagineImage = "grok-imagine-image"
    case grokImagineImagePro = "grok-imagine-image-pro"
    case grokImagineVideo = "grok-imagine-video"

    // MARK: - Legacy Models
    @available(*, deprecated, message: "Use grok3 or grok4FastReasoning instead.")
    case grok = "grok-2-1212"
    @available(*, deprecated, message: "Use grok3 or newer models instead.")
    case grokBeta = "grok-beta"

    var openAIModel: OpenAIModel { OpenAIModel(customModelID: rawValue) }
}

// MARK: - CaseIterable
// Manual implementation required: @available(*, deprecated) on enum cases
// breaks synthesized CaseIterable conformance in Swift.
extension XAIModel: CaseIterable {
    public static var allCases: [XAIModel] {
        let active: [XAIModel] = [
            .grok41FastReasoning, .grok41FastNonReasoning,
            .grok4FastReasoning, .grok4FastNonReasoning, .grok4_0709,
            .grok3, .grok3_mini,
            .grokCodeFast,
            .grok2Vision, .grok2Image,
            .grokImagineImage, .grokImagineImagePro, .grokImagineVideo,
        ]
        // Use rawValue init to include deprecated cases without re-triggering warnings.
        let legacy = ["grok-2-1212", "grok-beta"].compactMap(XAIModel.init(rawValue:))
        return active + legacy
    }
}

extension OpenAIModel {
    static let xAIModels = XAI.Model.allCases.map { $0.openAIModel }
}

extension OpenAI.ChatCompletionRequest {
    public init(model: XAI.Model, messages: [Message], temperature: Double? = nil, top_p: Double? = nil, n: Int? = nil, stream: Bool? = nil, stream_options: StreamOptions? = nil, stop: Stop? = nil, max_tokens: Int? = nil, presence_penalty: Double? = nil, frequency_penalty: Double? = nil, logit_bias: [String: Double]? = nil, logprobs: Bool? = nil, top_logprobs: Int? = nil, user: String? = nil, response_type: ResponseType? = nil, seed: Int? = nil, tools: [Tool]? = nil, tool_choice: ToolChoice? = nil, parallel_tool_calls: Bool? = nil, choose: @escaping ([Response.Choice]) -> Int = {_ in 0}) {
        self.init(model: model.openAIModel, messages: messages, temperature: temperature, top_p: top_p, n: n, stream: stream, stream_options: stream_options, stop: stop, max_tokens: max_tokens, presence_penalty: presence_penalty, frequency_penalty: frequency_penalty, logit_bias: logit_bias, logprobs: logprobs, top_logprobs: top_logprobs, user: user, response_type: response_type, seed: seed, tools: tools, tool_choice: tool_choice, parallel_tool_calls: parallel_tool_calls, choose: choose)
    }
}
