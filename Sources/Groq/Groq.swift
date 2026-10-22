//
//  Groq.swift
//  LangTools
//
//  Groq serves open-weight models through an OpenAI-compatible API.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LangTools
import OpenAI

public final class Groq: OpenAICompatibleProvider {
    public typealias Model = OpenAICompatibleModel<Groq>
    public typealias ErrorResponse = OpenAICompatibleErrorResponse

    public static let providerID = LangToolsProviderID(rawValue: "groq")
    public static let displayName = "Groq"
    public static let defaultBaseURL = URL(string: "https://api.groq.com/openai/v1/")!
    public static let apiKeyEnvironmentVariable = "GROQ_API_KEY"

    /// Suggested models. The provider's catalog changes often; `listModels()` is authoritative.
    public static var knownModels: [Model] {
        [
            "llama-3.3-70b-versatile",
            "llama-3.1-8b-instant",
            "openai/gpt-oss-120b",
            "openai/gpt-oss-20b",
            "moonshotai/kimi-k2-instruct-0905",
            "meta-llama/llama-4-scout-17b-16e-instruct"
        ]
    }

    public let openAI: OpenAI

    public init(
        baseURL: URL = Groq.defaultBaseURL,
        apiKey: String,
        session: URLSession = URLSession(configuration: .default, delegate: nil, delegateQueue: nil),
        logger: LangToolsLogger? = nil
    ) {
        openAI = Self.makeClient(baseURL: baseURL, apiKey: apiKey, session: session, logger: logger)
    }

    /// Groq rejects log-probability options and `name` on messages.
    public static func adaptChatBody(_ body: inout [String: JSON]) {
        OpenAICompatibleBody.remove(["logprobs", "top_logprobs", "logit_bias"], from: &body)
        OpenAICompatibleBody.updateMessages(in: &body) { $0.removeValue(forKey: "name") }
    }
}
