//
//  OpenAICompatibleProvider.swift
//  OpenAICompatible
//
//  Shared plumbing for providers that serve OpenAI's Chat Completions or
//  Responses format at their own base URL. A provider supplies its identity
//  and an `OpenAI` client; routing, preparation, headers, errors, and model
//  listing come from here.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LangTools
@_exported import OpenAI

/// A provider whose chat endpoint is wire-compatible with OpenAI's. Its requests'
/// models carry its tag (`OpenAICompatibleModel.openAIModel`), so providers serving
/// the same model names share one `LangToolchain`. A provider with request types of
/// its own adds validators to `compatibleRequestValidators` and routes the rest of
/// `prepare` through `prepareCompatible(request:)`.
public protocol OpenAICompatibleProvider: LangTools {
    static var providerID: LangToolsProviderID { get }
    /// A human-readable name, such as `"Groq"`.
    static var displayName: String { get }
    static var defaultBaseURL: URL { get }
    /// Such as `"GROQ_API_KEY"`.
    static var apiKeyEnvironmentVariable: String { get }
    /// The OpenAI formats served; the default is `.chatCompletions`.
    static var compatibleFormats: OpenAICompatibleFormats { get }
    /// Whether the provider serves `GET /models` at its base URL.
    static var supportsModelListing: Bool { get }
    /// Models to offer before, or instead of, a catalog fetch.
    static var knownModels: [OpenAICompatibleModel<Self>] { get }
    var openAI: OpenAI { get }
    /// Sent on every request; invalid or reserved names (`OpenAICompatibleHeaders`) make `prepare` throw.
    var additionalHeaders: [String: String] { get }
    /// Adjusts an encoded body for the provider's dialect; see `OpenAICompatibleBody`.
    static func adaptChatBody(_ body: inout [String: JSON])
    static func adaptResponsesBody(_ body: inout [String: JSON])
    /// The default reads `GET /models`; a provider with its own catalog API overrides it.
    func listModels() async throws -> [OpenAICompatibleModelInfo]
}

public struct OpenAICompatibleFormats: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let chatCompletions = OpenAICompatibleFormats(rawValue: 1), responses = OpenAICompatibleFormats(rawValue: 2)
}

extension OpenAICompatibleProvider {
    public static var compatibleFormats: OpenAICompatibleFormats { .chatCompletions }
    public static var supportsModelListing: Bool { true }
    public static var knownModels: [OpenAICompatibleModel<Self>] { [] }
    public static func adaptChatBody(_ body: inout [String: JSON]) {}
    public static func adaptResponsesBody(_ body: inout [String: JSON]) {}
    public var additionalHeaders: [String: String] { [:] }

    public var session: URLSession { openAI.session }
    public var logger: LangToolsLogger? { openAI.logger }

    /// Claims tagged requests in `compatibleFormats` and the catalog request.
    public static var compatibleRequestValidators: [(any LangToolsRequest) -> Bool] {
        var validators: [(any LangToolsRequest) -> Bool] = [{ $0 is OpenAICompatibleListModelsRequest<Self> }]
        if compatibleFormats.contains(.chatCompletions) {
            validators.append { ($0 as? OpenAI.ChatCompletionRequest)?.model.belongs(to: providerID) ?? false }
        }
        if compatibleFormats.contains(.responses) {
            validators.append { ($0 as? OpenAI.ResponsesRequest)?.model.belongs(to: providerID) ?? false }
        }
        return validators
    }

    public static var requestValidators: [(any LangToolsRequest) -> Bool] { compatibleRequestValidators }

