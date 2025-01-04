//
//  Anthropic+Message.swift
//  Anthropic
//
//  Created by Reid Chatham on 12/7/23.
//

import Foundation
import LangTools


public extension Anthropic {
    func performMessageRequest(messages: [Message], model: Model = .claude35Sonnet_20240620, stream: Bool = false, completion: @escaping (Result<Anthropic.MessageResponse, Error>) -> Void, didCompleteStreaming: ((Error?) -> Void)? = nil) {
        perform(request: Anthropic.MessageRequest(model: model, messages: messages, stream: stream), completion: completion, didCompleteStreaming: didCompleteStreaming)
    }
}

extension Anthropic {
    public struct MessageRequest: Codable, LangToolsChatRequest, LangToolsStreamableRequest, LangToolsCompletableRequest, LangToolsToolCallingRequest {

        public typealias LangTool = Anthropic
        public typealias Response = MessageResponse
        public static var endpoint: String { "messages" }

        let model: Model
        public var messages: [Message]
        let max_tokens: Int
        let metadata: Metadata?
        let stop_sequences: [String]?
        public var stream: Bool?
        let system: String?
        let temperature: Double?
        public let tools: [Tool]?
        let tool_choice: ToolChoice?
        let top_k: Int?
        let top_p: Double?

        public init(model: Model, messages: [Message], max_tokens: Int = 1024, metadata: Metadata? = nil, stop_sequences: [String]? = nil, stream: Bool? = nil, system: String? = nil, temperature: Double? = nil, tools: [Tool]? = nil, tool_choice: ToolChoice? = nil, top_k: Int? = nil, top_p: Double? = nil) {
            self.model = model
            self.messages = messages
            self.max_tokens = max_tokens
            self.metadata = metadata
            self.stop_sequences = stop_sequences
            self.stream = stream
            self.system = system
            self.temperature = temperature
            self.tools = tools
            self.tool_choice = tool_choice
            self.top_k = top_k
            self.top_p = top_p
        }

        public enum ToolChoice: Codable {
            case auto, `any`, tool(String)

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                switch self {
                case .auto: try container.encode("auto", forKey: .type)
                case .any: try container.encode("any", forKey: .type)
                case .tool(let name): try container.encode("tool", forKey: .type)
                    try container.encode(name, forKey: .name)
                }
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                switch try container.decode(String.self, forKey: .type) {
                case "auto": self = .auto
                case "any": self = .any
                case "tool": self = .tool(try container.decode(String.self, forKey: .name))
                default: throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Invalid string value")
                }
            }

            enum CodingKeys: String, CodingKey {
                case type, name
            }
        }

        public struct Metadata: Codable {
            let user_id: String?
        }
    }

    public struct MessageResponse: Codable, LangToolsStreamableChatResponse, LangToolsToolCallingResponse {

        public var message: Anthropic.Message? {
            messageInfo.flatMap { Message(role: $0.role, content: $0.content) }
        }

        public typealias Message = Anthropic.Message
        public typealias ToolSelection = Message.ToolSelection

        public let type: ResponseType
        public let messageInfo: MessageResponseInfo?
        public let stream: StreamResponseInfo?
        public var usage: Usage { return Usage(input_tokens: messageInfo?.usage.input_tokens, output_tokens: stream?.usage?.output_tokens ?? messageInfo?.usage.output_tokens ?? 0) }

        init() {
            type = .empty
            messageInfo = nil
            stream = nil
        }

        init(content: Content, id: String, model: String, role: Role, stop_reason: StopReason?, stop_sequence: String?, type: ResponseType, usage: Usage) {
            self.type = type
            messageInfo = MessageResponseInfo(content: content, id: id, model: model, role: role, stop_reason: stop_reason, stop_sequence: stop_sequence, type: type, usage: usage)
            stream = nil
        }

        public enum ResponseType: String, Codable { case empty, message, message_start, message_delta, message_stop, content_block_start, content_block_delta, content_block_stop, ping }

        public enum StopReason: String, Codable { case end_turn, max_tokens, stop_sequence, tool_use }

        public struct Usage: Codable {
            public let input_tokens: Int?
            public let output_tokens: Int

            init(input_tokens: Int?, output_tokens: Int) {
                self.input_tokens = input_tokens
                self.output_tokens = output_tokens
            }
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let message = try? container.decode(MessageResponseInfo.self) {
                messageInfo = message
                stream = nil
                type = message.type
            } else if let stream = try? container.decode(StreamMessageResponse.self) {
                self.stream = StreamResponseInfo(index: stream.index, delta: stream.delta, usage: stream.usage)
                messageInfo = stream.message
                type = stream.type
            } else { throw DecodingError.valueNotFound(ResponseType.self, .init(codingPath: [], debugDescription: "Failed to decode response type.")) }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
//            if let stream = stream { try container.encode(StreamMessageResponse(type: type, message: messageInfo, index: stream.index, delta: stream.delta, usage: stream.usage)) }
//            else
            if let message = messageInfo { try container.encode(message) }
            else { throw EncodingError.invalidValue(false, .init(codingPath: [], debugDescription: "Missing stream and message data.")) }
        }

        enum CodingKeys: String, CodingKey {
            case content, id, model, role, stop_reason, stop_sequence, type, usage
        }
    }
}

