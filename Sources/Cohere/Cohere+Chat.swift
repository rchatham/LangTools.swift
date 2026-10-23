//
//  Cohere+Chat.swift
//  LangTools
//
//  Cohere's native v2 Chat API (`POST /v2/chat`), served beside the
//  Compatibility API. It adds grounding documents with citations, tool plans,
//  and thinking budgets.
//

import Foundation
import LangTools
import OpenAI
import OpenAICompatible

extension Cohere {
    public struct ChatRequest: Codable, LangToolsChatRequest, LangToolsStreamableRequest, LangToolsToolCallingRequest, LangToolsStructuredOutputRequest {
        public typealias Response = ChatResponse
        public typealias LangTool = Cohere
        public static var endpoint: String { "v2/chat" }

        public let model: Model
        public var messages: [Message]
        public var stream: Bool?
        public var tools: [OpenAI.Tool]?
        public var tool_choice: ToolChoice?
        /// Grounding documents: strings, or objects such as `{"id": ..., "data": {...}}`.
        /// The answer cites them in `message.citations`.
        public var documents: [JSON]?
        public var temperature: Double?, max_tokens: Int?, p: Double?, k: Int?, seed: Int?, stop_sequences: [String]?
        public var frequency_penalty: Double?, presence_penalty: Double?
        /// `["type": "enabled", "token_budget": 1024]`, or `["type": "disabled"]`.
        public var thinking: [String: JSON]?
        public var response_format: ResponseFormat?
        @CodableIgnored public var toolEventHandler: ((LangToolsToolEvent) -> Void)?

        public var responseSchema: JSONSchema? {
            get { response_format?.json_schema }
            set { response_format = newValue.map { ResponseFormat(json_schema: $0) } }
        }

        public init(model: Model, messages: [any LangToolsMessage]) { self.init(model: model, messages: messages.map { Message($0) }) }

        public init(model: Model, messages: [Message], stream: Bool? = nil, tools: [OpenAI.Tool]? = nil, tool_choice: ToolChoice? = nil, documents: [JSON]? = nil, temperature: Double? = nil, max_tokens: Int? = nil, p: Double? = nil, k: Int? = nil, seed: Int? = nil, stop_sequences: [String]? = nil, frequency_penalty: Double? = nil, presence_penalty: Double? = nil, thinking: [String: JSON]? = nil, toolEventHandler: ((LangToolsToolEvent) -> Void)? = nil) {
            (self.model, self.messages, self.stream, self.tools, self.tool_choice, self.documents, self.temperature, self.max_tokens) = (model, messages, stream, tools, tool_choice, documents, temperature, max_tokens)
            (self.p, self.k, self.seed, self.stop_sequences, self.frequency_penalty, self.presence_penalty, self.thinking, self.toolEventHandler) = (p, k, seed, stop_sequences, frequency_penalty, presence_penalty, thinking, toolEventHandler)
        }

        /// JSON output, constrained to `json_schema` when one is given.
        public struct ResponseFormat: Codable {
            public var type = "json_object", json_schema: JSONSchema?
        }

        /// `REQUIRED` forces a tool call and `NONE` forbids one; omit it to let the model choose.
        public enum ToolChoice: String, Codable {
            case required = "REQUIRED", none = "NONE"

            /// The choice matching an OpenAI tool choice; nil for `auto`.
            public init?(_ choice: OpenAI.ChatCompletionRequest.ToolChoice) {
                switch choice {
                case .none: self = .none
                case .auto: return nil
                case .required, .tool: self = .required
                }
            }
        }
    }

    public struct ChatResponse: Decodable, LangToolsStreamableChatResponse, LangToolsToolCallingResponse, LangToolsStructuredOutputResponse {
        public typealias ToolSelection = ToolCall

        public var id: String?
        /// `COMPLETE`, `STOP_SEQUENCE`, `MAX_TOKENS`, `TOOL_CALL`, `ERROR`, or `TIMEOUT`.
        public var finish_reason: String?
        public var message: Message?
        public var usage: JSON?

        // One streamed event; nil for a complete response.
        private var eventType: String?, eventIndex: Int?, textDelta: String?, toolPlanDelta: String?
        private var toolCallStart: ToolCall?, argumentsDelta: String?, citation: Citation?, eventError: String?

