//
//  OpenAICompatibleProviders.swift
//  OpenAICompatible
//
//  Single-vendor providers that serve OpenAI's chat format with small
//  dialect differences, handled in `adaptChatBody`. Their catalogs change
//  often, so `knownModels` are suggestions and `listModels()` is authoritative.
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
    public static let providerID = LangToolsProviderID(rawValue: "groq"), displayName = "Groq", apiKeyEnvironmentVariable = "GROQ_API_KEY"
    public static let defaultBaseURL = URL(string: "https://api.groq.com/openai/v1/")!
    public static var knownModels: [Model] { ["llama-3.3-70b-versatile", "llama-3.1-8b-instant", "openai/gpt-oss-120b", "openai/gpt-oss-20b", "moonshotai/kimi-k2-instruct-0905", "meta-llama/llama-4-scout-17b-16e-instruct"] }
    public let openAI: OpenAI

    public init(baseURL: URL = defaultBaseURL, apiKey: String, session: URLSession = URLSession(configuration: .default), logger: LangToolsLogger? = nil) {
        openAI = Self.makeClient(baseURL: baseURL, apiKey: apiKey, session: session, logger: logger)
    }

    /// Groq rejects log-probability options and `name` on messages.
    public static func adaptChatBody(_ body: inout [String: JSON]) {
        OpenAICompatibleBody.remove(["logprobs", "top_logprobs", "logit_bias"], from: &body)
        OpenAICompatibleBody.updateMessages(in: &body) { $0.removeValue(forKey: "name") }
    }
}

public final class Mistral: OpenAICompatibleProvider {
    public typealias Model = OpenAICompatibleModel<Mistral>
    public typealias ErrorResponse = OpenAICompatibleErrorResponse
    public static let providerID = LangToolsProviderID(rawValue: "mistral"), displayName = "Mistral", apiKeyEnvironmentVariable = "MISTRAL_API_KEY"
    public static let defaultBaseURL = URL(string: "https://api.mistral.ai/v1/")!
    public static var knownModels: [Model] { ["mistral-large-latest", "mistral-medium-latest", "mistral-small-latest", "magistral-medium-latest", "codestral-latest", "ministral-8b-latest"] }
    public let openAI: OpenAI

    public init(baseURL: URL = defaultBaseURL, apiKey: String, session: URLSession = URLSession(configuration: .default), logger: LangToolsLogger? = nil) {
        openAI = Self.makeClient(baseURL: baseURL, apiKey: apiKey, session: session, logger: logger)
    }

    /// Mistral answers 422 for fields it does not define: OpenAI-only options are
    /// removed and renamed ones moved to Mistral's names.
    public static func adaptChatBody(_ body: inout [String: JSON]) {
        OpenAICompatibleBody.remove(["stream_options", "user", "service_tier", "store", "metadata", "logit_bias", "logprobs", "top_logprobs", "modalities", "audio", "prediction"], from: &body)
        OpenAICompatibleBody.rename("seed", to: "random_seed", in: &body)
        OpenAICompatibleBody.rename("max_completion_tokens", to: "max_tokens", in: &body)
        OpenAICompatibleBody.updateMessages(in: &body) { if $0["role"] != .string("tool") { $0.removeValue(forKey: "name") } }
    }
}

public final class DeepSeek: OpenAICompatibleProvider {
    public typealias Model = OpenAICompatibleModel<DeepSeek>
    public typealias ErrorResponse = OpenAICompatibleErrorResponse
    public static let providerID = LangToolsProviderID(rawValue: "deepseek"), displayName = "DeepSeek", apiKeyEnvironmentVariable = "DEEPSEEK_API_KEY"
    public static let defaultBaseURL = URL(string: "https://api.deepseek.com/")!
    public static var knownModels: [Model] { ["deepseek-v4-flash", "deepseek-v4-pro"] }
    public let openAI: OpenAI

    public init(baseURL: URL = defaultBaseURL, apiKey: String, session: URLSession = URLSession(configuration: .default), logger: LangToolsLogger? = nil) {
        openAI = Self.makeClient(baseURL: baseURL, apiKey: apiKey, session: session, logger: logger)
    }

