//
//  OpenRouter.swift
//  LangTools
//
//  OpenRouter is an OpenAI-compatible gateway to models from many vendors.
//  Requests are `OpenAI.ChatCompletionRequest`s whose model carries the
//  OpenRouter provider tag, so they never collide with OpenAI, XAI, Gemini,
//  or another gateway serving the same `creator/model` slugs.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LangTools
import OpenAI

public final class OpenRouter: LangTools {
    public typealias Model = OpenRouterModel
    public typealias ErrorResponse = OpenRouterErrorResponse

    /// The provider tag carried by every OpenRouter model.
    public static let providerID = LangToolsProviderID(rawValue: "openrouter")
    public static let defaultBaseURL = URL(string: "https://openrouter.ai/api/v1/")!

    /// Claims chat requests whose model is tagged for OpenRouter, and OpenRouter's
    /// own catalog request. Untagged models are left to OpenAI, XAI, and Gemini.
    public static var requestValidators: [(any LangToolsRequest) -> Bool] {
        [
            { ($0 as? OpenAI.ChatCompletionRequest)?.model.belongs(to: providerID) ?? false },
            { $0 is ListModelsRequest },
        ]
    }

    public var session: URLSession { openAI.session }
    public var logger: LangToolsLogger? { openAI.logger }

    let openAI: OpenAI
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
        openAI = OpenAI(configuration: .init(
            baseURL: baseURL, apiKey: apiKey, session: session, logger: logger, additionalHeaders: headers))
    }

    public func prepare(request: some LangToolsRequest) throws -> URLRequest {
        var urlRequest = try openAI.prepare(request: request)
        // The OpenAI client derives GET query items from every stored property,
        // including nil optionals, so the catalog request builds its own URL.
        if let listModels = request as? ListModelsRequest {
            urlRequest.url = listModels.url(relativeTo: baseURL)
        }
        return urlRequest
    }

    public static func chatRequest(model: any RawRepresentable, messages: [any LangToolsMessage], tools: [any LangToolsTool]?, responseSchema: JSONSchema?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) throws -> any LangToolsChatRequest {
        guard let model = model as? Model else { throw LangToolsError.invalidArgument("Unsupported model \(model)") }
        return try OpenAI.chatRequest(model: model.openAIModel, messages: messages, tools: tools, responseSchema: responseSchema, toolEventHandler: toolEventHandler)
    }
}

/// An OpenRouter error body: `{"error": {"code": 402, "message": "..."}}`.
public struct OpenRouterErrorResponse: Error, Codable, LocalizedError {
    public let error: OpenAI.ChatCompletionResponse.ResponseError

    public init(error: OpenAI.ChatCompletionResponse.ResponseError) {
        self.error = error
    }

    public var errorDescription: String? { error.errorDescription }
}

/// An OpenRouter model slug such as `"anthropic/claude-sonnet-4.5"`, optionally
/// with a variant suffix such as `":free"`.
///
/// OpenRouter's catalog changes often, so models are plain slugs rather than an
/// enum. Use `OpenRouter.listModels()` to discover them.
public struct OpenRouterModel: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    /// Returns nil for an empty or whitespace-only slug.
    public init?(rawValue: String) {
        guard !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        rawValue = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let slug = try container.decode(String.self)
        guard let model = OpenRouterModel(rawValue: slug) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Empty OpenRouter model slug")
        }
        self = model
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    /// OpenRouter's router, which picks a model for each prompt.
    public static let auto: OpenRouterModel = "openrouter/auto"

    /// The tagged OpenAI-compatible model used on the wire and for routing.
    public var openAIModel: OpenAIModel {
        OpenAIModel(customModelID: rawValue, providerID: OpenRouter.providerID)
    }
}