        public var delta: ChatDelta? { textDelta.map { ChatDelta(role: .assistant, content: $0) } }
        public var jsonContent: String? { message?.content.text }
        public static var empty: ChatResponse { ChatResponse() }

        init(id: String? = nil, finish_reason: String? = nil, message: Message? = nil, usage: JSON? = nil) {
            (self.id, self.finish_reason, self.message, self.usage) = (id, finish_reason, message, usage)
        }

        /// Fails on a `message-end` event carrying an error, or an `ERROR` finish.
        public func validateStreamChunk() throws {
            if let eventError { throw LangToolsError.apiError(OpenAICompatibleErrorResponse(message: eventError)) }
            if finish_reason == "ERROR" { throw LangToolsError.apiError(OpenAICompatibleErrorResponse(message: "The response finished with an error", code: finish_reason)) }
        }

        /// A stream is complete once `message-end` has set `finish_reason`.
        public func validateStreamCompletion() throws {
            guard finish_reason != nil else { throw LangToolsError.incompleteStream }
        }

        public func combining(with next: ChatResponse) -> ChatResponse {
            guard next.eventType != nil else { return next }
            var message = self.message ?? Message(role: .assistant, content: "")
            message.content.text += next.textDelta ?? ""
            if let plan = next.toolPlanDelta { message.tool_plan = (message.tool_plan ?? "") + plan }
            if let citation = next.citation { message.citations = (message.citations ?? []) + [citation] }
            var calls = message.tool_calls ?? []
            let index = next.eventIndex ?? (next.toolCallStart == nil ? calls.count - 1 : calls.count)
            if let call = next.toolCallStart, index <= calls.count {
                if index == calls.count { calls.append(call) } else { calls[index] = call }
            } else if let arguments = next.argumentsDelta, calls.indices.contains(index) {
                calls[index].function.arguments = (calls[index].function.arguments ?? "") + arguments
            }
            message.tool_calls = calls.isEmpty ? nil : calls
            return ChatResponse(id: next.id ?? id, finish_reason: next.finish_reason ?? finish_reason, message: message, usage: next.usage ?? usage)
        }

        private enum CodingKeys: String, CodingKey { case id, finish_reason, message, usage, type, index, delta }
        private struct Event: Decodable {
            struct DeltaMessage: Decodable { let content: Citation?, tool_plan: String?, tool_calls: ToolCall?, citations: Citation? }
            let message: DeltaMessage?, finish_reason: String?, usage: JSON?, error: JSON?
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(String.self, forKey: .id)
            guard let type = try container.decodeIfPresent(String.self, forKey: .type) else {
                finish_reason = try container.decodeIfPresent(String.self, forKey: .finish_reason)
                message = try container.decodeIfPresent(Message.self, forKey: .message)
                usage = try container.decodeIfPresent(JSON.self, forKey: .usage)
                return
            }
            eventType = type
            eventIndex = try container.decodeIfPresent(Int.self, forKey: .index)
            // Event payloads vary by type; one that does not match its expected shape is ignored.
            guard let delta = try? container.decodeIfPresent(Event.self, forKey: .delta) else { return }
            switch type {
            case "content-delta": textDelta = delta.message?.content?.text
            case "tool-plan-delta": toolPlanDelta = delta.message?.tool_plan
            case "tool-call-start": toolCallStart = delta.message?.tool_calls
            case "tool-call-delta": argumentsDelta = delta.message?.tool_calls?.function.arguments
            case "citation-start": citation = delta.message?.citations
            case "message-end":
                (finish_reason, usage) = (delta.finish_reason, delta.usage)
                eventError = delta.error?.stringValue ?? delta.error?["message"]?.stringValue
            default: break
            }
        }
    }

    public struct ChatDelta: Codable, LangToolsMessageDelta {
        public let role: Role?
        public let content: String?
    }

    public struct Message: Codable, LangToolsMessage, LangToolsToolMessage {
        public let role: Role
        public var content: LangToolsTextContent
        /// The model's plan before calling tools, on assistant messages.
        public var tool_plan: String?
        public var tool_calls: [ToolCall]?
        /// The call a `tool` message answers.
        public let tool_call_id: String?
        /// Spans of the answer grounded in documents or tool results.
        public var citations: [Citation]?

