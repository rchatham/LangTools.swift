//
//  Ollama.swift
//  LangTools
//
//  Created by Claude on 1/18/25.
//

import Foundation
import LangTools
import OpenAI

public final class Ollama: LangTools {
    public typealias Model = OllamaModel
    public typealias ErrorResponse = OllamaErrorResponse

    private var configuration: OllamaConfiguration

    public struct OllamaConfiguration {
        public var baseURL: URL

        public init(baseURL: URL = URL(string: "http://localhost:11434")!) {
            self.baseURL = baseURL
        }
    }

    public private(set) lazy var session: URLSession = URLSession(configuration: .default, delegate: nil, delegateQueue: nil)

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

    public init(baseURL: URL = URL(string: "http://localhost:11434")!) {
        configuration = OllamaConfiguration(baseURL: baseURL)
    }

    public init(configuration: OllamaConfiguration) {
        self.configuration = configuration
    }

    internal func configure(testURLSessionConfiguration: URLSessionConfiguration) -> Self {
        session = URLSession(configuration: testURLSessionConfiguration, delegate: nil, delegateQueue: nil)
        return self
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
        catch { throw LangToolError.invalidData }

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

// Helper Types
public enum Value: Codable {
    case string(String)
    case bool(Bool)
    case int(Int)
    case double(Double)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) {
            self = .string(str)
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? container.decode(Int.self) {
            self = .int(int)
        } else if let double = try? container.decode(Double.self) {
            self = .double(double)
        } else if container.decodeNil() {
            self = .null
        } else {
            throw DecodingError.typeMismatch(Value.self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Invalid value type"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let str): try container.encode(str)
        case .bool(let bool): try container.encode(bool)
        case .int(let int): try container.encode(int)
        case .double(let double): try container.encode(double)
        case .null: try container.encodeNil()
        }
    }

    var string: String? { if case .string(let val) = self { val } else { nil }}
    var integer: Int? { if case .int(let val) = self { val } else { nil }}
    var bool: Bool? { if case .bool(let val) = self { val } else { nil }}
    var double: Double? { if case .double(let val) = self { val } else { nil }}
    var isNull: Bool { if case .null = self { true } else { false }}
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