    /// The OpenAI client's request with `additionalHeaders` and the adapted body.
    public func prepareCompatible(request: some LangToolsRequest) throws -> URLRequest {
        var urlRequest = try openAI.prepare(request: request)
        try OpenAICompatibleHeaders.apply(additionalHeaders, to: &urlRequest)
        let adapt: ((inout [String: JSON]) -> Void)? = request is OpenAI.ChatCompletionRequest ? Self.adaptChatBody : request is OpenAI.ResponsesRequest ? Self.adaptResponsesBody : nil
        if let adapt, let data = urlRequest.httpBody,
           case .object(var body) = try JSONDecoder().decode(JSON.self, from: data) {
            let original = body
            adapt(&body)
            if body != original { urlRequest.httpBody = try JSONEncoder().encode(JSON.object(body)) }
        }
        return urlRequest
    }

    public func prepare(request: some LangToolsRequest) throws -> URLRequest {
        try prepareCompatible(request: request)
    }

    /// A request to the provider's own API: `headers`, `additionalHeaders`, and a JSON body unless a GET.
    public func prepareNative(request: some LangToolsRequest, url: URL, headers: [String: String]) throws -> URLRequest {
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = type(of: request).httpMethod.rawValue
        headers.forEach { urlRequest.setValue($1, forHTTPHeaderField: $0) }
        try OpenAICompatibleHeaders.apply(additionalHeaders, to: &urlRequest)
        guard type(of: request).httpMethod != .get else { return urlRequest }
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(request)
        return urlRequest
    }

    /// A chat completion request for one of this provider's models, tagged to route here.
    public static func compatibleChatRequest(model: OpenAICompatibleModel<Self>, messages: [any LangToolsMessage], tools: [any LangToolsTool]?, responseSchema: JSONSchema?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) throws -> OpenAI.ChatCompletionRequest {
        guard let request = try OpenAI.chatRequest(model: model.openAIModel, messages: messages, tools: tools, responseSchema: responseSchema, toolEventHandler: toolEventHandler) as? OpenAI.ChatCompletionRequest else {
            throw LangToolsError.invalidArgument("Unsupported model \(model)")
        }
        return request
    }

    /// A chat completion request, or a Responses request for a Responses-only provider.
    public static func chatRequest(model: any RawRepresentable, messages: [any LangToolsMessage], tools: [any LangToolsTool]?, responseSchema: JSONSchema?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) throws -> any LangToolsChatRequest {
        guard let model = model as? OpenAICompatibleModel<Self> else { throw LangToolsError.invalidArgument("Unsupported model \(model)") }
        if !compatibleFormats.contains(.chatCompletions) {
            return try OpenAI.responsesRequest(model: model.openAIModel, messages: messages, tools: tools, responseSchema: responseSchema, toolEventHandler: toolEventHandler)
        }
        return try compatibleChatRequest(model: model, messages: messages, tools: tools, responseSchema: responseSchema, toolEventHandler: toolEventHandler)
    }

    /// `GET /models`, skipping entries that fail to decode; throws without a catalog endpoint.
    public func listModels() async throws -> [OpenAICompatibleModelInfo] {
        guard Self.supportsModelListing else { throw LangToolsError.invalidArgument("\(Self.displayName) does not list models; use knownModels") }
        return try await perform(request: OpenAICompatibleListModelsRequest<Self>()).data
    }

    /// SSE `data:` lines without the `[DONE]` sentinel; unlike the LangTools default,
    /// a chunk whose text contains "[DONE]" still decodes.
    public static func decodeStream<T: Decodable>(_ buffer: String) throws -> T? {
        guard buffer.hasPrefix("data:") else { return nil }
        let payload = buffer.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
        guard payload != "[DONE]", let data = payload.data(using: .utf8) else { return nil }
        return try decodeResponse(data: data)
    }

    public static func makeClient(baseURL: URL, apiKey: String, session: URLSession, logger: LangToolsLogger?) -> OpenAI {
        OpenAI(configuration: .init(baseURL: baseURL, apiKey: apiKey, session: session, logger: logger))
    }
}

// MARK: - Headers

/// Validation for `OpenAICompatibleProvider.additionalHeaders`.
public enum OpenAICompatibleHeaders {
    /// Lowercased names that may not be set: credentials, framing, and hop-by-hop headers.
    public static let reservedNames: Set<String> = [
        "authorization", "proxy-authorization", "cookie", "x-api-key",
        "host", "content-type", "content-length", "transfer-encoding",
        "connection", "te", "trailer", "upgrade",
    ]

