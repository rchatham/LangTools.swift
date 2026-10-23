//
//  AnthropicCompatibleProvider.swift
//  AnthropicCompatible
//
//  Shared plumbing for providers that also serve Anthropic's Messages format
//  (Vercel AI Gateway, OpenRouter): routing, the provider's model IDs, and its
//  authentication, on an `Anthropic` client pointed at the provider.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LangTools
@_exported import Anthropic

/// A provider serving Anthropic's Messages API (`POST {base}/messages`) for requests
/// routed to it with `MessageRequest.routed(to:modelID:)`. A class serving other formats
/// too combines `anthropicRequestValidators`, `prepareAnthropicCompatible(request:)`, and
/// `anthropicChatRequest(...)` with theirs.
public protocol AnthropicCompatibleProvider: LangTools {
    static var providerID: LangToolsProviderID { get }
    var anthropic: Anthropic { get }
    /// How the API key is sent; defaults to Anthropic's `x-api-key` header.
    var anthropicAuthentication: AnthropicCompatibleAuthentication { get }
    /// The model ID sent when a request has none of its own; defaults to `model.gatewayModelID`.
    static func anthropicModelID(for model: Anthropic.Model) -> String
}

/// `x-api-key: <key>` as Anthropic expects, or `Authorization: Bearer <key>`.
public enum AnthropicCompatibleAuthentication: Sendable { case apiKeyHeader, bearer }

extension AnthropicCompatibleProvider {
    public var anthropicAuthentication: AnthropicCompatibleAuthentication { .apiKeyHeader }
    public static func anthropicModelID(for model: Anthropic.Model) -> String { model.gatewayModelID }

    public var session: URLSession { anthropic.session }
    public var logger: LangToolsLogger? { anthropic.logger }

    /// Claims Messages requests routed to this provider.
    public static var anthropicRequestValidators: [(any LangToolsRequest) -> Bool] {
        [{ ($0 as? Anthropic.MessageRequest)?.providerID == providerID }]
    }

    public static var requestValidators: [(any LangToolsRequest) -> Bool] { anthropicRequestValidators }

    /// The Anthropic client's request with the provider's authentication and model ID.
    public func prepareAnthropicCompatible(request: some LangToolsRequest) throws -> URLRequest {
        var urlRequest = try anthropic.prepare(request: request)
        if anthropicAuthentication == .bearer, let key = urlRequest.value(forHTTPHeaderField: "x-api-key") {
            urlRequest.setValue(nil, forHTTPHeaderField: "x-api-key")
            urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        if let message = request as? Anthropic.MessageRequest, let data = urlRequest.httpBody,
           case .object(var body) = try JSONDecoder().decode(JSON.self, from: data) {
            body["model"] = .string(message.providerModelID ?? Self.anthropicModelID(for: message.model))
            urlRequest.httpBody = try JSONEncoder().encode(JSON.object(body))
        }
        return urlRequest
    }

    public func prepare(request: some LangToolsRequest) throws -> URLRequest {
        try prepareAnthropicCompatible(request: request)
    }

    /// A Messages request routed to this provider.
    public static func anthropicChatRequest(model: Anthropic.Model, messages: [any LangToolsMessage], tools: [any LangToolsTool]?, responseSchema: JSONSchema?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) throws -> Anthropic.MessageRequest {
        guard let request = try Anthropic.chatRequest(model: model, messages: messages, tools: tools, responseSchema: responseSchema, toolEventHandler: toolEventHandler) as? Anthropic.MessageRequest else {
            throw LangToolsError.invalidArgument("Unsupported model \(model)")
        }
        return request.routed(to: providerID)
    }

    public static func chatRequest(model: any RawRepresentable, messages: [any LangToolsMessage], tools: [any LangToolsTool]?, responseSchema: JSONSchema?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) throws -> any LangToolsChatRequest {
        guard let model = model as? Anthropic.Model else { throw LangToolsError.invalidArgument("Unsupported model \(model)") }
        return try anthropicChatRequest(model: model, messages: messages, tools: tools, responseSchema: responseSchema, toolEventHandler: toolEventHandler)
    }
}

extension Anthropic.Model {
    /// The ID gateways use, such as `anthropic/claude-sonnet-4.5` for `claude-sonnet-4-5-20250929`;
    /// date and `-latest` suffixes are dropped.
    public var gatewayModelID: String {
        var parts = rawValue.split(separator: "-").map(String.init)
        if let last = parts.last, last == "latest" || (last.count == 8 && last.allSatisfy(\.isNumber)) {
            parts.removeLast()
        }
        // Join a trailing minor version with a dot: claude-opus-4-1 -> claude-opus-4.1,
        // claude-3-5-sonnet -> claude-3.5-sonnet.
        var joined: [String] = []
        for part in parts {
            if let previous = joined.last, previous.allSatisfy(\.isNumber), part.count == 1, part.allSatisfy(\.isNumber) {
                joined[joined.count - 1] = previous + "." + part
            } else {
                joined.append(part)
            }
        }
        return "anthropic/" + joined.joined(separator: "-")
    }
}
