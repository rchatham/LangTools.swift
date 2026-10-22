//
//  OpenAICompatibleProvider.swift
//  OpenAI
//
//  Shared plumbing for providers that serve OpenAI's Chat Completions API at
//  their own base URL (Groq, Mistral, DeepSeek, Vercel AI Gateway, ...). A
//  provider supplies its identity and an `OpenAI` client configured for its
//  endpoint; routing, request preparation, error decoding, and model listing
//  come from the extensions below.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LangTools

/// A provider whose chat endpoint is wire-compatible with OpenAI's.
///
/// Requests are `OpenAI.ChatCompletionRequest`s whose model carries the
/// provider's tag (see `OpenAICompatibleModel.openAIModel`), so several
/// providers serving the same model names can share one `LangToolchain`.
///
/// Conforming types declare `typealias Model = OpenAICompatibleModel<Self>`
/// and `typealias ErrorResponse = OpenAICompatibleErrorResponse`.
public protocol OpenAICompatibleProvider: LangTools where ErrorResponse == OpenAICompatibleErrorResponse {
    /// The tag carried by this provider's models.
    static var providerID: LangToolsProviderID { get }
    /// A human-readable name, such as `"Groq"`.
    static var displayName: String { get }
    static var defaultBaseURL: URL { get }
    /// The environment variable conventionally holding the API key, such as
    /// `"GROQ_API_KEY"`.
    static var apiKeyEnvironmentVariable: String { get }
    /// Whether the provider serves `GET /models` at its base URL.
    static var supportsModelListing: Bool { get }
    /// Models to offer before, or instead of, a catalog fetch.
    static var knownModels: [OpenAICompatibleModel<Self>] { get }

    /// The client that prepares requests for this provider's endpoint.
    var openAI: OpenAI { get }

    /// Adjusts an encoded chat completion body for this provider's dialect,
    /// such as dropping parameters it rejects. The default changes nothing.
    /// See `OpenAICompatibleBody` for helpers.
    static func adaptChatBody(_ body: inout [String: JSON])
}

extension OpenAICompatibleProvider {
    public static var supportsModelListing: Bool { true }
    public static var knownModels: [OpenAICompatibleModel<Self>] { [] }
    public static func adaptChatBody(_ body: inout [String: JSON]) {}

    public var session: URLSession { openAI.session }
    public var logger: LangToolsLogger? { openAI.logger }

    /// Claims chat requests whose model is tagged for this provider, and this
    /// provider's catalog request. Untagged models are left to OpenAI, XAI,
    /// and Gemini.
    public static var requestValidators: [(any LangToolsRequest) -> Bool] {
        [
            { ($0 as? OpenAI.ChatCompletionRequest)?.model.belongs(to: providerID) ?? false },
            { $0 is OpenAICompatibleListModelsRequest<Self> },
        ]
    }

    public func prepare(request: some LangToolsRequest) throws -> URLRequest {
        var urlRequest = try openAI.prepare(request: request)
        if request is OpenAI.ChatCompletionRequest, let data = urlRequest.httpBody,
           case .object(var body) = try JSONDecoder().decode(JSON.self, from: data) {
            let original = body
            Self.adaptChatBody(&body)
            if body != original { urlRequest.httpBody = try JSONEncoder().encode(JSON.object(body)) }
        }
        return urlRequest
    }

    public static func chatRequest(model: any RawRepresentable, messages: [any LangToolsMessage], tools: [any LangToolsTool]?, responseSchema: JSONSchema?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) throws -> any LangToolsChatRequest {
        guard let model = model as? OpenAICompatibleModel<Self> else { throw LangToolsError.invalidArgument("Unsupported model \(model)") }
        return try OpenAI.chatRequest(model: model.openAIModel, messages: messages, tools: tools, responseSchema: responseSchema, toolEventHandler: toolEventHandler)
    }

