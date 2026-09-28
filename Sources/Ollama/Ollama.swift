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
        public var apiKey: String?
        /// Cloud routing for `:cloud`-suffixed models: requests for those models
        /// go to this host with the cloud API key, while local models keep using
        /// `baseURL` (which may itself proxy cloud models when the daemon is
        /// signed in).
        public var cloudBaseURL: URL?
        public var cloudAPIKey: String?
        public var session: URLSession

        public init(
            baseURL: URL = URL(string: "http://localhost:11434")!,
            session: URLSession = URLSession(configuration: .default, delegate: nil, delegateQueue: nil)
        ) {
            self.baseURL = baseURL
            self.apiKey = nil
            self.cloudBaseURL = nil
            self.cloudAPIKey = nil
            self.session = session
        }

        public init(
            baseURL: URL = URL(string: "http://localhost:11434")!,
            apiKey: String,
            session: URLSession = URLSession(configuration: .default, delegate: nil, delegateQueue: nil)
        ) {
            self.baseURL = baseURL
            self.apiKey = apiKey
            self.cloudBaseURL = nil
            self.cloudAPIKey = nil
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

    public init(
        baseURL: URL = URL(string: "http://localhost:11434")!,
        session: URLSession = URLSession(configuration: .default, delegate: nil, delegateQueue: nil)
    ) {
        configuration = OllamaConfiguration(baseURL: baseURL, session: session)
    }

    public init(
        baseURL: URL = URL(string: "http://localhost:11434")!,
        apiKey: String,
        session: URLSession = URLSession(configuration: .default, delegate: nil, delegateQueue: nil)
    ) {
        configuration = OllamaConfiguration(baseURL: baseURL, apiKey: apiKey, session: session)
    }

    public init(
        baseURL: URL = URL(string: "http://localhost:11434")!,
        apiKey: String,
        cloudBaseURL: URL,
        cloudAPIKey: String,
        session: URLSession = URLSession(configuration: .default, delegate: nil, delegateQueue: nil)
    ) {
        configuration = OllamaConfiguration(
            baseURL: baseURL,
            apiKey: apiKey,
            session: session
        )
        configuration.cloudBaseURL = cloudBaseURL
        configuration.cloudAPIKey = cloudAPIKey
    }

    public init(configuration: OllamaConfiguration) {
        self.configuration = configuration
    }

    /// Whether the request targets an Ollama-hosted cloud model (":cloud"
    /// suffix) — those are served by ollama.com instead of the local daemon.
    private func isCloudTargeted(_ request: any LangToolsRequest) -> Bool {
        if let chat = request as? ChatRequest {
            return chat.model.isCloudModel
        }
        if let generate = request as? GenerateRequest {
            return generate.model.hasSuffix(":cloud")
        }
        return false
    }

    public func prepare<Request: LangToolsRequest>(request: Request) throws -> URLRequest {
        let cloudTargeted = isCloudTargeted(request)
        let baseURL = cloudTargeted
            ? (configuration.cloudBaseURL ?? configuration.baseURL)
            : configuration.baseURL
        var url = baseURL.appending(path: request.endpoint)
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
        let apiKey = cloudTargeted
            ? (configuration.cloudAPIKey ?? configuration.apiKey)
            : configuration.apiKey
        if let apiKey, !apiKey.isEmpty {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

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

    /// Ollama-hosted cloud models carry the `:cloud` suffix (e.g.
    /// "glm-5.2:cloud") and are served by ollama.com rather than the local
    /// daemon.
    public var isCloudModel: Bool { rawValue.hasSuffix(":cloud") }

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
