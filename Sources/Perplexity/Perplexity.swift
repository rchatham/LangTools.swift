//
//  Perplexity.swift
//  LangTools
//
//  Perplexity's Agent API: web-grounded answers in OpenAI's Responses format at
//  /v1/agent. Sonar Chat Completions was retired on 2026-09-27.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LangTools
import OpenAI
import OpenAICompatible

public final class Perplexity: OpenAICompatibleProvider {
    public typealias Model = OpenAICompatibleModel<Perplexity>
    public typealias ErrorResponse = OpenAICompatibleErrorResponse

    public static let providerID = LangToolsProviderID(rawValue: "perplexity"), displayName = "Perplexity", apiKeyEnvironmentVariable = "PERPLEXITY_API_KEY"
    public static let defaultBaseURL = URL(string: "https://api.perplexity.ai/v1/")!
    public static var compatibleFormats: OpenAICompatibleFormats { .responses }
    public static var supportsModelListing: Bool { false }
    /// Presets bundle a model, tools, and a reasoning budget; they are sent as `preset`.
    public static let presets: Set<String> = ["fast", "low", "medium", "high", "xhigh"]
    /// Any model the Agent API routes to, such as `openai/gpt-5.2`, can also be used by ID.
    public static var knownModels: [Model] { [.fast, .low, .medium, .high, .xhigh, .sonar] }

    public let openAI: OpenAI
    private let baseURL: URL

    public init(baseURL: URL = defaultBaseURL, apiKey: String, session: URLSession = URLSession(configuration: .default), logger: LangToolsLogger? = nil) {
        self.baseURL = baseURL
        openAI = Self.makeClient(baseURL: baseURL, apiKey: apiKey, session: session, logger: logger)
    }

    public func prepare(request: some LangToolsRequest) throws -> URLRequest {
        var urlRequest = try prepareCompatible(request: request)
        if request is OpenAI.ResponsesRequest { urlRequest.url = baseURL.appendingPathComponent("agent") }
        return urlRequest
    }

    /// Presets go as `preset`, the schema moves from `text.format` to `response_format`,
    /// and options the Agent API rejects are dropped.
    public static func adaptResponsesBody(_ body: inout [String: JSON]) {
        if case .string(let model)? = body["model"], presets.contains(model) {
            body.removeValue(forKey: "model")
            body["preset"] = .string(model)
        }
        if case .object(let text)? = body.removeValue(forKey: "text"),
           case .object(var format)? = text["format"], format["type"] == .string("json_schema") {
            format.removeValue(forKey: "type")
            body["response_format"] = .object(["type": .string("json_schema"), "json_schema": .object(format)])
        }
        OpenAICompatibleBody.remove(["tool_choice", "parallel_tool_calls", "metadata"], from: &body)
    }
}

extension OpenAICompatibleModel where Provider == Perplexity {
    public static var fast: Self { "fast" }
    public static var low: Self { "low" }
    public static var medium: Self { "medium" }
    public static var high: Self { "high" }
    public static var xhigh: Self { "xhigh" }
    public static var sonar: Self { "perplexity/sonar" }
}
