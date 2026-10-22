//
//  VercelAnthropicGateway.swift
//  LangTools
//
//  Vercel AI Gateway's Anthropic-compatible endpoint, for calling Claude models
//  in Anthropic's Messages format (with Anthropic features such as extended
//  thinking and prompt caching) through the gateway.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LangTools
import Anthropic

public final class VercelAnthropicGateway: AnthropicMessagesGateway {
    public typealias Model = Anthropic.Model
    public typealias ErrorResponse = AnthropicGatewayErrorResponse

    public static let anthropicProviderID = LangToolsProviderID(rawValue: "vercel.anthropic")
    public static let defaultBaseURL = URL(string: "https://ai-gateway.vercel.sh/v1/")!

    public let anthropic: Anthropic

    /// - Parameter authentication: `.apiKeyHeader` for an AI Gateway API key;
    ///   `.bearer` for a key or a Vercel OIDC token.
    public init(
        baseURL: URL = VercelAnthropicGateway.defaultBaseURL,
        apiKey: String,
        authentication: Anthropic.AnthropicConfiguration.Authentication = .apiKeyHeader,
        session: URLSession = URLSession(configuration: .default, delegate: nil, delegateQueue: nil),
        logger: LangToolsLogger? = nil
    ) {
        anthropic = Anthropic(configuration: .init(baseURL: baseURL, apiKey: apiKey, session: session, logger: logger, authentication: authentication))
    }
}
