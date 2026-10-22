//
//  DeepSeek.swift
//  LangTools
//
//  DeepSeek's OpenAI-compatible API.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LangTools
import OpenAI
import OpenAICompatible

public final class DeepSeek: OpenAICompatibleProvider {
    public typealias Model = OpenAICompatibleModel<DeepSeek>
    public typealias ErrorResponse = OpenAICompatibleErrorResponse

    public static let providerID = LangToolsProviderID(rawValue: "deepseek")
    public static let displayName = "DeepSeek"
    public static let defaultBaseURL = URL(string: "https://api.deepseek.com/")!
    public static let apiKeyEnvironmentVariable = "DEEPSEEK_API_KEY"

    /// Suggested models. The provider's catalog changes often; `listModels()` is authoritative.
    public static var knownModels: [Model] {
        [
            "deepseek-v4-flash",
            "deepseek-v4-pro"
        ]
    }

    public let openAI: OpenAI

    public init(
        baseURL: URL = DeepSeek.defaultBaseURL,
        apiKey: String,
        session: URLSession = URLSession(configuration: .default, delegate: nil, delegateQueue: nil),
        logger: LangToolsLogger? = nil
    ) {
        openAI = Self.makeClient(baseURL: baseURL, apiKey: apiKey, session: session, logger: logger)
    }

    /// DeepSeek's thinking mode (on by default for V4 models) requires
    /// `reasoning_content` on every assistant turn sent back, and it supports
    /// only `json_object` structured output.
    public static func adaptChatBody(_ body: inout [String: JSON]) {
        OpenAICompatibleBody.remove(["seed", "user"], from: &body)
        OpenAICompatibleBody.updateMessages(in: &body) { message in
            if message["role"] == .string("assistant"), message["reasoning_content"] == nil {
                message["reasoning_content"] = .string("")
            }
        }
        if body["response_format"]?["type"] == .string("json_schema") {
            body["response_format"] = .object(["type": .string("json_object")])
        }
    }
}