    /// Whether `name` is an RFC 9110 token: letters, digits, and ``!#$%&'*+-.^_`|~``.
    public static func isToken(_ name: String) -> Bool {
        !name.isEmpty && name.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "!#$%&'*+-.^_`|~".unicodeScalars.contains(scalar))
        }
    }

    /// Sets `headers`, rejecting invalid or reserved names and values with line breaks.
    public static func apply(_ headers: [String: String], to request: inout URLRequest) throws {
        for (name, value) in headers {
            guard isToken(name) else { throw LangToolsError.invalidArgument("additionalHeaders name '\(name)' is not a valid header name") }
            guard !reservedNames.contains(name.lowercased()) else { throw LangToolsError.invalidArgument("additionalHeaders cannot set '\(name)'") }
            // Scalars, not Characters: "\r\n" is a single Character in Swift.
            guard !value.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" }) else { throw LangToolsError.invalidArgument("additionalHeaders value for '\(name)' contains a line break") }
            request.setValue(value, forHTTPHeaderField: name)
        }
    }
}

// MARK: - Model

/// A model ID for an OpenAI-compatible provider; catalogs change often, so IDs are not an enum.
public struct OpenAICompatibleModel<Provider: OpenAICompatibleProvider>: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    /// Returns nil for an empty ID or one with leading or trailing whitespace.
    public init?(rawValue: String) {
        guard !rawValue.isEmpty, rawValue == rawValue.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) { rawValue = value }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let model = Self(rawValue: try container.decode(String.self)) else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid \(Provider.displayName) model ID") }
        self = model
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
    /// The tagged model used on the wire and for routing.
    public var openAIModel: OpenAIModel { OpenAIModel(customModelID: rawValue, providerID: Provider.providerID) }
}

// MARK: - Errors

/// An error body: `{"error": {"message", ...}}`, `{"error": "..."}`, a top-level
/// `{"message", ...}`, or `{"detail": "..." | [{"msg": ...}]}`. Numeric codes are kept as text.
public struct OpenAICompatibleErrorResponse: Error, Codable, LocalizedError, Equatable {
    public let message: String, type: String?, code: String?, param: String?
    public var errorDescription: String? { message }

    public init(message: String, type: String? = nil, code: String? = nil, param: String? = nil) {
        (self.message, self.type, self.code, self.param) = (message, type, code, param)
    }

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
    public func encode(to encoder: Encoder) throws {}
}

/// A catalog as `{"data": [...]}` or a bare array, skipping entries that fail to decode.
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

/// One catalog entry normalized across providers; the raw entry is in `metadata`.
/// `supportsTools` is nil when the catalog does not say; `isChatModel` falls back to the ID.
public struct OpenAICompatibleModelInfo: Decodable, Identifiable, Equatable {
    public let id: String, name: String?, ownedBy: String?, contextWindow: Int?, maxOutputTokens: Int?, supportsTools: Bool?, isChatModel: Bool, metadata: JSON

    public init(id: String, name: String? = nil, ownedBy: String? = nil, contextWindow: Int? = nil, maxOutputTokens: Int? = nil, supportsTools: Bool? = nil, isChatModel: Bool = true, metadata: JSON = .null) {
        (self.id, self.name, self.ownedBy, self.contextWindow) = (id, name, ownedBy, contextWindow)
        (self.maxOutputTokens, self.supportsTools, self.isChatModel, self.metadata) = (maxOutputTokens, supportsTools, isChatModel, metadata)
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
        if let tags = json["tags"]?.arrayValue?.compactMap(\.stringValue) { return tags.contains("tool-use") }
        if let supports = json["capabilities"]?["function_calling"]?.boolValue ?? json["supports_tools"]?.boolValue { return supports }
        return json["supported_parameters"]?.arrayValue?.compactMap(\.stringValue).contains("tools")
    }