        public var tool_selection: [ToolCall]? { tool_calls }

        public init(role: Role, content: LangToolsTextContent) { self.init(role: role, content: content.text) }

        public init(role: Role, content: String, tool_plan: String? = nil, tool_calls: [ToolCall]? = nil, tool_call_id: String? = nil) {
            (self.role, self.content, self.tool_plan, self.tool_calls, self.tool_call_id) = (role, LangToolsTextContent(text: content), tool_plan, tool_calls, tool_call_id)
        }

        public init(tool_selection: [ToolCall]) { self.init(role: .assistant, content: "", tool_calls: tool_selection) }

        /// Converts another provider's message, keeping its tool calls and result.
        public init(_ message: any LangToolsMessage) {
            if let native = message as? Self { self = native; return }
            if let result = message.content.array?.compactMap(\.toolResultContentType).first {
                self.init(role: .tool, content: result.result, tool_call_id: result.tool_selection_id)
                return
            }
            let calls: [any LangToolsToolSelection] = (message as? any LangToolsToolMessage)?.tool_selection ?? []
            self.init(role: Role(message.role), content: message.content.text, tool_calls: calls.isEmpty ? nil : calls.map { ToolCall(id: $0.id, name: $0.name ?? "", arguments: $0.arguments) })
        }

        public static func messages(for tool_results: [ToolCallResult]) -> [Message] {
            tool_results.map { Message(role: .tool, content: $0.result, tool_call_id: $0.tool_selection_id) }
        }

        private enum CodingKeys: String, CodingKey { case role, content, tool_plan, tool_calls, tool_call_id, citations }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // Content is a string or typed parts; thinking parts are not answer text.
            let text = try? container.decodeIfPresent(String.self, forKey: .content)
            let parts = text == nil ? try container.decodeIfPresent([Citation].self, forKey: .content) ?? [] : []
            self.init(role: try container.decode(Role.self, forKey: .role), content: text ?? parts.filter { $0.type == "text" }.compactMap(\.text).joined(), tool_plan: try container.decodeIfPresent(String.self, forKey: .tool_plan), tool_calls: try container.decodeIfPresent([ToolCall].self, forKey: .tool_calls), tool_call_id: try container.decodeIfPresent(String.self, forKey: .tool_call_id))
            citations = try? container.decodeIfPresent([Citation].self, forKey: .citations)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(role, forKey: .role)
            // An assistant turn that only calls tools carries no content.
            if !content.text.isEmpty || tool_calls?.isEmpty != false { try container.encode(content.text, forKey: .content) }
            try container.encodeIfPresent(tool_plan, forKey: .tool_plan)
            try container.encodeIfPresent(tool_calls, forKey: .tool_calls)
            try container.encodeIfPresent(tool_call_id, forKey: .tool_call_id)
        }
    }

    public struct ToolCall: Codable, LangToolsToolSelection {
        public var id: String?, type: String? = "function", function: Function
        public var name: String? { function.name }
        /// Cohere's `"null"` arguments for a call without arguments read as empty.
        public var arguments: String { function.arguments == "null" ? "" : function.arguments ?? "" }

        public init(id: String?, name: String, arguments: String) { (self.id, function) = (id, Function(name: name, arguments: arguments)) }

        public struct Function: Codable {
            public var name: String?, arguments: String?
        }
    }

    public struct ToolCallResult: Codable, LangToolsToolSelectionResult {
        public let tool_selection_id: String, result: String
        public var is_error: Bool
        public init(tool_selection_id: String, result: String, is_error: Bool) { (self.tool_selection_id, self.result, self.is_error) = (tool_selection_id, result, is_error) }
    }

    /// A span of the answer and its sources; also the shape of a content part.
    public struct Citation: Codable {
        public let start: Int?, end: Int?, text: String?, sources: [JSON]?, type: String?
    }

    public enum Role: String, Codable, LangToolsRole {
        case system, user, assistant, tool

        public init(_ role: any LangToolsRole) {
            self = role.isUser ? .user : role.isSystem ? .system : role.isTool ? .tool : .assistant
        }

        public var isAssistant: Bool { self == .assistant }
        public var isUser: Bool { self == .user }
        public var isSystem: Bool { self == .system }
        public var isTool: Bool { self == .tool }
    }
}
