//
//  VercelAIGateway.swift
//  LangTools
//
//  Vercel AI Gateway routes `creator/model` IDs, such as `anthropic/claude-sonnet-4.5`,
//  to many vendors through one OpenAI-compatible endpoint.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LangTools
import OpenAI

public final class VercelAIGateway: OpenAICompatibleProvider {
    public typealias Model = OpenAICompatibleModel<VercelAIGateway>
    public typealias ErrorResponse = OpenAICompatibleErrorResponse

    public static let providerID = LangToolsProviderID(rawValue: "vercel")
    public static let displayName = "Vercel AI Gateway"
    public static let defaultBaseURL = URL(string: "https://ai-gateway.vercel.sh/v1/")!
    public static let apiKeyEnvironmentVariable = "AI_GATEWAY_API_KEY"

    /// Suggested models. The provider's catalog changes often; `listModels()` is authoritative.
    public static var knownModels: [Model] {
        [
            "openai/gpt-5",
            "openai/gpt-5-mini",
            "anthropic/claude-sonnet-4.5",
            "anthropic/claude-haiku-4.5",
            "google/gemini-2.5-pro",
            "google/gemini-2.5-flash",
            "deepseek/deepseek-v4-flash",
            "meta/llama-3.3-70b"
        ]
    }

    public let openAI: OpenAI

    public init(
        baseURL: URL = VercelAIGateway.defaultBaseURL,
        apiKey: String,
        session: URLSession = URLSession(configuration: .default, delegate: nil, delegateQueue: nil),
        logger: LangToolsLogger? = nil
    ) {
        openAI = Self.makeClient(baseURL: baseURL, apiKey: apiKey, session: session, logger: logger)
    }

    /// The gateway documents `max_tokens` but not `max_completion_tokens`.
    public static func adaptChatBody(_ body: inout [String: JSON]) {
        OpenAICompatibleBody.rename("max_completion_tokens", to: "max_tokens", in: &body)
    }
}
