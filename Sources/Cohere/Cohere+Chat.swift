//
//  Cohere+Chat.swift
//  LangTools
//
//  Cohere's native v2 Chat API (`POST /v2/chat`), served beside the
//  Compatibility API. It adds what the OpenAI format cannot carry: grounding
//  documents with citations, tool plans, and thinking budgets.
//

import Foundation
import LangTools
import OpenAI
import OpenAICompatible

extension Cohere {
    /// Builds a native v2 chat request; `chatRequest` builds a Compatibility
    /// API request.
    public static func nativeChatRequest(model: Model, messages: [any LangToolsMessage], tools: [any LangToolsTool]? = nil, responseSchema: JSONSchema? = nil, toolEventHandler: @escaping (LangToolsToolEvent) -> Void = { _ in }) -> ChatRequest {
        var request = ChatRequest(model: model, messages: messages.map { Message($0) }, tools: tools?.map { OpenAI.Tool($0) }, toolEventHandler: toolEventHandler)
        request.responseSchema = responseSchema
        return request
    }

    public struct ChatRequest: Codable, LangToolsChatRequest, LangToolsStreamableRequest, LangToolsToolCallingRequest, LangToolsStructuredOutputRequest {
        public typealias Response = ChatResponse
        public typealias LangTool = Cohere
        /// Relative to `Cohere.nativeBaseURL`.
        public static var endpoint: String { "v2/chat" }

        public let model: Model
        public var messages: [Message]
        public var stream: Bool?
        public let tools: [OpenAI.Tool]?
        public let tool_choice: ToolChoice?
        /// Grounding documents: strings, or objects such as `{"id": ..., "data": {...}}`.
        /// The answer cites them in `message.citations`.
        public let documents: [JSON]?
        public let temperature: Double?
        public let max_tokens: Int?
        public let p: Double?
        public let k: Int?
        public let seed: Int?
        public let stop_sequences: [String]?
        public let frequency_penalty: Double?
        public let presence_penalty: Double?
        public let thinking: Thinking?
        public var response_format: ResponseFormat?

        @CodableIgnored
        public var toolEventHandler: ((LangToolsToolEvent) -> Void)?

        public var responseSchema: JSONSchema? {
            get { response_format?.json_schema }
            set { response_format = newValue.map { ResponseFormat(schema: $0) } }
        }

        public init(model: Model, messages: [any LangToolsMessage]) {
            self.init(model: model, messages: messages.map { Message($0) })
        }

        public init(
            model: Model,
            messages: [Message],
            stream: Bool? = nil,
            tools: [OpenAI.Tool]? = nil,
            tool_choice: ToolChoice? = nil,
            documents: [JSON]? = nil,
            temperature: Double? = nil,
            max_tokens: Int? = nil,
            p: Double? = nil,
            k: Int? = nil,
            seed: Int? = nil,
            stop_sequences: [String]? = nil,
            frequency_penalty: Double? = nil,
            presence_penalty: Double? = nil,
            thinking: Thinking? = nil,
            response_format: ResponseFormat? = nil,
            toolEventHandler: ((LangToolsToolEvent) -> Void)? = nil
        ) {
            self.model = model
            self.messages = messages
            self.stream = stream
            self.tools = tools
            self.tool_choice = tool_choice
            self.documents = documents
            self.temperature = temperature
            self.max_tokens = max_tokens
            self.p = p
            self.k = k
            self.seed = seed
            self.stop_sequences = stop_sequences
            self.frequency_penalty = frequency_penalty
            self.presence_penalty = presence_penalty
            self.thinking = thinking
            self.response_format = response_format
            self.toolEventHandler = toolEventHandler
        }

        /// `REQUIRED` forces a tool call; `NONE` forbids one. Omit it to let
        /// the model choose.
        public enum ToolChoice: String, Codable {
            case required = "REQUIRED"
            case none = "NONE"
        }

