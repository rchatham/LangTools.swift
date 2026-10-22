//
//  AnthropicCompatibleProvider.swift
//  AnthropicCompatible
//
//  Shared plumbing for providers that also serve Anthropic's Messages format
//  (Vercel AI Gateway, OpenRouter, ...). A provider prepares requests with an
//  `Anthropic` client pointed at its base URL; this layer routes requests to
//  it, sends the provider's model ID in place of Anthropic's, and applies the
//  provider's authentication. The Anthropic module itself only provides the
//  routing hook: `MessageRequest.routed(to:modelID:)`.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LangTools
@_exported import Anthropic

/// A provider serving Anthropic's Messages API (`POST {base}/messages`).
///
/// Requests reach the provider only when routed to it with
/// `MessageRequest.routed(to:modelID:)`; unrouted requests stay with
/// `Anthropic`.
///
/// A class can serve this format alongside others, such as the OpenAI format
/// from `OpenAICompatibleProvider`. It then implements the members both
/// protocols provide (`session`, `logger`, `requestValidators`, `prepare`,
/// `chatRequest`) by combining `anthropicRequestValidators`,
/// `prepareAnthropicCompatible(request:)`, and `anthropicChatRequest(...)`
/// with the other format's equivalents.
public protocol AnthropicCompatibleProvider: LangTools {
    /// The tag that routes requests to this provider. A class serving several
    /// formats uses one ID for all of them.
    static var providerID: LangToolsProviderID { get }

    /// The client that prepares requests for the provider's Messages endpoint.
    var anthropic: Anthropic { get }

    /// How the API key is sent. Defaults to Anthropic's `x-api-key` header.
    var anthropicAuthentication: AnthropicCompatibleAuthentication { get }

    /// The model ID sent for `model` when a request has no explicit model ID.
    /// Defaults to `model.gatewayModelID`, such as `anthropic/claude-sonnet-4.5`.
    static func anthropicModelID(for model: Anthropic.Model) -> String
}

/// How an Anthropic-compatible provider expects the API key.
public enum AnthropicCompatibleAuthentication: Sendable {
    /// `x-api-key: <key>`, as Anthropic does.
    case apiKeyHeader
    /// `Authorization: Bearer <key>`, which some gateways also accept, or
    /// require for tokens.
    case bearer
}

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

    /// Prepares a request for the Messages endpoint: the Anthropic client's
    /// request with the provider's authentication and model ID.
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
    /// The `anthropic/<family>-<version>` ID that gateways use for this model,
    /// such as `anthropic/claude-sonnet-4.5` for `claude-sonnet-4-5-20250929`.
    /// Date and `-latest` suffixes are dropped, so dated snapshots map to the
    /// gateway's current model of that version.
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

/// An error from an Anthropic-compatible endpoint: Anthropic's shape
/// (`{"type": "error", "error": {"type": ..., "message": ...}}`) or the
/// OpenAI-style shape some gateways return (`{"error": {"message": ..., "code": ...}}`).
public struct AnthropicCompatibleErrorResponse: Error, Codable, LocalizedError, Equatable {
    public let message: String
    public let type: String?

    public init(message: String, type: String? = nil) {
        self.message = message
        self.type = type
    }

    public var errorDescription: String? { message }

    private enum CodingKeys: String, CodingKey { case error, message, type }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let nested = try? container.nestedContainer(keyedBy: CodingKeys.self, forKey: .error),
           let message = try? nested.decode(String.self, forKey: .message) {
            self.init(message: message, type: try? nested.decode(String.self, forKey: .type))
        } else if let message = try? container.decode(String.self, forKey: .error) {
            self.init(message: message)
        } else {
            self.init(message: try container.decode(String.self, forKey: .message), type: try? container.decode(String.self, forKey: .type))
        }
    }

    /// Encodes Anthropic's shape.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("error", forKey: .type)
        var nested = container.nestedContainer(keyedBy: CodingKeys.self, forKey: .error)
        try nested.encode(message, forKey: .message)
        try nested.encodeIfPresent(type, forKey: .type)
    }
}
