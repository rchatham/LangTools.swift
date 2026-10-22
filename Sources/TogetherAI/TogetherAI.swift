//
//  TogetherAI.swift
//  LangTools
//
//  Together AI's OpenAI-compatible API for open-weight models.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LangTools
import OpenAI

public final class TogetherAI: OpenAICompatibleProvider {
    public typealias Model = OpenAICompatibleModel<TogetherAI>
    public typealias ErrorResponse = OpenAICompatibleErrorResponse

    public static let providerID = LangToolsProviderID(rawValue: "together")
    public static let displayName = "Together AI"
    public static let defaultBaseURL = URL(string: "https://api.together.xyz/v1/")!
    public static let apiKeyEnvironmentVariable = "TOGETHER_API_KEY"

    /// Suggested models. The provider's catalog changes often; `listModels()` is authoritative.
    public static var knownModels: [Model] {
        [
            "meta-llama/Llama-3.3-70B-Instruct-Turbo",
            "deepseek-ai/DeepSeek-V3",
            "Qwen/Qwen2.5-72B-Instruct-Turbo",
            "Qwen/Qwen2.5-Coder-32B-Instruct"
        ]
    }

    public let openAI: OpenAI

    public init(
        baseURL: URL = TogetherAI.defaultBaseURL,
        apiKey: String,
        session: URLSession = URLSession(configuration: .default, delegate: nil, delegateQueue: nil),
        logger: LangToolsLogger? = nil
    ) {
        openAI = Self.makeClient(baseURL: baseURL, apiKey: apiKey, session: session, logger: logger)
    }

    /// Together takes `logprobs` as a count rather than a flag.
    public static func adaptChatBody(_ body: inout [String: JSON]) {
        guard case .bool(let enabled)? = body["logprobs"] else { return }
        let count = body.removeValue(forKey: "top_logprobs") ?? .number(1)
        body["logprobs"] = enabled ? count : nil
    }
}
