//
//  Mistral.swift
//  LangTools
//
//  Mistral's La Plateforme API, which follows OpenAI's chat format but
//  rejects fields it does not know.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LangTools
import OpenAI
import OpenAICompatible

public final class Mistral: OpenAICompatibleProvider {
    public typealias Model = OpenAICompatibleModel<Mistral>
    public typealias ErrorResponse = OpenAICompatibleErrorResponse

    public static let providerID = LangToolsProviderID(rawValue: "mistral")
    public static let displayName = "Mistral"
    public static let defaultBaseURL = URL(string: "https://api.mistral.ai/v1/")!
    public static let apiKeyEnvironmentVariable = "MISTRAL_API_KEY"

    /// Suggested models. The provider's catalog changes often; `listModels()` is authoritative.
    public static var knownModels: [Model] {
        [
            "mistral-large-latest",
            "mistral-medium-latest",
            "mistral-small-latest",
            "magistral-medium-latest",
            "codestral-latest",
            "ministral-8b-latest"
        ]
    }

    public let openAI: OpenAI

    public init(
        baseURL: URL = Mistral.defaultBaseURL,
        apiKey: String,
        session: URLSession = URLSession(configuration: .default, delegate: nil, delegateQueue: nil),
        logger: LangToolsLogger? = nil
    ) {
        openAI = Self.makeClient(baseURL: baseURL, apiKey: apiKey, session: session, logger: logger)
    }

    /// Mistral answers 422 for any field it does not define, so OpenAI-only
    /// options are removed and renamed ones moved to Mistral's names.
    public static func adaptChatBody(_ body: inout [String: JSON]) {
        OpenAICompatibleBody.remove(["stream_options", "user", "service_tier", "store", "metadata", "logit_bias", "logprobs", "top_logprobs", "modalities", "audio", "prediction"], from: &body)
        OpenAICompatibleBody.rename("seed", to: "random_seed", in: &body)
        OpenAICompatibleBody.rename("max_completion_tokens", to: "max_tokens", in: &body)
        OpenAICompatibleBody.updateMessages(in: &body) { message in
            if message["role"] != .string("tool") { message.removeValue(forKey: "name") }
        }
    }
}
