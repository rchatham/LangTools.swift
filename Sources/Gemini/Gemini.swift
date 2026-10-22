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
import OpenAICompatible

/// Serves Gemini's OpenAI-compatible API and its native `generateContent` API
/// (`Gemini.GenerateContentRequest`, see Gemini+GenerateContent.swift).
///
/// OpenAI-format requests for `Gemini.Model` cases route here untagged, as
/// before; any other Gemini model ID can be sent as an
/// `OpenAICompatibleModel<Gemini>`, which is tagged for Gemini.
public final class Gemini: OpenAICompatibleProvider {
    public typealias Model = GeminiModel
    public typealias ErrorResponse = GeminiErrorResponse

    public static let providerID = LangToolsProviderID(rawValue: "gemini")
    public static let displayName = "Gemini"
    public static let defaultBaseURL = URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/")!
    public static let apiKeyEnvironmentVariable = "GEMINI_API_KEY"
    /// The root of the native API (`models/{model}:generateContent`, `models`).
    public static let nativeBaseURL = URL(string: "https://generativelanguage.googleapis.com/v1beta/")!

    /// The models of `Gemini.Model`, as tagged compatible models.
    public static var knownModels: [OpenAICompatibleModel<Gemini>] {
        Model.allCases.compactMap { OpenAICompatibleModel(rawValue: $0.rawValue) }
    }

    /// Claims untagged requests for `Gemini.Model` cases, as before, requests
    /// tagged for Gemini, and native requests.
    public static var requestValidators: [(any LangToolsRequest) -> Bool] {
        [
            { ($0 as? OpenAI.ChatCompletionRequest).flatMap { $0.model.providerID == nil && OpenAIModel.geminiModels.contains($0.model) } ?? false },
            { $0 is GenerateContentRequest },
            { $0 is ListModelsRequest },
        ] + compatibleRequestValidators
    }

    public let openAI: OpenAI
    private let nativeBaseURL: URL
    private let apiKey: String

    public init(baseURL: URL = Gemini.defaultBaseURL, nativeBaseURL: URL = Gemini.nativeBaseURL, apiKey: String, session: URLSession = URLSession(configuration: .default, delegate: nil, delegateQueue: nil), logger: LangToolsLogger? = nil) {
        self.nativeBaseURL = nativeBaseURL
        self.apiKey = apiKey
        openAI = OpenAI(configuration: .init(baseURL: baseURL, apiKey: apiKey, session: session, logger: logger))
    }

    public func prepare(request: some LangToolsRequest) throws -> URLRequest {
        let url: URL
        if let request = request as? GenerateContentRequest {
            let method = request.stream == true ? "streamGenerateContent" : "generateContent"
            url = URL(string: "\(request.modelPath):\(method)\(request.stream == true ? "?alt=sse" : "")", relativeTo: nativeBaseURL)?.absoluteURL ?? nativeBaseURL
        } else if let request = request as? ListModelsRequest {
            var components = URLComponents(url: nativeBaseURL.appendingPathComponent("models"), resolvingAgainstBaseURL: false)
            components?.queryItems = request.queryItems
            url = components?.url ?? nativeBaseURL
        } else {
            return try prepareCompatible(request: request)
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = type(of: request).httpMethod.rawValue
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        try OpenAICompatibleHeaders.apply(additionalHeaders, to: &urlRequest)
        guard type(of: request).httpMethod != .get else { return urlRequest }
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do { urlRequest.httpBody = try JSONEncoder().encode(request) }
        catch { throw LangToolsError.invalidArgument("Failed to encode request: \(error)") }
        return urlRequest
    }

    /// Lists models that support `generateContent` from the native catalog,
    /// with their token limits.
    public func listModels() async throws -> [OpenAICompatibleModelInfo] {
        var models: [OpenAICompatibleModelInfo] = []
        var pageToken: String?
        // The catalog is small; the page cap only guards against a looping token.
        for _ in 0..<10 {
            let page = try await perform(request: ListModelsRequest(pageToken: pageToken))
            models += page.models.map(\.info)
            guard let next = page.nextPageToken, !next.isEmpty else { break }
            pageToken = next
        }
        return models
    }

    public static func chatRequest(model: any RawRepresentable, messages: [any LangToolsMessage], tools: [any LangToolsTool]?, responseSchema: JSONSchema?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) throws -> any LangToolsChatRequest {
        if let model = model as? OpenAICompatibleModel<Gemini> {
            return try compatibleChatRequest(model: model, messages: messages, tools: tools, responseSchema: responseSchema, toolEventHandler: toolEventHandler)
        }
        guard let model = model as? Model else { throw LangToolsError.invalidArgument("Unsupported model \(model)") }
        return try OpenAI.chatRequest(model: model.openAIModel, messages: messages, tools: tools, responseSchema: responseSchema, toolEventHandler: toolEventHandler)
    }
}

/// Errors from both APIs: the OpenAI-compatible endpoint's
/// `{"error": {"message", "type", ...}}` and the native API's
/// `{"error": {"code": 400, "message", "status"}}`. For a native error, `type`
/// is its `status` and `code` its numeric code as text.
public struct GeminiErrorResponse: Error, Codable {
    public let type: String?
    public let error: APIError