        public struct Thinking: Codable {
            public let type: String
            public let token_budget: Int?

            public static var disabled: Thinking { Thinking(type: "disabled", token_budget: nil) }
            public static func enabled(tokenBudget: Int? = nil) -> Thinking { Thinking(type: "enabled", token_budget: tokenBudget) }
        }

        /// JSON output, constrained to `json_schema` when one is given.
        public struct ResponseFormat: Codable {
            public let type: String
            public let json_schema: JSONSchema?

            public init(schema: JSONSchema?) {
                type = "json_object"
                json_schema = schema
            }
        }
    }

    public struct ChatResponse: Decodable, LangToolsStreamableChatResponse, LangToolsToolCallingResponse, LangToolsStructuredOutputResponse {
        public typealias Delta = ChatDelta
        public typealias Message = Cohere.Message
        public typealias ToolSelection = ToolCall

        public var id: String?
        /// `COMPLETE`, `STOP_SEQUENCE`, `MAX_TOKENS`, `TOOL_CALL`, `ERROR`, or `TIMEOUT`.
        public var finish_reason: String?
        public var message: Message?
        public var usage: Usage?

        // One streamed event; nil for a complete response.
        private var eventType: String?
        private var eventIndex: Int?
        private var textDelta: String?
        private var toolPlanDelta: String?
        private var toolCallStart: ToolCall?
        private var argumentsDelta: String?
        private var citation: Citation?
        private var eventError: String?

        public var delta: ChatDelta? {
            guard let textDelta else { return nil }
            return ChatDelta(role: .assistant, content: textDelta)
        }

        public var jsonContent: String? { message?.content.text }

        public static var empty: ChatResponse { ChatResponse(id: nil, finish_reason: nil, message: nil, usage: nil) }

        public init(id: String?, finish_reason: String?, message: Message?, usage: Usage?) {
            self.id = id
            self.finish_reason = finish_reason
            self.message = message
            self.usage = usage
        }

        /// Fails on a `message-end` event that reports an error, or a response
        /// that finished with `ERROR`.
        public func validateStreamChunk() throws {
            if let eventError { throw LangToolsError.apiError(OpenAICompatibleErrorResponse(message: eventError)) }
            if finish_reason == "ERROR" {
                throw LangToolsError.apiError(OpenAICompatibleErrorResponse(message: "The response finished with an error", code: finish_reason))
            }
        }

        /// A stream is complete once `message-end` has set `finish_reason`.
        public func validateStreamCompletion() throws {
            guard finish_reason != nil else { throw LangToolsError.incompleteStream }
        }

        public func combining(with next: ChatResponse) -> ChatResponse {
            guard next.eventType != nil else { return next }
            var combined = ChatResponse(id: next.id ?? id, finish_reason: next.finish_reason ?? finish_reason, message: message, usage: next.usage ?? usage)
            var accumulated = combined.message ?? Message(role: .assistant, content: "")
            if let text = next.textDelta { accumulated.content.text += text }
            if let plan = next.toolPlanDelta { accumulated.tool_plan = (accumulated.tool_plan ?? "") + plan }
            if let citation = next.citation { accumulated.citations = (accumulated.citations ?? []) + [citation] }
            if let call = next.toolCallStart {
                var calls = accumulated.tool_calls ?? []
                let index = next.eventIndex ?? calls.count
                if calls.indices.contains(index) { calls[index] = call } else if index == calls.count { calls.append(call) }
                accumulated.tool_calls = calls
            } else if let arguments = next.argumentsDelta, var calls = accumulated.tool_calls {
                let index = next.eventIndex ?? calls.count - 1
                if calls.indices.contains(index) {
                    calls[index].function.arguments += arguments
                    accumulated.tool_calls = calls
                }
            }
            combined.message = accumulated
            return combined
        }

        public struct Usage: Codable {
            public let billed_units: Units?
            public let tokens: Units?