    /// Model IDs that name a non-chat model when the catalog gives no type.
    static let nonChatIDMarkers = ["whisper", "tts", "embed", "rerank", "moderation", "transcribe", "dall-e", "flux", "stable-diffusion", "sdxl", "playai", "orpheus"]

    private static func chatSupport(_ json: JSON, id: String) -> Bool {
        // Fireworks marks some embedding models `supports_chat`.
        if json["active"]?.boolValue == false || json["kind"]?.stringValue?.uppercased().contains("EMBEDDING") == true { return false }
        if let chat = json["capabilities"]?["completion_chat"]?.boolValue ?? json["supports_chat"]?.boolValue { return chat }
        if let type = json["type"]?.stringValue?.lowercased() { return ["chat", "language", "text", "llm"].contains(type) }
        return !nonChatIDMarkers.contains { id.lowercased().contains($0) }
    }
}

// MARK: - Body adaptation helpers

/// Helpers for `OpenAICompatibleProvider.adaptChatBody(_:)`.
public enum OpenAICompatibleBody {
    public static func remove(_ keys: [String], from body: inout [String: JSON]) { keys.forEach { body.removeValue(forKey: $0) } }

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

// Requests for a provider's model, tagged so a `LangToolchain` routes them there.

extension OpenAI.ChatCompletionRequest {
    public init<Provider>(model: OpenAICompatibleModel<Provider>, messages: [Message], temperature: Double? = nil, top_p: Double? = nil, n: Int? = nil, stream: Bool? = nil, stream_options: StreamOptions? = nil, stop: Stop? = nil, max_tokens: Int? = nil, max_completion_tokens: Int? = nil, presence_penalty: Double? = nil, frequency_penalty: Double? = nil, logit_bias: [String: Double]? = nil, logprobs: Bool? = nil, top_logprobs: Int? = nil, user: String? = nil, response_type: ResponseType? = nil, seed: Int? = nil, tools: [OpenAI.Tool]? = nil, tool_choice: ToolChoice? = nil, parallel_tool_calls: Bool? = nil, reasoning_effort: ReasoningEffort? = nil, choose: @escaping ([Response.Choice]) -> Int = { _ in 0 }, toolEventHandler: @escaping (LangToolsToolEvent) -> Void = { _ in }) {
        self.init(model: model.openAIModel, messages: messages, temperature: temperature, top_p: top_p, n: n, stream: stream, stream_options: stream_options, stop: stop, max_tokens: max_tokens, max_completion_tokens: max_completion_tokens, presence_penalty: presence_penalty, frequency_penalty: frequency_penalty, logit_bias: logit_bias, logprobs: logprobs, top_logprobs: top_logprobs, user: user, response_type: response_type, seed: seed, tools: tools, tool_choice: tool_choice, parallel_tool_calls: parallel_tool_calls, reasoning_effort: reasoning_effort, choose: choose, toolEventHandler: toolEventHandler)
    }
}

extension OpenAI.ResponsesRequest {
    public init<Provider>(model: OpenAICompatibleModel<Provider>, messages: [Message], stream: Bool? = nil, instructions: String? = nil, previous_response_id: String? = nil, max_output_tokens: Int? = nil, temperature: Double? = nil, top_p: Double? = nil, tools: [OpenAI.Tool]? = nil, tool_choice: ToolChoice? = nil, parallel_tool_calls: Bool? = nil, text: TextConfig? = nil, metadata: [String: String]? = nil, toolEventHandler: @escaping (LangToolsToolEvent) -> Void = { _ in }) {
        self.init(model: model.openAIModel, messages: messages, stream: stream, instructions: instructions, previous_response_id: previous_response_id, max_output_tokens: max_output_tokens, temperature: temperature, top_p: top_p, tools: tools, tool_choice: tool_choice, parallel_tool_calls: parallel_tool_calls, text: text, metadata: metadata, toolEventHandler: toolEventHandler)
    }
}
