//
//  Ollama.swift
//  LangTools
//
//  Created by Claude on 1/18/25.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LangTools
import OpenAI

public final class Ollama: LangTools {
    public typealias Model = OllamaModel
    public typealias ErrorResponse = OllamaErrorResponse

    public var configuration: OllamaConfiguration
    public var session: URLSession { configuration.session }

    public struct OllamaConfiguration {
        public var baseURL: URL
        public var session: URLSession

        public init(baseURL: URL = URL(string: "http://localhost:11434")!, session: URLSession = URLSession(configuration: .default, delegate: nil, delegateQueue: nil)) {
            self.baseURL = baseURL
            self.session = session
        }
    }

    public static var requestValidators: [(any LangToolsRequest) -> Bool] {
        return [
            { $0 is ListModelsRequest },
            { $0 is ListRunningModelsRequest },
            { $0 is ShowModelRequest },
            { $0 is DeleteModelRequest },
            { $0 is CopyModelRequest },
            { $0 is PullModelRequest },
            { $0 is PushModelRequest },
            { $0 is CreateModelRequest },
            { $0 is ChatRequest },
            { $0 is GenerateRequest },
            { $0 is VersionRequest }
        ]
    }

    public init(baseURL: URL = URL(string: "http://localhost:11434")!, session: URLSession = URLSession(configuration: .default, delegate: nil, delegateQueue: nil)) {
        configuration = OllamaConfiguration(baseURL: baseURL, session: session)
    }

    public init(configuration: OllamaConfiguration) {
        self.configuration = configuration
    }

    public func prepare<Request: LangToolsRequest>(request: Request) throws -> URLRequest {
        var url = configuration.baseURL.appending(path: request.endpoint)
        if Request.httpMethod == .get {
            if let id = (request as? any Identifiable)?.id as? String {
                url = url.appending(path: id)
            }
            let queryItems = Mirror(reflecting: request).children
                .filter { $0.label != nil && $0.label != "id" }
                .map { URLQueryItem(name: $0.label!, value: String(describing: $0.value))}
            if !queryItems.isEmpty {
                url = url.appending(queryItems: queryItems)
            }
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = Request.httpMethod.rawValue

        if Request.httpMethod == .get { return urlRequest }

        urlRequest.addValue("application/json", forHTTPHeaderField: "Content-Type")
        do { urlRequest.httpBody = try JSONEncoder().encode(request) }
        catch { throw LangToolsError.invalidData }

        return urlRequest
    }

    public static func decodeStream<T: Decodable>(_ buffer: String) throws -> T? {
        return try buffer.data(using: .utf8).map { try Self.decodeResponse(data: $0) }
    }
}

public struct OllamaErrorResponse: Error, Codable {
    public let error: APIError

    public struct APIError: Error, Codable {
        public let message: String
        public let type: String
    }
}

public struct OllamaModel: RawRepresentable, Codable, Hashable, CaseIterable {

    static public var allCases: [OllamaModel] = []

    public let rawValue: String

    public init?(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public struct Details: Codable {
        public let format: String?
        public let family: String?
        public let families: [String]?
        public let parameterSize: String?
        public let quantizationLevel: String?

        enum CodingKeys: String, CodingKey {
            case format
            case family
            case families
            case parameterSize = "parameter_size"
            case quantizationLevel = "quantization_level"
        }
    }
}

extension OllamaModel {
    var openAIModel: OpenAIModel { .init(customModelID: rawValue) }
}

extension OpenAIModel {
    static var ollamaModels: [OpenAIModel] { OllamaModel.allCases.map { $0.openAIModel } }
}

extension OpenAI.ChatCompletionRequest {
    public init(
        model: Ollama.Model, messages: [Message], temperature: Double? = nil, top_p: Double? = nil,
        n: Int? = nil, stream: Bool? = nil, stream_options: StreamOptions? = nil, stop: Stop? = nil,
        max_tokens: Int? = nil, presence_penalty: Double? = nil, frequency_penalty: Double? = nil,
        logit_bias: [String: Double]? = nil, logprobs: Bool? = nil, top_logprobs: Int? = nil,
        user: String? = nil, response_type: ResponseType? = nil, seed: Int? = nil,
        tools: [Tool]? = nil, tool_choice: ToolChoice? = nil, parallel_tool_calls: Bool? = nil,
        choose: @escaping ([Response.Choice]) -> Int = { _ in 0 }
    ) {
        self.init(
            model: model.openAIModel, messages: messages, temperature: temperature, top_p: top_p,
            n: n, stream: stream, stream_options: stream_options, stop: stop,
            max_tokens: max_tokens, presence_penalty: presence_penalty,
            frequency_penalty: frequency_penalty, logit_bias: logit_bias, logprobs: logprobs,
            top_logprobs: top_logprobs, user: user, response_type: response_type, seed: seed,
            tools: tools, tool_choice: tool_choice, parallel_tool_calls: parallel_tool_calls,
            choose: choose)
    }
}

// MARK: - Testing
extension Ollama {
    internal func configure(testURLSessionConfiguration: URLSessionConfiguration) -> Self {
        configuration.session = URLSession(configuration: testURLSessionConfiguration, delegate: session.delegate, delegateQueue: session.delegateQueue)
        return self
    }
}