            public struct Units: Codable {
                public let input_tokens: Double?
                public let output_tokens: Double?
            }
        }

        private enum CodingKeys: String, CodingKey { case id, finish_reason, message, usage, type, index, delta }
        private enum DeltaKeys: String, CodingKey { case message, finish_reason, usage, error }
        private enum DeltaMessageKeys: String, CodingKey { case content, tool_plan, tool_calls, citations }
        private enum DeltaContentKeys: String, CodingKey { case text }
        private enum DeltaToolCallKeys: String, CodingKey { case function }
        private enum DeltaFunctionKeys: String, CodingKey { case arguments }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(String.self, forKey: .id)
            guard let type = try container.decodeIfPresent(String.self, forKey: .type) else {
                finish_reason = try container.decodeIfPresent(String.self, forKey: .finish_reason)
                message = try container.decodeIfPresent(Message.self, forKey: .message)
                usage = try container.decodeIfPresent(Usage.self, forKey: .usage)
                return
            }
            eventType = type
            eventIndex = try container.decodeIfPresent(Int.self, forKey: .index)
            guard let delta = try? container.nestedContainer(keyedBy: DeltaKeys.self, forKey: .delta) else { return }
            let deltaMessage = try? delta.nestedContainer(keyedBy: DeltaMessageKeys.self, forKey: .message)
            switch type {
            case "content-delta":
                textDelta = try deltaMessage?.nestedContainer(keyedBy: DeltaContentKeys.self, forKey: .content).decodeIfPresent(String.self, forKey: .text)
            case "tool-plan-delta":
                toolPlanDelta = try deltaMessage?.decodeIfPresent(String.self, forKey: .tool_plan)
            case "tool-call-start":
                toolCallStart = try deltaMessage?.decodeIfPresent(ToolCall.self, forKey: .tool_calls)
            case "tool-call-delta":
                argumentsDelta = try deltaMessage?.nestedContainer(keyedBy: DeltaToolCallKeys.self, forKey: .tool_calls)
                    .nestedContainer(keyedBy: DeltaFunctionKeys.self, forKey: .function)
                    .decodeIfPresent(String.self, forKey: .arguments)
            case "citation-start":
                citation = try deltaMessage?.decodeIfPresent(Citation.self, forKey: .citations)
            case "message-end":
                finish_reason = try delta.decodeIfPresent(String.self, forKey: .finish_reason)
                usage = try delta.decodeIfPresent(Usage.self, forKey: .usage)
                eventError = Self.errorMessage(in: delta)
            default:
                break
            }
        }