    /// Thinking mode (the V4 default) requires `reasoning_content` on every assistant
    /// turn, and DeepSeek supports only `json_object` structured output.
    public static func adaptChatBody(_ body: inout [String: JSON]) {
        OpenAICompatibleBody.remove(["seed", "user"], from: &body)
        OpenAICompatibleBody.updateMessages(in: &body) { if $0["role"] == .string("assistant"), $0["reasoning_content"] == nil { $0["reasoning_content"] = .string("") } }
        if body["response_format"]?["type"] == .string("json_schema") { body["response_format"] = .object(["type": .string("json_object")]) }
    }
}

public final class Cerebras: OpenAICompatibleProvider {
    public typealias Model = OpenAICompatibleModel<Cerebras>
    public typealias ErrorResponse = OpenAICompatibleErrorResponse
    public static let providerID = LangToolsProviderID(rawValue: "cerebras"), displayName = "Cerebras", apiKeyEnvironmentVariable = "CEREBRAS_API_KEY"
    public static let defaultBaseURL = URL(string: "https://api.cerebras.ai/v1/")!
    public static var knownModels: [Model] { ["gpt-oss-120b", "gemma-4-31b"] }
    public let openAI: OpenAI

    public init(baseURL: URL = defaultBaseURL, apiKey: String, session: URLSession = URLSession(configuration: .default), logger: LangToolsLogger? = nil) {
        openAI = Self.makeClient(baseURL: baseURL, apiKey: apiKey, session: session, logger: logger)
    }
}

public final class TogetherAI: OpenAICompatibleProvider {
    public typealias Model = OpenAICompatibleModel<TogetherAI>
    public typealias ErrorResponse = OpenAICompatibleErrorResponse
    public static let providerID = LangToolsProviderID(rawValue: "together"), displayName = "Together AI", apiKeyEnvironmentVariable = "TOGETHER_API_KEY"
    public static let defaultBaseURL = URL(string: "https://api.together.xyz/v1/")!
    public static var knownModels: [Model] { ["meta-llama/Llama-3.3-70B-Instruct-Turbo", "deepseek-ai/DeepSeek-V3", "Qwen/Qwen2.5-72B-Instruct-Turbo", "Qwen/Qwen2.5-Coder-32B-Instruct"] }
    public let openAI: OpenAI

    public init(baseURL: URL = defaultBaseURL, apiKey: String, session: URLSession = URLSession(configuration: .default), logger: LangToolsLogger? = nil) {
        openAI = Self.makeClient(baseURL: baseURL, apiKey: apiKey, session: session, logger: logger)
    }

    /// Together takes `logprobs` as a count rather than a flag.
    public static func adaptChatBody(_ body: inout [String: JSON]) {
        guard case .bool(let enabled)? = body["logprobs"] else { return }
        let count = body.removeValue(forKey: "top_logprobs") ?? .number(1)
        body["logprobs"] = enabled ? count : nil
    }
}

public final class Fireworks: OpenAICompatibleProvider {
    public typealias Model = OpenAICompatibleModel<Fireworks>
    public typealias ErrorResponse = OpenAICompatibleErrorResponse
    public static let providerID = LangToolsProviderID(rawValue: "fireworks"), displayName = "Fireworks AI", apiKeyEnvironmentVariable = "FIREWORKS_API_KEY"
    public static let defaultBaseURL = URL(string: "https://api.fireworks.ai/inference/v1/")!
    public static var knownModels: [Model] { ["accounts/fireworks/models/kimi-k2-instruct", "accounts/fireworks/models/deepseek-v3", "accounts/fireworks/models/llama-v3p3-70b-instruct", "accounts/fireworks/models/qwen2p5-coder-32b-instruct"] }
    public let openAI: OpenAI

    public init(baseURL: URL = defaultBaseURL, apiKey: String, session: URLSession = URLSession(configuration: .default), logger: LangToolsLogger? = nil) {
        openAI = Self.makeClient(baseURL: baseURL, apiKey: apiKey, session: session, logger: logger)
    }
}
