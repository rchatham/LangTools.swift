//
//  Ollama.swift
//  Ollama
//
//  Created by Reid Chatham on 1/6/25.
//

import Foundation
import LangTools
import OpenAI

public final class Ollama: LangTools {
    public typealias Model = OllamaModel
    public typealias ErrorResponse = OllamaErrorResponse

    public var requestTypes: [(any LangToolsRequest) -> Bool] {
        [
            { ($0 as? OpenAI.ChatCompletionRequest).flatMap { OpenAIModel.ollamaModels.contains($0.model) } ?? false },
        ]
    }

    public private(set) lazy var session: URLSession = URLSession(configuration: .default, delegate: streamManager, delegateQueue: nil)
    public let streamManager = StreamSessionManager<Ollama>()

    let openAI: OpenAI

    public init(baseURL: URL = URL(string: "http://localhost:11434")!) {
        openAI = OpenAI(configuration: .init(baseURL: baseURL, apiKey: "ollama"))
    }

    internal func configure(testURLSessionConfiguration: URLSessionConfiguration) -> Self {
        session = URLSession(configuration: testURLSessionConfiguration, delegate: streamManager, delegateQueue: nil)
        return self
    }

    public func prepare(request: some LangToolsRequest) throws -> URLRequest {
        try openAI.prepare(request: request)
    }

    public static func processStream(data: Data, completion: @escaping (Data) -> Void) {
        OpenAI.processStream(data: data, completion: completion)
    }
}

public struct OllamaErrorResponse: Error, Codable {
    public let error: APIError

    public struct APIError: Error, Codable {
        public let message: String
        public let type: String
        public let param: String?
        public let code: String?
    }
}

public struct OllamaModel: Codable, CaseIterable, Equatable, Identifiable, RawRepresentable {

    public static var allCases: [OllamaModel] = []

    public init?(rawValue: String) {
        guard let id = ModelID(rawValue: rawValue) else { return nil }
        self = Self.init(modelID: id)
    }

    public init(modelID: ModelID) {
        id = modelID
        if !Self.allCases.contains(self) {
            Self.allCases.append(self)
        }
    }

    public var id: ModelID
    public var rawValue: String { id.rawValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        id = ModelID(stringLiteral: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(id)
    }

    public static func ==(_ lhs: OllamaModel, _ rhs: OllamaModel) -> Bool {
        return lhs.id == rhs.id
    }

    var openAIModel: OpenAIModel { OpenAIModel(customModelID: rawValue) }

    public struct ModelID: Hashable, Equatable, Comparable, RawRepresentable, CustomStringConvertible, ExpressibleByStringLiteral, ExpressibleByStringInterpolation, Codable {
        /// The optional namespace of the model.
        /// Namespaces are used to organize models, often representing the creator or organization.
        public let namespace: String?

        /// The name of the model.
        /// This is the primary identifier for the model.
        public let model: String

        /// The optional tag (version) of the model.
        /// Tags are used to specify different versions or variations of the same model.
        public let tag: String?

        /// The raw string representation of the model identifier.
        public typealias RawValue = String

        // MARK: Equatable & Comparable

        /// Compares two `ModelID` instances for equality.
        /// The comparison is case-insensitive.
        public static func == (lhs: ModelID, rhs: ModelID) -> Bool {
            return lhs.rawValue.caseInsensitiveCompare(rhs.rawValue) == .orderedSame
        }

        /// Compares two `ModelID` instances for ordering.
        /// The comparison is case-insensitive.
        public static func < (lhs: ModelID, rhs: ModelID) -> Bool {
            return lhs.rawValue.caseInsensitiveCompare(rhs.rawValue) == .orderedAscending
        }

        // MARK: RawRepresentable

        /// Initializes a `ModelID` from a raw string value.
        /// The raw value should be in the format `"[namespace/]model[:tag]"`.
        public init?(rawValue: RawValue) {
            let components = rawValue.split(separator: "/", maxSplits: 1)

            if components.count == 2 {
                self.namespace = String(components[0])
                let modelAndTag = components[1].split(separator: ":", maxSplits: 1)
                self.model = String(modelAndTag[0])
                self.tag = modelAndTag.count > 1 ? String(modelAndTag[1]) : nil
            } else {
                self.namespace = nil
                let modelAndTag = rawValue.split(separator: ":", maxSplits: 1)
                self.model = String(modelAndTag[0])
                self.tag = modelAndTag.count > 1 ? String(modelAndTag[1]) : nil
            }
        }

        /// Returns the raw string representation of the `ModelID`.
        public var rawValue: String {
            let namespaceString = namespace.map { "\($0)/" } ?? ""
            let tagString = tag.map { ":\($0)" } ?? ""
            return "\(namespaceString)\(model)\(tagString)"
        }

        // MARK: CustomStringConvertible

        /// A textual representation of the `ModelID`.
        public var description: String {
            return rawValue
        }

        // MARK: ExpressibleByStringLiteral

        /// Initializes a `ModelID` from a string literal.
        public init(stringLiteral value: StringLiteralType) {
            self.init(rawValue: value)!
        }

        // MARK: ExpressibleByStringInterpolation

        /// Initializes a `ModelID` from a string interpolation.
        public init(stringInterpolation: DefaultStringInterpolation) {
            self.init(rawValue: stringInterpolation.description)!
        }

        // MARK: Codable

        /// Decodes a `ModelID` from a single string value.
        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self)
            guard let identifier = Self.init(rawValue: rawValue) else {
                throw DecodingError.dataCorruptedError( in: container, debugDescription: "Invalid Identifier string: \(rawValue)")
            }
            self = identifier
        }

        /// Encodes the `ModelID` as a single string value.
        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }

        // MARK: Pattern Matching

        /// Defines the pattern matching operator for `ID`.
        /// This allows for partial matching based on namespace, model name, and tag.
        public static func ~= (pattern: Self, value: Self) -> Bool {
            if let patternNamespace = pattern.namespace, patternNamespace != value.namespace {
                return false
            }
            if pattern.model != value.model {
                return false
            }
            if let patternTag = pattern.tag, patternTag != value.tag {
                return false
            }
            return true
        }
    }

    // MARK: -

    /// Represents additional information about a model.
    public struct Details: Hashable, Decodable {
        /// The format of the model file (e.g., "gguf").
        public let format: String

        /// The primary family or architecture of the model (e.g., "llama").
        public let family: String

        /// Additional families or architectures the model belongs to, if any.
        public let families: [String]?

        /// The parameter size of the model (e.g., "7B", "13B").
        public let parameterSize: String

        /// The quantization level of the model (e.g., "Q4_0").
        public let quantizationLevel: String

        /// The parent model, if this model is derived from another.
        public let parentModel: String?

        /// Coding keys for mapping JSON keys to struct properties.
        enum CodingKeys: String, CodingKey {
            case format, family, families
            case parameterSize = "parameter_size"
            case quantizationLevel = "quantization_level"
            case parentModel = "parent_model"
        }
    }
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
