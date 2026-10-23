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
        let path = request is ChatRequest ? "v2/chat" : request is ListModelsRequest ? "v1/models?endpoint=chat&page_size=1000" : nil
        guard let path, let url = URL(string: path, relativeTo: nativeBaseURL)?.absoluteURL else { return try prepareCompatible(request: request) }
        return try prepareNative(request: request, url: url, headers: ["Authorization": "Bearer \(apiKey)"])
    }

    /// Lists chat models from Cohere's native catalog, without deprecated ones.
    public func listModels() async throws -> [OpenAICompatibleModelInfo] {
        try await perform(request: ListModelsRequest()).models.filter { $0.is_deprecated != true }.compactMap(\.info)
    }

    /// Builds a native v2 request; build an `OpenAI.ChatCompletionRequest` for the Compatibility API.
    public static func chatRequest(model: any RawRepresentable, messages: [any LangToolsMessage], tools: [any LangToolsTool]?, responseSchema: JSONSchema?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) throws -> any LangToolsChatRequest {
        guard let model = model as? Model else { throw LangToolsError.invalidArgument("Unsupported model \(model)") }
        var request = ChatRequest(model: model, messages: messages.map { Message($0) }, tools: tools?.map { OpenAI.Tool($0) }, toolEventHandler: toolEventHandler)
        request.responseSchema = responseSchema
        return request
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
    /// `GET v1/models?endpoint=chat` on the native API.
    public struct ListModelsRequest: LangToolsRequest, Encodable {
        public typealias Response = ListModelsResponse
        public typealias LangTool = Cohere
        public static var endpoint: String { "v1/models" }
        public static var httpMethod: HTTPMethod { .get }
        public init() {}
        public func encode(to encoder: Encoder) throws {}
    }

    public struct ListModelsResponse: Decodable {
        public let models: [ModelEntry]
    }

    public struct ModelEntry: Codable {
        /// `features` lists capabilities such as `"tools"` or `"json_schema"`.
        public let name: String?, endpoints: [String]?, features: [String]?, context_length: Double?, is_deprecated: Bool?

        /// The entry normalized like an OpenAI-compatible catalog entry; nil without a name.
        public var info: OpenAICompatibleModelInfo? {
            name.map { OpenAICompatibleModelInfo(id: $0, ownedBy: "cohere", contextWindow: context_length.map { Int($0) }, supportsTools: features.map { $0.contains("tools") || $0.contains("strict_tools") }, isChatModel: endpoints?.contains("chat") ?? true) }
        }
    }
}
