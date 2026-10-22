//
//  OpenRouterAnthropicGateway.swift
//  LangTools
//
//  OpenRouter's Anthropic-compatible endpoint, for calling Claude models in
//  Anthropic's Messages format through OpenRouter.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LangTools
import Anthropic

public final class OpenRouterAnthropicGateway: AnthropicMessagesGateway {
    public typealias Model = Anthropic.Model
    public typealias ErrorResponse = AnthropicGatewayErrorResponse

    public static let anthropicProviderID = LangToolsProviderID(rawValue: "openrouter.anthropic")

    public let anthropic: Anthropic

    public init(
        baseURL: URL = OpenRouter.defaultBaseURL,
        apiKey: String,
        session: URLSession = URLSession(configuration: .default, delegate: nil, delegateQueue: nil),
        logger: LangToolsLogger? = nil
    ) {
        anthropic = Anthropic(configuration: .init(baseURL: baseURL, apiKey: apiKey, session: session, logger: logger))
    }
}
