//
//  Cohere.swift
//  LangTools
//
//  Cohere serves two formats: its Compatibility API, which accepts OpenAI
//  chat requests for Command models, and its native v2 Chat API
//  (`Cohere.ChatRequest`, see Cohere+Chat.swift). Models are listed from the
//  native catalog.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LangTools
import OpenAI
import OpenAICompatible

public final class Cohere: OpenAICompatibleProvider {
    public typealias Model = OpenAICompatibleModel<Cohere>
    public typealias ErrorResponse = OpenAICompatibleErrorResponse

    public static let providerID = LangToolsProviderID(rawValue: "cohere")
    public static let displayName = "Cohere"
    public static let defaultBaseURL = URL(string: "https://api.cohere.com/compatibility/v1/")!
    public static let apiKeyEnvironmentVariable = "COHERE_API_KEY"
    /// The root of Cohere's native API (`v2/chat`, `v1/models`).
    public static let nativeBaseURL = URL(string: "https://api.cohere.com/")!

    /// Suggested models. The provider's catalog changes often.
    public static var knownModels: [Model] {
        [
            "command-a-03-2025",
            "command-a-reasoning-08-2025",
            "command-a-vision-07-2025",
            "command-r-plus-08-2024",
            "command-r-08-2024",
            "command-r7b-12-2024"
        ]
    }

    public let openAI: OpenAI
    private let nativeBaseURL: URL
    private let apiKey: String

    public init(
        baseURL: URL = Cohere.defaultBaseURL,
        nativeBaseURL: URL = Cohere.nativeBaseURL,
        apiKey: String,
        session: URLSession = URLSession(configuration: .default, delegate: nil, delegateQueue: nil),
        logger: LangToolsLogger? = nil
    ) {
        self.nativeBaseURL = nativeBaseURL
        self.apiKey = apiKey
        openAI = Self.makeClient(baseURL: baseURL, apiKey: apiKey, session: session, logger: logger)
    }

    public static var requestValidators: [(any LangToolsRequest) -> Bool] {
        compatibleRequestValidators + [{ $0 is ChatRequest }, { $0 is ListModelsRequest }]
    }

    public func prepare(request: some LangToolsRequest) throws -> URLRequest {
        guard request is ChatRequest || request is ListModelsRequest else { return try prepareCompatible(request: request) }
        var url = nativeBaseURL.appendingPathComponent(request.endpoint)
        if let list = request as? ListModelsRequest, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = list.queryItems
            url = components.url ?? url
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = type(of: request).httpMethod.rawValue
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        try OpenAICompatibleHeaders.apply(additionalHeaders, to: &urlRequest)
        guard type(of: request).httpMethod != .get else { return urlRequest }
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do { urlRequest.httpBody = try JSONEncoder().encode(request) }
        catch { throw LangToolsError.invalidArgument("Failed to encode request: \(error)") }
        return urlRequest
    }

    /// Lists chat models from Cohere's native catalog, without deprecated ones.
    public func listModels() async throws -> [OpenAICompatibleModelInfo] {
        try await perform(request: ListModelsRequest()).models.filter { !($0.is_deprecated ?? false) }.map(\.info)
    }

    /// Cohere rejects OpenAI options it does not implement, and takes the
    /// JSON schema itself under `json_schema` rather than OpenAI's wrapper.
    public static func adaptChatBody(_ body: inout [String: JSON]) {
        OpenAICompatibleBody.remove(["stream_options", "store", "metadata", "logit_bias", "logprobs", "top_logprobs", "n", "modalities", "prediction", "audio", "service_tier", "parallel_tool_calls"], from: &body)
        if body["response_format"]?["type"] == .string("json_schema"),
           let schema = body["response_format"]?["json_schema"]?["schema"] {
            body["response_format"] = .object(["type": .string("json_schema"), "json_schema": schema])
        }
    }
}

// MARK: - Model catalog

extension Cohere {
    /// `GET v1/models` on the native API.
    public struct ListModelsRequest: LangToolsRequest, Encodable {
        public typealias Response = ListModelsResponse
        public typealias LangTool = Cohere
        public static var endpoint: String { "v1/models" }
        public static var httpMethod: HTTPMethod { .get }

        /// Only models served on this endpoint, such as `"chat"` or `"embed"`.
        public var endpointFilter: String?
        public var pageSize: Int

        public init(endpoint: String? = "chat", pageSize: Int = 1000) {
            endpointFilter = endpoint
            self.pageSize = pageSize
        }

        /// GET requests carry no body.
        public func encode(to encoder: Encoder) throws {}

        var queryItems: [URLQueryItem] {
            var items = [URLQueryItem(name: "page_size", value: String(pageSize))]
            if let endpointFilter { items.append(URLQueryItem(name: "endpoint", value: endpointFilter)) }
            return items
        }
    }

    public struct ListModelsResponse: Decodable {
        public let models: [ModelEntry]
        public let next_page_token: String?

        private enum CodingKeys: String, CodingKey { case models, next_page_token }
        private struct Lossy: Decodable {
            let entry: ModelEntry?
            init(from decoder: Decoder) throws { entry = try? ModelEntry(from: decoder) }
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // Entries that fail to decode are skipped.
            models = try container.decode([Lossy].self, forKey: .models).compactMap(\.entry)
            next_page_token = try container.decodeIfPresent(String.self, forKey: .next_page_token)
        }
    }

    public struct ModelEntry: Codable {
        public let name: String
        public let endpoints: [String]?
        /// Capabilities such as `"tools"`, `"json_schema"`, or `"vision"`.
        public let features: [String]?
        public let context_length: Double?
        public let is_deprecated: Bool?

        /// The entry normalized like an OpenAI-compatible catalog entry.
        public var info: OpenAICompatibleModelInfo {
            OpenAICompatibleModelInfo(
                id: name,
                ownedBy: "cohere",
                contextWindow: context_length.map { Int($0) },
                supportsTools: features.map { $0.contains("tools") || $0.contains("strict_tools") },
                isChatModel: endpoints?.contains("chat") ?? true
            )
        }
    }
}