    /// Lists the provider's catalog with `GET /models`. Entries that fail to
    /// decode are skipped. Throws `LangToolsError.invalidArgument` for a
    /// provider without a catalog endpoint; use `knownModels` there.
    public func listModels() async throws -> [OpenAICompatibleModelInfo] {
        guard Self.supportsModelListing else {
            throw LangToolsError.invalidArgument("\(Self.displayName) does not list models; use knownModels")
        }
        return try await perform(request: OpenAICompatibleListModelsRequest<Self>()).data
    }

    /// Builds the `OpenAI` client for an OpenAI-compatible endpoint.
    public static func makeClient(baseURL: URL, apiKey: String, session: URLSession, logger: LangToolsLogger?, additionalHeaders: [String: String] = [:]) -> OpenAI {
        OpenAI(configuration: .init(baseURL: baseURL, apiKey: apiKey, session: session, logger: logger, additionalHeaders: additionalHeaders))
    }
}

// MARK: - Model

/// A model ID for an OpenAI-compatible provider, such as `"llama-3.3-70b-versatile"`
/// on Groq. Catalogs change often, so models are plain IDs rather than an enum.
public struct OpenAICompatibleModel<Provider: OpenAICompatibleProvider>: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    /// Returns nil for an empty ID or one with leading or trailing whitespace.
    public init?(rawValue: String) {
        guard !rawValue.isEmpty, rawValue == rawValue.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        rawValue = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let id = try container.decode(String.self)
        guard let model = Self(rawValue: id) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid \(Provider.displayName) model ID")
        }
        self = model
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    /// The tagged OpenAI-compatible model used on the wire and for routing.
    public var openAIModel: OpenAIModel {
        OpenAIModel(customModelID: rawValue, providerID: Provider.providerID)
    }
}

// MARK: - Errors

/// An error body from an OpenAI-compatible provider. Decodes the shapes these
/// providers use:
/// - `{"error": {"message": "...", "type": "...", "code": ...}}` (OpenAI style)
/// - `{"error": "..."}`
/// - `{"message": "...", "type": "..."}` (top level, as Mistral and Cohere send)
/// - `{"detail": "..."}` or `{"detail": [{"msg": "..."}]}` (validation errors)
public struct OpenAICompatibleErrorResponse: Error, Codable, LocalizedError, Equatable {
    public let message: String
    public let type: String?
    /// The provider's error code; numeric codes are kept as their decimal text.
    public let code: String?
    public let param: String?

    public init(message: String, type: String? = nil, code: String? = nil, param: String? = nil) {
        self.message = message
        self.type = type
        self.code = code
        self.param = param
    }

    public var errorDescription: String? { message }

    private enum CodingKeys: String, CodingKey { case error, message, type, code, param, detail }
    private struct Detail: Decodable { let msg: String? }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let nested = try? container.nestedContainer(keyedBy: CodingKeys.self, forKey: .error),
           let message = try? nested.decode(String.self, forKey: .message) {
            self.init(message: message, type: Self.text(nested, .type), code: Self.text(nested, .code), param: Self.text(nested, .param))
        } else if let message = try? container.decode(String.self, forKey: .error) {
            self.init(message: message, type: Self.text(container, .type), code: Self.text(container, .code))
        } else if let message = try? container.decode(String.self, forKey: .message) {
            self.init(message: message, type: Self.text(container, .type), code: Self.text(container, .code), param: Self.text(container, .param))
        } else if let nested = try? container.nestedContainer(keyedBy: CodingKeys.self, forKey: .message),
                  let message = Self.detailMessage(nested) {
            // Mistral's validation errors: {"message": {"detail": [...]}, "type": ...}
            self.init(message: message, type: Self.text(container, .type), code: Self.text(container, .code))
        } else if let message = Self.detailMessage(container) {
            self.init(message: message)
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "No error message"))
        }
    }

    /// Encodes the OpenAI shape.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        var nested = container.nestedContainer(keyedBy: CodingKeys.self, forKey: .error)
        try nested.encode(message, forKey: .message)
        try nested.encodeIfPresent(type, forKey: .type)
        try nested.encodeIfPresent(code, forKey: .code)
        try nested.encodeIfPresent(param, forKey: .param)
    }

    private static func detailMessage(_ container: KeyedDecodingContainer<CodingKeys>) -> String? {
        if let detail = try? container.decode(String.self, forKey: .detail) { return detail }
        let messages = ((try? container.decode([Detail].self, forKey: .detail)) ?? []).compactMap(\.msg)
        return messages.isEmpty ? nil : messages.joined(separator: "; ")
    }

    private static func text(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> String? {
        if let string = try? container.decode(String.self, forKey: key) { return string }
        if let int = try? container.decode(Int.self, forKey: key) { return String(int) }
        return nil
    }
}

