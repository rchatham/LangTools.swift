//
//  Anthropic+Gateway.swift
//  Anthropic
//
//  Gateways such as Vercel AI Gateway and OpenRouter also accept Anthropic's
//  Messages format at their own base URL. A gateway prepares requests with an
//  `Anthropic` client pointed at that URL and sends the gateway's model ID,
//  such as `anthropic/claude-sonnet-4.5`, in place of Anthropic's.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LangTools

/// A gateway serving Anthropic's Messages API (`POST {base}/messages`).
///
/// Requests reach a gateway only when routed to it with
/// `MessageRequest.routed(to:modelID:)`; untagged requests stay with `Anthropic`.
/// Conforming types declare `typealias Model = Anthropic.Model` and
/// `typealias ErrorResponse = AnthropicGatewayErrorResponse`.
public protocol AnthropicMessagesGateway: LangTools where ErrorResponse == AnthropicGatewayErrorResponse {
    /// The tag that routes requests to this gateway.
    static var anthropicProviderID: LangToolsProviderID { get }

    /// The client that prepares requests for the gateway's Messages endpoint.
    var anthropic: Anthropic { get }
}

extension AnthropicMessagesGateway {
    public var session: URLSession { anthropic.session }
    public var logger: LangToolsLogger? { anthropic.logger }

    public static var requestValidators: [(any LangToolsRequest) -> Bool] {
        [{ ($0 as? Anthropic.MessageRequest)?.gatewayProviderID == anthropicProviderID }]
    }

    public func prepare(request: some LangToolsRequest) throws -> URLRequest {
        var urlRequest = try anthropic.prepare(request: request)
        if let message = request as? Anthropic.MessageRequest, let data = urlRequest.httpBody,
           case .object(var body) = try JSONDecoder().decode(JSON.self, from: data) {
            body["model"] = .string(message.gatewayModelID ?? message.model.gatewayModelID)
            urlRequest.httpBody = try JSONEncoder().encode(JSON.object(body))
        }
        return urlRequest
    }

    public static func decodeStream<T: Decodable>(_ buffer: String) throws -> T? {
        if buffer.hasPrefix("event:") { return nil }
        return if buffer.hasPrefix("data:") && !buffer.contains("[DONE]"), let data = buffer.dropFirst(5).data(using: .utf8) { try Self.decodeResponse(data: data) } else { nil }
    }

    /// A Messages request routed to this gateway.
    public static func chatRequest(model: any RawRepresentable, messages: [any LangToolsMessage], tools: [any LangToolsTool]?, responseSchema: JSONSchema?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) throws -> any LangToolsChatRequest {
        guard let request = try Anthropic.chatRequest(model: model, messages: messages, tools: tools, responseSchema: responseSchema, toolEventHandler: toolEventHandler) as? Anthropic.MessageRequest else {
            throw LangToolsError.invalidArgument("Unsupported model \(model)")
        }
        return request.routed(to: anthropicProviderID)
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

/// An error from a Messages-format gateway: Anthropic's shape
/// (`{"type": "error", "error": {"type": ..., "message": ...}}`) or the
/// OpenAI-style shape some gateways return (`{"error": {"message": ..., "code": ...}}`).
public struct AnthropicGatewayErrorResponse: Error, Codable, LocalizedError, Equatable {
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
