//
//  Cerebras.swift
//  LangTools
//
//  Cerebras Inference's OpenAI-compatible API.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LangTools
import OpenAI

public final class Cerebras: OpenAICompatibleProvider {
    public typealias Model = OpenAICompatibleModel<Cerebras>
    public typealias ErrorResponse = OpenAICompatibleErrorResponse

    public static let providerID = LangToolsProviderID(rawValue: "cerebras")
    public static let displayName = "Cerebras"
    public static let defaultBaseURL = URL(string: "https://api.cerebras.ai/v1/")!
    public static let apiKeyEnvironmentVariable = "CEREBRAS_API_KEY"

    /// Suggested models. The provider's catalog changes often; `listModels()` is authoritative.
    public static var knownModels: [Model] {
        [
            "gpt-oss-120b",
            "gemma-4-31b"
        ]
    }

    public let openAI: OpenAI

    public init(
        baseURL: URL = Cerebras.defaultBaseURL,
        apiKey: String,
        session: URLSession = URLSession(configuration: .default, delegate: nil, delegateQueue: nil),
        logger: LangToolsLogger? = nil
    ) {
        openAI = Self.makeClient(baseURL: baseURL, apiKey: apiKey, session: session, logger: logger)
    }
}