// MARK: - Model listing

/// `GET /models` for an OpenAI-compatible provider.
public struct OpenAICompatibleListModelsRequest<Provider: OpenAICompatibleProvider>: LangToolsRequest, Encodable {
    public typealias Response = OpenAICompatibleListModelsResponse
    public typealias LangTool = Provider
    public static var endpoint: String { "models" }
    public static var httpMethod: HTTPMethod { .get }

    public init() {}

    /// GET requests carry no body.
    public func encode(to encoder: Encoder) throws {}
}

/// A catalog as `{"data": [...]}` or a bare array. Entries that fail to decode
/// or have an unusable ID are skipped, since providers add fields and model
/// types over time.
public struct OpenAICompatibleListModelsResponse: Decodable {
    public let data: [OpenAICompatibleModelInfo]

    private enum CodingKeys: String, CodingKey { case data }

    public init(from decoder: Decoder) throws {
        var entries: UnkeyedDecodingContainer
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            entries = try container.nestedUnkeyedContainer(forKey: .data)
        } else {
            entries = try decoder.unkeyedContainer()
        }
        var models: [OpenAICompatibleModelInfo] = []
        while !entries.isAtEnd {
            if let model = try? entries.decode(OpenAICompatibleModelInfo.self) {
                if model.id == model.id.trimmingCharacters(in: .whitespacesAndNewlines), !model.id.isEmpty { models.append(model) }
            } else {
                _ = try entries.decode(JSON.self)
            }
        }
        data = models
    }
}

/// One catalog entry, normalized across providers. The raw entry is kept in
/// `metadata` for provider-specific fields.
public struct OpenAICompatibleModelInfo: Decodable, Identifiable, Equatable {
    public let id: String
    public let name: String?
    public let ownedBy: String?
    public let contextWindow: Int?
    public let maxOutputTokens: Int?
    /// Whether the model accepts `tools`, or nil when the catalog does not say.
    public let supportsTools: Bool?
    /// Whether the model serves chat completions, judged from the entry's type
    /// and capability fields, or from its ID when those are absent.
    public let isChatModel: Bool
    public let metadata: JSON

    public init(id: String, name: String? = nil, ownedBy: String? = nil, contextWindow: Int? = nil, maxOutputTokens: Int? = nil, supportsTools: Bool? = nil, isChatModel: Bool = true, metadata: JSON = .null) {
        self.id = id
        self.name = name
        self.ownedBy = ownedBy
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
        self.supportsTools = supportsTools
        self.isChatModel = isChatModel
        self.metadata = metadata
    }

