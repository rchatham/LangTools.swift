//
//  OpenRouter.swift
//  LangTools
//
//  OpenRouter is a gateway to models from many vendors. It serves OpenAI's
//  chat format, Anthropic's Messages format, and its own catalog request.
//  Chat requests carry the OpenRouter provider tag, so they never collide with
//  OpenAI, XAI, Gemini, or another gateway serving the same `creator/model`
//  slugs.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LangTools
import OpenAI
import OpenAICompatible
import Anthropic
import AnthropicCompatible

public final class OpenRouter: OpenAICompatibleProvider, AnthropicCompatibleProvider {
    public typealias Model = OpenRouterModel
    public typealias ErrorResponse = OpenRouterErrorResponse

    /// The provider tag carried by every OpenRouter request.
    public static let providerID = LangToolsProviderID(rawValue: "openrouter")
    public static let displayName = "OpenRouter"
    public static let defaultBaseURL = URL(string: "https://openrouter.ai/api/v1/")!
    public static let apiKeyEnvironmentVariable = "OPENROUTER_API_KEY"

    /// OpenRouter's router. The catalog is too large and changes too often for
    /// a static list; use `listModels()`.
    public static var knownModels: [Model] { [.auto] }

    public let openAI: OpenAI
    public let anthropic: Anthropic
    public let additionalHeaders: [String: String]
    private let baseURL: URL

    /// - Parameters:
    ///   - appURL: Sent as `HTTP-Referer`. OpenRouter uses it to identify your app
    ///     in its rankings and analytics.
    ///   - appTitle: Sent as `X-OpenRouter-Title`, the app's display name there.
    public init(
        baseURL: URL = OpenRouter.defaultBaseURL,
        apiKey: String,
        appURL: URL? = nil,
        appTitle: String? = nil,
        session: URLSession = URLSession(configuration: .default, delegate: nil, delegateQueue: nil),
        logger: LangToolsLogger? = nil
    ) {
        var headers: [String: String] = [:]
        if let appURL { headers["HTTP-Referer"] = appURL.absoluteString }
        if let appTitle, !appTitle.isEmpty { headers["X-OpenRouter-Title"] = appTitle }
        self.baseURL = baseURL
        additionalHeaders = headers
        openAI = Self.makeClient(baseURL: baseURL, apiKey: apiKey, session: session, logger: logger)
        anthropic = Anthropic(baseURL: baseURL, apiKey: apiKey, session: session, logger: logger)
    }

    // OpenRouter accepts the key as a bearer token on every format.
    public var anthropicAuthentication: AnthropicCompatibleAuthentication { .bearer }

    // MARK: Serving every format

    public var session: URLSession { openAI.session }
    public var logger: LangToolsLogger? { openAI.logger }

    /// Claims tagged chat requests, Messages requests routed to OpenRouter, and
    /// OpenRouter's catalog request. Untagged models are left to OpenAI, XAI,
    /// and Gemini.
    public static var requestValidators: [(any LangToolsRequest) -> Bool] {
        compatibleRequestValidators + anthropicRequestValidators + [{ $0 is ListModelsRequest }]
    }

    public func prepare(request: some LangToolsRequest) throws -> URLRequest {
        if request is Anthropic.MessageRequest {
            var urlRequest = try prepareAnthropicCompatible(request: request)
            try OpenAICompatibleHeaders.apply(additionalHeaders, to: &urlRequest)
            return urlRequest
        }
        var urlRequest = try prepareCompatible(request: request)
        // The OpenAI client derives GET query items from every stored property,
        // including nil optionals, so the catalog request builds its own URL.
        if let listModels = request as? ListModelsRequest {
            urlRequest.url = listModels.url(relativeTo: baseURL)
        }
        return urlRequest
    }

    /// An Anthropic `Model` builds a Messages request; an OpenRouter `Model`
    /// builds a chat completion request.
    public static func chatRequest(model: any RawRepresentable, messages: [any LangToolsMessage], tools: [any LangToolsTool]?, responseSchema: JSONSchema?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) throws -> any LangToolsChatRequest {
        if let model = model as? Anthropic.Model {
            return try anthropicChatRequest(model: model, messages: messages, tools: tools, responseSchema: responseSchema, toolEventHandler: toolEventHandler)
        }
        guard let model = model as? Model else { throw LangToolsError.invalidArgument("Unsupported model \(model)") }
        return try compatibleChatRequest(model: model, messages: messages, tools: tools, responseSchema: responseSchema, toolEventHandler: toolEventHandler)
    }
}

/// An OpenRouter error body: `{"error": {"code": 402, "message": "..."}}`. The
/// Messages endpoint's `{"type": "error", "error": {"type": ..., "message": ...}}`
/// decodes into the same shape.
public struct OpenRouterErrorResponse: Error, Codable, LocalizedError {
    public let error: OpenAI.ChatCompletionResponse.ResponseError

    public init(error: OpenAI.ChatCompletionResponse.ResponseError) {
        self.error = error
    }

    public var errorDescription: String? { error.errorDescription }
}

/// An OpenRouter model slug such as `"anthropic/claude-sonnet-4.5"`, optionally
/// with a variant suffix such as `":free"`. Empty and whitespace-padded slugs
/// are rejected.
///
/// OpenRouter's catalog changes often, so models are plain slugs rather than an
/// enum. Use `OpenRouter.listModels()` to discover them.
public typealias OpenRouterModel = OpenAICompatibleModel<OpenRouter>

extension OpenAICompatibleModel where Provider == OpenRouter {
    /// OpenRouter's router, which picks a model for each prompt.
    public static var auto: OpenRouterModel { "openrouter/auto" }
}