        private static func errorMessage(in delta: KeyedDecodingContainer<DeltaKeys>) -> String? {
            if let message = try? delta.decodeIfPresent(String.self, forKey: .error) { return message }
            return (try? delta.decodeIfPresent(OpenAICompatibleErrorResponse.self, forKey: .error))??.message
        }
    }

    public struct ChatDelta: Codable, LangToolsMessageDelta {
        public typealias Role = Cohere.Role
        public let role: Role?
        public let content: String?
    }

    public struct Message: Codable, LangToolsMessage, LangToolsToolMessage {
        public typealias Content = LangToolsTextContent
        public typealias ToolSelection = ToolCall
        public typealias ToolResult = ToolCallResult

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

        public init(role: Role, content: LangToolsTextContent) {
            self.init(role: role, content: content.text)
        }

        public init(role: Role, content: String, tool_plan: String? = nil, tool_calls: [ToolCall]? = nil, tool_call_id: String? = nil) {
            self.role = role
            self.content = LangToolsTextContent(text: content)
            self.tool_plan = tool_plan
            self.tool_calls = tool_calls
            self.tool_call_id = tool_call_id
            self.citations = nil
        }

        public init(tool_selection: [ToolCall]) {
            self.init(role: .assistant, content: "", tool_calls: tool_selection)
        }

        public static func messages(for tool_results: [ToolCallResult]) -> [Message] {
            tool_results.map { Message(role: .tool, content: $0.result, tool_call_id: $0.tool_selection_id) }
        }

        private enum CodingKeys: String, CodingKey { case role, content, tool_plan, tool_calls, tool_call_id, citations }
        private struct ContentPart: Decodable { let type: String; let text: String? }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            role = try container.decode(Role.self, forKey: .role)
            // Content is a string or typed parts; thinking parts are not answer text.
            if let text = try? container.decodeIfPresent(String.self, forKey: .content) {
                content = LangToolsTextContent(text: text)
            } else {
                let parts = try container.decodeIfPresent([ContentPart].self, forKey: .content) ?? []
                content = LangToolsTextContent(text: parts.filter { $0.type == "text" }.compactMap(\.text).joined())
            }
            tool_plan = try container.decodeIfPresent(String.self, forKey: .tool_plan)
            tool_calls = try container.decodeIfPresent([ToolCall].self, forKey: .tool_calls)
            tool_call_id = try container.decodeIfPresent(String.self, forKey: .tool_call_id)
            citations = try? container.decodeIfPresent([Citation].self, forKey: .citations)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(role, forKey: .role)
            // An assistant turn that only calls tools carries no content.
            if !(content.text.isEmpty && tool_calls?.isEmpty == false) {
                try container.encode(content.text, forKey: .content)
            }
            try container.encodeIfPresent(tool_plan, forKey: .tool_plan)
            try container.encodeIfPresent(tool_calls, forKey: .tool_calls)
            try container.encodeIfPresent(tool_call_id, forKey: .tool_call_id)
        }
    }

    public struct ToolCall: Codable, LangToolsToolSelection {
        public let id: String?
        public var type: String
        public var function: Function

        public var name: String? { function.name }
        /// The JSON arguments; Cohere's `"null"` for a call without arguments
        /// reads as empty.
        public var arguments: String { function.arguments == "null" ? "" : function.arguments }

        public init(id: String?, name: String, arguments: String) {
            self.id = id
            type = "function"
            function = Function(name: name, arguments: arguments)
        }

        private enum CodingKeys: String, CodingKey { case id, type, function }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(String.self, forKey: .id)
            type = try container.decodeIfPresent(String.self, forKey: .type) ?? "function"
            function = try container.decode(Function.self, forKey: .function)
        }

        public struct Function: Codable {
            public var name: String
            public var arguments: String

            private enum CodingKeys: String, CodingKey { case name, arguments }

            public init(name: String, arguments: String) {
                self.name = name
                self.arguments = arguments
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                // A streamed tool-call-start carries an empty or missing name
                // only in malformed events; default rather than fail the stream.
                name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
                arguments = try container.decodeIfPresent(String.self, forKey: .arguments) ?? ""
            }
        }
    }

    public struct ToolCallResult: Codable, LangToolsToolSelectionResult {
        public let tool_selection_id: String
        public let result: String
        public var is_error: Bool

        public init(tool_selection_id: String, result: String, is_error: Bool) {
            self.tool_selection_id = tool_selection_id
            self.result = result
            self.is_error = is_error
        }
    }

    /// A span of the answer and the documents or tool results supporting it.
    public struct Citation: Codable {
        public let start: Int?
        public let end: Int?
        public let text: String?
        public let sources: [JSON]?
        public let type: String?
    }

    public enum Role: String, Codable, LangToolsRole {
        case system, user, assistant, tool

        public init(_ role: any LangToolsRole) {
            if role.isUser { self = .user }
            else if role.isSystem { self = .system }
            else if role.isTool { self = .tool }
            else { self = .assistant }
        }

        public var isAssistant: Bool { self == .assistant }
        public var isUser: Bool { self == .user }
        public var isSystem: Bool { self == .system }
        public var isTool: Bool { self == .tool }
    }
}