extension Anthropic.MessageResponse: LangToolsStreamableResponse {
    public var delta: Delta? {
        stream?.delta
    }

    public struct MessageResponseInfo: Codable {
        public let content: Anthropic.Content
        public let id: String
        public let model: String
        public let role: Anthropic.Role
        public let stop_reason: StopReason?
        public let stop_sequence: String?
        public let type: ResponseType
        public let usage: Usage

        init(content: Anthropic.Content, id: String, model: String, role: Anthropic.Role, stop_reason: StopReason?, stop_sequence: String?, type: ResponseType, usage: Usage) {
            self.content = content
            self.id = id
            self.model = model
            self.role = role
            self.stop_reason = stop_reason
            self.stop_sequence = stop_sequence
            self.type = type
            self.usage = usage
        }
    }

    internal struct StreamMessageResponse: Decodable {
        let type: ResponseType
        let message: MessageResponseInfo?
        let index: Int?
        let delta: Delta?
        let usage: Usage?

        init(type: ResponseType, message: MessageResponseInfo?, index: Int?, delta: Delta?, usage: Usage?) {
            self.type = type
            self.message = message
            self.index = index
            self.delta = delta
            self.usage = usage
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.type = try container.decode(ResponseType.self, forKey: .type)
            self.message = try container.decodeIfPresent(MessageResponseInfo.self, forKey: .message)
            self.index = try container.decodeIfPresent(Int.self, forKey: .index)
            self.delta = try container.decodeIfPresent(Delta.self, forKey: .content_block) ?? container.decodeIfPresent(Delta.self, forKey: .delta)
            self.usage = try container.decodeIfPresent(Usage.self, forKey: .usage)
        }

//        public func encode(to encoder: Encoder) throws {}

        enum CodingKeys: CodingKey { case type, message, index, content_block, delta, usage }
    }

    public struct StreamResponseInfo {
        public let index: Int?
        public let delta: Delta?
        public let usage: Usage?
    }

    public struct Delta: Codable, LangToolsMessageDelta {
        public var role: Anthropic.Role? { .assistant }
        public var content: String? { text }

        public let type: String?
        public let text: String?

        // Tool use
        public let id: String?
        public let name: String?
//        public let input: [String:String]?
        public let partial_json: String?

        public let stop_reason: StopReason?
        public let stop_sequence: String?
    }

    public static var empty: Anthropic.MessageResponse { .init() }

    public func combining(with next: Anthropic.MessageResponse) -> Anthropic.MessageResponse {
        guard type != .empty else { return next }
        guard let message = messageInfo, case .array(var array) = message.content else { return self }
        // combine message content based on index
        if let index = next.stream?.index, let delta = next.stream?.delta {
            if index < array.count {
                if let partial_text = delta.text, case .text(let text) = array[index] {
                    array[index] = .text(.init(text: text.text + partial_text)) }
                if let partial_json = delta.partial_json, case .toolUse(let toolUse) = array[index] {
                    array[index] = .toolUse(.init(id: toolUse.id, name: toolUse.name, input: toolUse.input + partial_json)) }
            } else {
                if let partial_text = delta.text { array.append(.text(.init(text: partial_text))) }
                if delta.type == "tool_use", let id = delta.id, let name = delta.name { array.append(.toolUse(.init(id: id, name: name, input: ""))) } // This is kind of a hack, the api returns an empty json object for the "input" key, but then returns a string for "partial_json", so we ignore the "input" key when streaming.
            }
        }
        return Anthropic.MessageResponse(content: .array(array), id: message.id, model: message.model, role: message.role, stop_reason: message.stop_reason ?? next.stream?.delta?.stop_reason, stop_sequence: message.stop_sequence ?? next.stream?.delta?.stop_sequence, type: next.messageInfo?.type ?? message.type, usage: usage)
    }
}

public enum MessageRequestError: Error {
    case failedToDecodeFunctionArguments
    case missingRequiredFunctionArguments
}