    public struct APIError: Error, Codable {
        public let message: String
        public let type: String
        public let param: String?
        public let code: String?

        private enum CodingKeys: String, CodingKey { case message, type, param, code, status }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            message = try container.decode(String.self, forKey: .message)
            type = try container.decodeIfPresent(String.self, forKey: .type)
                ?? container.decodeIfPresent(String.self, forKey: .status) ?? "error"
            param = try container.decodeIfPresent(String.self, forKey: .param)
            if let code = try? container.decodeIfPresent(String.self, forKey: .code) {
                self.code = code
            } else {
                self.code = (try? container.decodeIfPresent(Int.self, forKey: .code)).map(String.init)
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(message, forKey: .message)
            try container.encode(type, forKey: .type)
            try container.encodeIfPresent(param, forKey: .param)
            try container.encodeIfPresent(code, forKey: .code)
        }
    }
}

// MARK: - Native model catalog

extension Gemini {
    /// `GET models` on the native API.
    public struct ListModelsRequest: LangToolsRequest, Encodable {
        public typealias Response = ListModelsResponse
        public typealias LangTool = Gemini
        public static var endpoint: String { "models" }
        public static var httpMethod: HTTPMethod { .get }

        public var pageSize: Int
        public var pageToken: String?

        public init(pageSize: Int = 1000, pageToken: String? = nil) {
            self.pageSize = pageSize
            self.pageToken = pageToken
        }

        /// GET requests carry no body.
        public func encode(to encoder: Encoder) throws {}

        var queryItems: [URLQueryItem] {
            var items = [URLQueryItem(name: "pageSize", value: String(pageSize))]
            if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            return items
        }
    }

    public struct ListModelsResponse: Decodable {
        public let models: [ModelEntry]
        public let nextPageToken: String?

        private enum CodingKeys: String, CodingKey { case models, nextPageToken }
        private struct Lossy: Decodable {
            let entry: ModelEntry?
            init(from decoder: Decoder) throws { entry = try? ModelEntry(from: decoder) }
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // Entries that fail to decode are skipped.
            models = (try container.decodeIfPresent([Lossy].self, forKey: .models) ?? []).compactMap(\.entry)
            nextPageToken = try container.decodeIfPresent(String.self, forKey: .nextPageToken)
        }
    }

    public struct ModelEntry: Codable {
        /// The resource name, such as `models/gemini-3-flash`.
        public let name: String
        public let displayName: String?
        public let inputTokenLimit: Int?
        public let outputTokenLimit: Int?
        public let supportedGenerationMethods: [String]?

        /// The ID used in requests, without the `models/` prefix.
        public var id: String { name.hasPrefix("models/") ? String(name.dropFirst("models/".count)) : name }

        /// The entry normalized like an OpenAI-compatible catalog entry.
        public var info: OpenAICompatibleModelInfo {
            OpenAICompatibleModelInfo(
                id: id,
                name: displayName,
                ownedBy: "google",
                contextWindow: inputTokenLimit,
                maxOutputTokens: outputTokenLimit,
                isChatModel: supportedGenerationMethods?.contains("generateContent") ?? false
            )
        }
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
    public init(model: Gemini.Model, messages: [Message], temperature: Double? = nil, top_p: Double? = nil, n: Int? = nil, stream: Bool? = nil, stream_options: StreamOptions? = nil, stop: Stop? = nil, max_tokens: Int? = nil, presence_penalty: Double? = nil, frequency_penalty: Double? = nil, logit_bias: [String: Double]? = nil, logprobs: Bool? = nil, top_logprobs: Int? = nil, user: String? = nil, response_type: ResponseType? = nil, seed: Int? = nil, tools: [Tool]? = nil, tool_choice: ToolChoice? = nil, parallel_tool_calls: Bool? = nil, choose: @escaping ([Response.Choice]) -> Int = {_ in 0}, toolEventHandler: @escaping (LangToolsToolEvent) -> Void = {_ in}) {
        self.init(model: model.openAIModel, messages: messages, temperature: temperature, top_p: top_p, n: n, stream: stream, stream_options: stream_options, stop: stop, max_tokens: max_tokens, presence_penalty: presence_penalty, frequency_penalty: frequency_penalty, logit_bias: logit_bias, logprobs: logprobs, top_logprobs: top_logprobs, user: user, response_type: response_type, seed: seed, tools: tools, tool_choice: tool_choice, parallel_tool_calls: parallel_tool_calls, choose: choose, toolEventHandler: toolEventHandler)
    }
}