    public init(from decoder: Decoder) throws {
        let json = try JSON(from: decoder)
        guard let id = json["id"]?.stringValue else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Model entry without an id"))
        }
        self.init(
            id: id,
            name: Self.first(json, ["name", "display_name"])?.stringValue,
            ownedBy: Self.first(json, ["owned_by", "organization"])?.stringValue,
            contextWindow: Self.first(json, ["context_window", "context_length", "max_context_length", "max_model_len"])?.truncatedIntValue,
            maxOutputTokens: Self.first(json, ["max_tokens", "max_completion_tokens", "max_output_tokens"])?.truncatedIntValue,
            supportsTools: Self.toolSupport(json),
            isChatModel: Self.chatSupport(json, id: id),
            metadata: json
        )
    }

    private static func first(_ json: JSON, _ keys: [String]) -> JSON? {
        for key in keys { if let value = json[key], value != .null { return value } }
        return nil
    }

    private static func toolSupport(_ json: JSON) -> Bool? {
        if let tags = json["tags"]?.arrayValue?.compactMap(\.stringValue) {
            return tags.contains("tool-use")
        }
        if let calling = json["capabilities"]?["function_calling"]?.boolValue { return calling }
        if let supports = json["supports_tools"]?.boolValue { return supports }
        if let parameters = json["supported_parameters"]?.arrayValue?.compactMap(\.stringValue) {
            return parameters.contains("tools")
        }
        return nil
    }

    /// Model IDs that name a non-chat model when the catalog gives no type.
    static let nonChatIDMarkers = ["whisper", "tts", "embed", "rerank", "moderation", "transcribe", "dall-e", "flux", "stable-diffusion", "sdxl", "playai", "orpheus"]

    private static func chatSupport(_ json: JSON, id: String) -> Bool {
        if json["active"]?.boolValue == false { return false }
        // Fireworks marks some embedding models `supports_chat`.
        if json["kind"]?.stringValue?.uppercased().contains("EMBEDDING") == true { return false }
        if let chat = json["capabilities"]?["completion_chat"]?.boolValue { return chat }
        if let chat = json["supports_chat"]?.boolValue { return chat }
        if let type = json["type"]?.stringValue?.lowercased() {
            return ["chat", "language", "text", "llm"].contains(type)
        }
        let lowercased = id.lowercased()
        return !nonChatIDMarkers.contains { lowercased.contains($0) }
    }
}

// MARK: - Body adaptation helpers

/// Helpers for `OpenAICompatibleProvider.adaptChatBody(_:)`.
public enum OpenAICompatibleBody {
    /// Removes top-level parameters.
    public static func remove(_ keys: [String], from body: inout [String: JSON]) {
        for key in keys { body.removeValue(forKey: key) }
    }

    /// Moves a parameter to a new name unless the new name is already set.
    public static func rename(_ key: String, to newKey: String, in body: inout [String: JSON]) {
        guard let value = body.removeValue(forKey: key), body[newKey] == nil else { return }
        body[newKey] = value
    }

    /// Applies `transform` to each message object in `messages`.
    public static func updateMessages(in body: inout [String: JSON], _ transform: (inout [String: JSON]) -> Void) {
        guard case .array(let messages)? = body["messages"] else { return }
        body["messages"] = .array(messages.map { message in
            guard case .object(var object) = message else { return message }
            transform(&object)
            return .object(object)
        })
    }
}

// MARK: - Requests

extension OpenAI.ChatCompletionRequest {
    /// A chat request for an OpenAI-compatible provider's model. The model is
    /// tagged with the provider, so a `LangToolchain` routes the request there.
    public init<Provider>(model: OpenAICompatibleModel<Provider>, messages: [Message], temperature: Double? = nil, top_p: Double? = nil, n: Int? = nil, stream: Bool? = nil, stream_options: StreamOptions? = nil, stop: Stop? = nil, max_tokens: Int? = nil, max_completion_tokens: Int? = nil, presence_penalty: Double? = nil, frequency_penalty: Double? = nil, logit_bias: [String: Double]? = nil, logprobs: Bool? = nil, top_logprobs: Int? = nil, user: String? = nil, response_type: ResponseType? = nil, seed: Int? = nil, tools: [OpenAI.Tool]? = nil, tool_choice: ToolChoice? = nil, parallel_tool_calls: Bool? = nil, reasoning_effort: ReasoningEffort? = nil, choose: @escaping ([Response.Choice]) -> Int = { _ in 0 }, toolEventHandler: @escaping (LangToolsToolEvent) -> Void = { _ in }) {
        self.init(model: model.openAIModel, messages: messages, temperature: temperature, top_p: top_p, n: n, stream: stream, stream_options: stream_options, stop: stop, max_tokens: max_tokens, max_completion_tokens: max_completion_tokens, presence_penalty: presence_penalty, frequency_penalty: frequency_penalty, logit_bias: logit_bias, logprobs: logprobs, top_logprobs: top_logprobs, user: user, response_type: response_type, seed: seed, tools: tools, tool_choice: tool_choice, parallel_tool_calls: parallel_tool_calls, reasoning_effort: reasoning_effort, choose: choose, toolEventHandler: toolEventHandler)
    }
}
