//
//  OpenAI+ResponseItem.swift
//  OpenAI
//
//  Responses API input/conversation item.
//

import Foundation
import LangTools


public extension OpenAI {
    /// A single conversation item used by the Responses API.
    ///
    /// The Responses API models a conversation as an array of `input` items rather than
    /// chat-style `messages`. An item can be a plain message (`role` + `content`), an
    /// assistant `function_call`, or a `function_call_output` carrying a tool result.
    ///
    /// To maximise reuse and cross-provider conversion, `Item` reuses the existing
    /// `OpenAI.Message` value types (`Role`, `Content`, `ToolCall`, `ToolResultContent`).
    struct Item: Codable, CustomStringConvertible, LangToolsMessage, LangToolsToolMessage {
        public typealias Role = OpenAI.Message.Role
        public typealias Content = OpenAI.Message.Content
        public typealias ToolSelection = OpenAI.Message.ToolCall
        public typealias ToolResult = OpenAI.Message.Content.ToolResultContent

        public let role: Role
        public let content: Content
        public let tool_calls: [ToolSelection]?

        public var tool_selection: [ToolSelection]? { tool_calls }

        var toolResult: ToolResult? {
            if case .toolResult(let tool) = content.array?.first { return tool }; return nil
        }

        public var tool_selection_id: String { toolResult?.tool_selection_id ?? "no id" }

        public var description: String {
            let tools = tool_calls?.map { $0.function.name ?? "" }.joined(separator: ",")
            return "Item(role: \(role.rawValue), content: \(content), tool_calls: \(tools ?? ""))"
        }

        // MARK: - Initializers

        public init(role: Role, content: Content) {
            self.role = role
            self.content = content
            self.tool_calls = nil
        }

        public init(role: Role, content: Content, tool_calls: [ToolSelection]?) {
            self.role = role
            self.content = content
            self.tool_calls = role == .assistant ? tool_calls : nil
        }

        /// Converts any message into an `Item`, preserving assistant tool calls (which the
        /// default `LangToolsMessage.init(_:)` would drop) so that tool-call history survives
        /// when a `ResponseRequest` is built from a heterogeneous `[any LangToolsMessage]`.
        public init(_ message: any LangToolsMessage) {
            if let openAIMessage = message as? OpenAI.Message, let calls = openAIMessage.tool_calls, !calls.isEmpty {
                self.init(tool_selection: calls)
            } else if let item = message as? Item, let calls = item.tool_calls, !calls.isEmpty {
                self.init(tool_selection: calls)
            } else {
                self.init(role: Role(message.role), content: Content(message.content))
            }
        }

        public init(role: Role, content: String) {
            self.init(role: role, content: .string(content))
        }

        public init(tool_selection: [ToolSelection]) {
            self.role = .assistant
            self.content = .null
            self.tool_calls = tool_selection
        }

        public init(tool_selection_id: String, result: String) {
            self.role = .tool
            self.content = .array([.toolResult(.init(tool_selection_id: tool_selection_id, result: result))])
            self.tool_calls = nil
        }

        public static func messages(for tool_results: [ToolResult]) -> [Item] {
            return tool_results.map { Item(tool_selection_id: $0.tool_selection_id, result: $0.result) }
        }

        // MARK: - Codable (Responses wire format)

        enum MessageKeys: String, CodingKey { case type, role, content }
        enum FunctionCallKeys: String, CodingKey { case type, call_id, name, arguments, output }

        public init(from decoder: Decoder) throws {
            // Peek at the discriminator `type` to detect function_call / function_call_output items.
            if let fc = try? decoder.container(keyedBy: FunctionCallKeys.self),
               let type = try? fc.decode(String.self, forKey: .type) {
                switch type {
                case "function_call":
                    let callID = try fc.decodeIfPresent(String.self, forKey: .call_id)
                    let name = try fc.decodeIfPresent(String.self, forKey: .name)
                    let arguments = try fc.decodeIfPresent(String.self, forKey: .arguments) ?? ""
                    self.role = .assistant
                    self.content = .null
                    self.tool_calls = [ToolSelection(index: 0, id: callID ?? "", type: .function, function: .init(name: name ?? "", arguments: arguments))]
                    return
                case "function_call_output":
                    let callID = try fc.decode(String.self, forKey: .call_id)
                    let output = try fc.decodeIfPresent(String.self, forKey: .output) ?? ""
                    self.role = .tool
                    self.content = .array([.toolResult(.init(tool_selection_id: callID, result: output))])
                    self.tool_calls = nil
                    return
                default:
                    break
                }
            }
            let container = try decoder.container(keyedBy: MessageKeys.self)
            self.role = try container.decode(Role.self, forKey: .role)
            self.content = try container.decodeIfPresent(Content.self, forKey: .content) ?? .null
            self.tool_calls = nil
        }

        public func encode(to encoder: Encoder) throws {
            if let tool_calls, let first = tool_calls.first {
                // A single function_call item. Items carrying multiple tool calls must be
                // flattened into multiple items by `ResponseRequest.encode(to:)`; encoding
                // such an Item on its own would silently drop calls, so fail loudly instead.
                guard tool_calls.count == 1 else {
                    throw EncodingError.invalidValue(tool_calls, EncodingError.Context(
                        codingPath: encoder.codingPath,
                        debugDescription: "An Item carrying multiple tool calls cannot be encoded directly; encode it via OpenAI.ResponseRequest, which flattens each call into its own function_call input item."))
                }
                var c = encoder.container(keyedBy: FunctionCallKeys.self)
                try c.encode("function_call", forKey: .type)
                try c.encodeIfPresent(first.id, forKey: .call_id)
                try c.encodeIfPresent(first.name, forKey: .name)
                try c.encode(first.arguments, forKey: .arguments)
            } else if let toolResult {
                var c = encoder.container(keyedBy: FunctionCallKeys.self)
                try c.encode("function_call_output", forKey: .type)
                try c.encode(toolResult.tool_selection_id, forKey: .call_id)
                try c.encode(toolResult.result, forKey: .output)
            } else {
                var c = encoder.container(keyedBy: MessageKeys.self)
                try c.encode(role, forKey: .role)
                try Item.encodeContent(content, into: &c)
            }
        }

        /// Encodes message content using the Responses API input content-part shapes
        /// (`input_text` / `input_image`). Plain string content is encoded directly.
        static func encodeContent(_ content: Content, into container: inout KeyedEncodingContainer<MessageKeys>) throws {
            switch content {
            case .string(let str):
                try container.encode(str, forKey: .content)
            case .null:
                try container.encode("", forKey: .content)
            case .array(let parts):
                var arr = container.nestedUnkeyedContainer(forKey: .content)
                for part in parts {
                    switch part {
                    case .text(let text):
                        try arr.encode(InputTextPart(text: text.text))
                    case .image(let image):
                        try arr.encode(InputImagePart(image_url: image.image_url.url))
                    default:
                        break // refusals / tool results are not valid input content parts
                    }
                }
            }
        }

        struct InputTextPart: Encodable {
            let type = "input_text"
            let text: String
        }

        struct InputImagePart: Encodable {
            let type = "input_image"
            let image_url: String
        }
    }
}
