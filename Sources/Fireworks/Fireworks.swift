//
//  Fireworks.swift
//  LangTools
//
//  Fireworks AI's OpenAI-compatible inference API.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LangTools
import OpenAI
import OpenAICompatible

public final class Fireworks: OpenAICompatibleProvider {
    public typealias Model = OpenAICompatibleModel<Fireworks>
    public typealias ErrorResponse = OpenAICompatibleErrorResponse

    public static let providerID = LangToolsProviderID(rawValue: "fireworks")
    public static let displayName = "Fireworks AI"
    public static let defaultBaseURL = URL(string: "https://api.fireworks.ai/inference/v1/")!
    public static let apiKeyEnvironmentVariable = "FIREWORKS_API_KEY"

    /// Suggested models. The provider's catalog changes often; `listModels()` is authoritative.
    public static var knownModels: [Model] {
        [
            "accounts/fireworks/models/kimi-k2-instruct",
            "accounts/fireworks/models/deepseek-v3",
            "accounts/fireworks/models/llama-v3p3-70b-instruct",
            "accounts/fireworks/models/qwen2p5-coder-32b-instruct"
        ]
    }

    public let openAI: OpenAI

    public init(
        baseURL: URL = Fireworks.defaultBaseURL,
        apiKey: String,
        session: URLSession = URLSession(configuration: .default, delegate: nil, delegateQueue: nil),
        logger: LangToolsLogger? = nil
    ) {
        openAI = Self.makeClient(baseURL: baseURL, apiKey: apiKey, session: session, logger: logger)
    }
}
