//
//  Cohere.swift
//  LangTools
//
//  Cohere's Compatibility API, which accepts OpenAI chat requests for
//  Command models.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LangTools
import OpenAI

public final class Cohere: OpenAICompatibleProvider {
    public typealias Model = OpenAICompatibleModel<Cohere>
    public typealias ErrorResponse = OpenAICompatibleErrorResponse

    public static let providerID = LangToolsProviderID(rawValue: "cohere")
    public static let displayName = "Cohere"
    public static let defaultBaseURL = URL(string: "https://api.cohere.com/compatibility/v1/")!
    public static let apiKeyEnvironmentVariable = "COHERE_API_KEY"
    public static let supportsModelListing = false

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

    public init(
        baseURL: URL = Cohere.defaultBaseURL,
        apiKey: String,
        session: URLSession = URLSession(configuration: .default, delegate: nil, delegateQueue: nil),
        logger: LangToolsLogger? = nil
    ) {
        openAI = Self.makeClient(baseURL: baseURL, apiKey: apiKey, session: session, logger: logger)
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
