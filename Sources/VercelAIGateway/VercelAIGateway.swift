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
import OpenAICompatible
import Anthropic
import AnthropicCompatible

/// Serves both the OpenAI format (`OpenAI.ChatCompletionRequest` with a
/// `VercelAIGateway.Model`) and Anthropic's Messages format
/// (`Anthropic.MessageRequest` routed with `routed(to: VercelAIGateway.providerID)`).
public final class VercelAIGateway: OpenAICompatibleProvider, AnthropicCompatibleProvider {
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
    public let anthropic: Anthropic

    /// - Parameter apiKey: An AI Gateway API key or a Vercel OIDC token. Both
    ///   formats send it as `Authorization: Bearer`.
    public init(
        baseURL: URL = VercelAIGateway.defaultBaseURL,
        apiKey: String,
        session: URLSession = URLSession(configuration: .default, delegate: nil, delegateQueue: nil),
        logger: LangToolsLogger? = nil
    ) {
        openAI = Self.makeClient(baseURL: baseURL, apiKey: apiKey, session: session, logger: logger)
        anthropic = Anthropic(baseURL: baseURL, apiKey: apiKey, session: session, logger: logger)
    }

    // The gateway accepts a key or an OIDC token as a bearer token on both formats.
    public var anthropicAuthentication: AnthropicCompatibleAuthentication { .bearer }

    // MARK: Serving both formats

    public var session: URLSession { openAI.session }
    public var logger: LangToolsLogger? { openAI.logger }

    public static var requestValidators: [(any LangToolsRequest) -> Bool] {
        compatibleRequestValidators + anthropicRequestValidators
    }

    public func prepare(request: some LangToolsRequest) throws -> URLRequest {
        request is Anthropic.MessageRequest ? try prepareAnthropicCompatible(request: request) : try prepareCompatible(request: request)
    }

    /// An Anthropic `Model` builds a Messages request; a gateway `Model` builds
    /// a chat completion request.
    public static func chatRequest(model: any RawRepresentable, messages: [any LangToolsMessage], tools: [any LangToolsTool]?, responseSchema: JSONSchema?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) throws -> any LangToolsChatRequest {
        if let model = model as? Anthropic.Model {
            return try anthropicChatRequest(model: model, messages: messages, tools: tools, responseSchema: responseSchema, toolEventHandler: toolEventHandler)
        }
        guard let model = model as? Model else { throw LangToolsError.invalidArgument("Unsupported model \(model)") }
        return try compatibleChatRequest(model: model, messages: messages, tools: tools, responseSchema: responseSchema, toolEventHandler: toolEventHandler)
    }

    /// The gateway documents `max_tokens` but not `max_completion_tokens`.
    public static func adaptChatBody(_ body: inout [String: JSON]) {
        OpenAICompatibleBody.rename("max_completion_tokens", to: "max_tokens", in: &body)
    }
}
