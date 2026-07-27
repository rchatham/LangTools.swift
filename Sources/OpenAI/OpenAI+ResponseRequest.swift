//
//  OpenAI+ResponseRequest.swift
//  OpenAI
//
//  OpenAI Responses API — https://platform.openai.com/docs/api-reference/responses
//

import Foundation
import LangTools


public extension OpenAI {
    /// Convenience for performing a Responses API request with a closure-based completion.
    func performResponseRequest(messages: [Item], model: Model = .gpt4o_mini, stream: Bool = false, completion: @escaping (Result<OpenAI.ResponseResponse, Error>) -> Void, didCompleteStreaming: ((Error?) -> Void)? = nil) {
        perform(request: OpenAI.ResponseRequest(model: model, messages: messages, stream: stream), completion: completion, didCompleteStreaming: didCompleteStreaming)
    }

    /// A request to the Responses API (`POST /v1/responses`).
    struct ResponseRequest: Codable, LangToolsChatRequest, LangToolsStreamableRequest, LangToolsToolCallingRequest, LangToolsStructuredOutputRequest {
        public typealias LangTool = OpenAI
        public typealias Response = ResponseResponse
        public static var endpoint: String { "responses" }

        public let model: Model
        /// The conversation, sent on the wire as `input`.
        public var messages: [Item]
        /// A system/developer message inserted into the model's context.
        public var instructions: String?
        public var tools: [Tool]?
        public var tool_choice: ToolChoice?
        public var temperature: Double?
        public var top_p: Double?
        public var max_output_tokens: Int?
        public var top_logprobs: Int?
        public var parallel_tool_calls: Bool?
        /// The id of a previous response to continue from (server-side conversation state).
        public var previous_response_id: String?
        public var store: Bool?
        public var stream: Bool?
        public var reasoning: Reasoning?
        public var text: TextConfig?
        public var metadata: [String: String]?
        public var include: [String]?
        public var truncation: String?
        public var user: String?

        public var toolEventHandler: ((LangToolsToolEvent) -> Void)?

        // MARK: - LangToolsStructuredOutputRequest

        /// The response schema for structured output. Setting it configures `text.format`
        /// to use the `json_schema` type with strict mode enabled.
        public var responseSchema: JSONSchema? {
            get {
                if case .json_schema(let format)? = text?.format { return format.schema }
                return nil
            }
            set {
                if let schema = newValue {
                    text = TextConfig(format: .json_schema(.init(
                        name: schema.title ?? "structured_response",
                        schema: schema,
                        strict: true)))
                } else if case .json_schema? = text?.format {
                    text = nil
                }
            }
        }

        /// Returns `true` when the request is configured with a structured output schema.
        public var usesStructuredOutput: Bool { responseSchema != nil }

        // MARK: - Initializers

        public init(model: Model, messages: [any LangToolsMessage]) {
            self.init(model: model, messages: messages.map { Item($0) })
        }

        public init(model: Model, messages: [Item], instructions: String? = nil, tools: [Tool]? = nil, tool_choice: ToolChoice? = nil, temperature: Double? = nil, top_p: Double? = nil, max_output_tokens: Int? = nil, top_logprobs: Int? = nil, parallel_tool_calls: Bool? = nil, previous_response_id: String? = nil, store: Bool? = nil, stream: Bool? = nil, reasoning: Reasoning? = nil, text: TextConfig? = nil, metadata: [String: String]? = nil, include: [String]? = nil, truncation: String? = nil, user: String? = nil, toolEventHandler: @escaping (LangToolsToolEvent) -> Void = { _ in }) {
            self.model = model
            self.messages = messages
            self.instructions = instructions
            self.tools = tools
            self.tool_choice = tool_choice
            self.temperature = temperature
            self.top_p = top_p
            self.max_output_tokens = max_output_tokens
            self.top_logprobs = top_logprobs
            self.parallel_tool_calls = parallel_tool_calls
            self.previous_response_id = previous_response_id
            self.store = store
            self.stream = stream
            self.reasoning = reasoning
            self.text = text
            self.metadata = metadata
            self.include = include
            self.truncation = truncation
            self.user = user
            self.toolEventHandler = toolEventHandler
        }

        // MARK: - Codable

        enum CodingKeys: String, CodingKey {
            case model, input, instructions, tools, tool_choice, temperature, top_p
            case max_output_tokens, top_logprobs, parallel_tool_calls, previous_response_id
            case store, stream, reasoning, text, metadata, include, truncation, user
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            model = try container.decode(Model.self, forKey: .model)
            if let string = try? container.decode(String.self, forKey: .input) {
                messages = [Item(role: .user, content: .string(string))]
            } else {
                // decodeIfPresent (not try?) so a malformed item surfaces an error rather than
                // silently discarding the whole conversation; absent `input` tolerates to [].
                messages = try container.decodeIfPresent([Item].self, forKey: .input) ?? []
            }
            instructions = try container.decodeIfPresent(String.self, forKey: .instructions)
            tools = try container.decodeIfPresent([Tool].self, forKey: .tools)
            tool_choice = try container.decodeIfPresent(ToolChoice.self, forKey: .tool_choice)
            temperature = try container.decodeIfPresent(Double.self, forKey: .temperature)
            top_p = try container.decodeIfPresent(Double.self, forKey: .top_p)
            max_output_tokens = try container.decodeIfPresent(Int.self, forKey: .max_output_tokens)
            top_logprobs = try container.decodeIfPresent(Int.self, forKey: .top_logprobs)
            parallel_tool_calls = try container.decodeIfPresent(Bool.self, forKey: .parallel_tool_calls)
            previous_response_id = try container.decodeIfPresent(String.self, forKey: .previous_response_id)
            store = try container.decodeIfPresent(Bool.self, forKey: .store)
            stream = try container.decodeIfPresent(Bool.self, forKey: .stream)
            reasoning = try container.decodeIfPresent(Reasoning.self, forKey: .reasoning)
            text = try container.decodeIfPresent(TextConfig.self, forKey: .text)
            metadata = try container.decodeIfPresent([String: String].self, forKey: .metadata)
            include = try container.decodeIfPresent([String].self, forKey: .include)
            truncation = try container.decodeIfPresent(String.self, forKey: .truncation)
            user = try container.decodeIfPresent(String.self, forKey: .user)
            toolEventHandler = nil
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(model, forKey: .model)

            // `input` is a heterogeneous array: assistant tool calls and tool results are
            // flattened into their own `function_call` / `function_call_output` items.
            var input = container.nestedUnkeyedContainer(forKey: .input)
            for item in messages {
                if let tool_calls = item.tool_calls, !tool_calls.isEmpty {
                    // An assistant turn may carry text (string or multipart) alongside its tool
                    // calls; emit it as its own message item so it is preserved in the conversation.
                    if Item.hasEncodableContent(item.content) {
                        var mc = input.nestedContainer(keyedBy: Item.MessageKeys.self)
                        try mc.encode(item.role, forKey: .role)
                        try Item.encodeContent(item.content, into: &mc)
                    }
                    for call in tool_calls {
                        var c = input.nestedContainer(keyedBy: Item.FunctionCallKeys.self)
                        try c.encode("function_call", forKey: .type)
                        try c.encodeIfPresent(call.id, forKey: .call_id)
                        try c.encodeIfPresent(call.name, forKey: .name)
                        try c.encode(call.arguments, forKey: .arguments)
                    }
                } else if let toolResult = item.toolResult {
                    var c = input.nestedContainer(keyedBy: Item.FunctionCallKeys.self)
                    try c.encode("function_call_output", forKey: .type)
                    try c.encode(toolResult.tool_selection_id, forKey: .call_id)
                    try c.encode(toolResult.result, forKey: .output)
                } else {
                    var c = input.nestedContainer(keyedBy: Item.MessageKeys.self)
                    try c.encode(item.role, forKey: .role)
                    try Item.encodeContent(item.content, into: &c)
                }
            }

            try container.encodeIfPresent(instructions, forKey: .instructions)
            try container.encodeIfPresent(tools, forKey: .tools)
            try container.encodeIfPresent(tool_choice, forKey: .tool_choice)
            try container.encodeIfPresent(temperature, forKey: .temperature)
            try container.encodeIfPresent(top_p, forKey: .top_p)
            try container.encodeIfPresent(max_output_tokens, forKey: .max_output_tokens)
            try container.encodeIfPresent(top_logprobs, forKey: .top_logprobs)
            try container.encodeIfPresent(parallel_tool_calls, forKey: .parallel_tool_calls)
            try container.encodeIfPresent(previous_response_id, forKey: .previous_response_id)
            try container.encodeIfPresent(store, forKey: .store)
            try container.encodeIfPresent(stream, forKey: .stream)
            try container.encodeIfPresent(reasoning, forKey: .reasoning)
            try container.encodeIfPresent(text, forKey: .text)
            try container.encodeIfPresent(metadata, forKey: .metadata)
            try container.encodeIfPresent(include, forKey: .include)
            try container.encodeIfPresent(truncation, forKey: .truncation)
            try container.encodeIfPresent(user, forKey: .user)
        }

        // MARK: - Reasoning

        public struct Reasoning: Codable {
            public var effort: Effort?
            public var summary: Summary?

            public init(effort: Effort? = nil, summary: Summary? = nil) {
                self.effort = effort
                self.summary = summary
            }

            public enum Effort: String, Codable { case minimal, low, medium, high, xhigh }
            public enum Summary: String, Codable { case auto, concise, detailed }
        }

        // MARK: - Text / structured output configuration

        public struct TextConfig: Codable {
            public var format: Format

            public init(format: Format) { self.format = format }

            public enum Format: Codable {
                case text
                case json_object
                case json_schema(JSONSchemaFormat)

                public struct JSONSchemaFormat: Codable {
                    public let name: String
                    public let schema: JSONSchema
                    public let strict: Bool

                    public init(name: String, schema: JSONSchema, strict: Bool = true) {
                        self.name = OpenAI.sanitizeSchemaName(name)
                        self.schema = schema
                        self.strict = strict
                    }
                }

                enum CodingKeys: String, CodingKey { case type, name, schema, strict }

                public init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    switch try container.decode(String.self, forKey: .type) {
                    case "text": self = .text
                    case "json_object": self = .json_object
                    case "json_schema":
                        self = .json_schema(.init(
                            name: try container.decode(String.self, forKey: .name),
                            schema: try container.decode(JSONSchema.self, forKey: .schema),
                            strict: try container.decodeIfPresent(Bool.self, forKey: .strict) ?? true))
                    case let type:
                        throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown text.format type: \(type)")
                    }
                }

                public func encode(to encoder: Encoder) throws {
                    var container = encoder.container(keyedBy: CodingKeys.self)
                    switch self {
                    case .text:
                        try container.encode("text", forKey: .type)
                    case .json_object:
                        try container.encode("json_object", forKey: .type)
                    case .json_schema(let format):
                        // The Responses API flattens name/schema/strict alongside `type`.
                        try container.encode("json_schema", forKey: .type)
                        try container.encode(format.name, forKey: .name)
                        try container.encode(format.schema, forKey: .schema)
                        try container.encode(format.strict, forKey: .strict)
                    }
                }
            }
        }

        // MARK: - Tool choice

        public enum ToolChoice: Codable {
            case none, auto, required
            case function(name: String)
            /// Forces a hosted tool by its type, e.g. `.hostedTool("file_search")` or
            /// `.hostedTool("web_search")` — encoded as `{"type": "<type>"}` with no name.
            case hostedTool(String)

            enum CodingKeys: String, CodingKey { case type, name }

            public init(from decoder: Decoder) throws {
                if let container = try? decoder.singleValueContainer(), let string = try? container.decode(String.self) {
                    switch string {
                    case "none": self = .none
                    case "auto": self = .auto
                    case "required": self = .required
                    default: throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid tool_choice: \(string)")
                    }
                    return
                }
                let container = try decoder.container(keyedBy: CodingKeys.self)
                let type = try container.decode(String.self, forKey: .type)
                if type == "function" {
                    let name = try container.decode(String.self, forKey: .name)
                    self = .function(name: name)
                } else {
                    self = .hostedTool(type)
                }
            }

            public func encode(to encoder: Encoder) throws {
                switch self {
                case .none:
                    var container = encoder.singleValueContainer()
                    try container.encode("none")
                case .auto:
                    var container = encoder.singleValueContainer()
                    try container.encode("auto")
                case .required:
                    var container = encoder.singleValueContainer()
                    try container.encode("required")
                case .function(let name):
                    var container = encoder.container(keyedBy: CodingKeys.self)
                    try container.encode("function", forKey: .type)
                    try container.encode(name, forKey: .name)
                case .hostedTool(let type):
                    var container = encoder.container(keyedBy: CodingKeys.self)
                    try container.encode(type, forKey: .type)
                }
            }
        }

        // MARK: - Tool

        /// A tool the model may call. Function tools support the LangTools callback-based
        /// tool-calling loop; the hosted tools (`web_search`, `file_search`, …) are server-side.
        public enum Tool: Codable, LangToolsTool {
            public typealias ToolSchema = OpenAI.Tool.FunctionSchema.Parameters

            case function(Function)
            case webSearch
            case webSearchPreview
            case fileSearch(vectorStoreIDs: [String])
            case codeInterpreter
            case imageGeneration

            public struct Function {
                public var name: String
                public var description: String?
                public var parameters: ToolSchema
                public var strict: Bool?
                public var callback: ((LangToolsRequestInfo, [String: JSON]) async throws -> String?)?

                public init(name: String, description: String? = nil, parameters: ToolSchema = .init(), strict: Bool? = nil, callback: ((LangToolsRequestInfo, [String: JSON]) async throws -> String?)? = nil) {
                    self.name = name
                    self.description = description
                    self.parameters = parameters
                    self.strict = strict
                    self.callback = callback
                }
            }

            // LangToolsTool conformance
            public init(name: String, description: String?, tool_schema: ToolSchema, callback: ((LangToolsRequestInfo, [String: JSON]) async throws -> String?)?) {
                self = .function(.init(name: name, description: description, parameters: tool_schema, callback: callback))
            }

            public var name: String {
                switch self {
                case .function(let f): return f.name
                case .webSearch: return "web_search"
                case .webSearchPreview: return "web_search_preview"
                case .fileSearch: return "file_search"
                case .codeInterpreter: return "code_interpreter"
                case .imageGeneration: return "image_generation"
                }
            }

            public var description: String? {
                if case .function(let f) = self { return f.description }; return nil
            }

            public var tool_schema: ToolSchema {
                if case .function(let f) = self { return f.parameters }; return .init()
            }

            public var callback: ((LangToolsRequestInfo, [String: JSON]) async throws -> String?)? {
                if case .function(let f) = self { return f.callback }; return nil
            }

            enum CodingKeys: String, CodingKey { case type, name, description, parameters, strict, vector_store_ids }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                switch try container.decode(String.self, forKey: .type) {
                case "function":
                    self = .function(.init(
                        name: try container.decode(String.self, forKey: .name),
                        description: try container.decodeIfPresent(String.self, forKey: .description),
                        parameters: try container.decodeIfPresent(ToolSchema.self, forKey: .parameters) ?? .init(),
                        strict: try container.decodeIfPresent(Bool.self, forKey: .strict),
                        callback: nil))
                case "web_search": self = .webSearch
                case "web_search_preview": self = .webSearchPreview
                case "file_search": self = .fileSearch(vectorStoreIDs: try container.decodeIfPresent([String].self, forKey: .vector_store_ids) ?? [])
                case "code_interpreter": self = .codeInterpreter
                case "image_generation": self = .imageGeneration
                case let type:
                    throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown tool type: \(type)")
                }
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                switch self {
                case .function(let f):
                    try container.encode("function", forKey: .type)
                    try container.encode(f.name, forKey: .name)
                    try container.encodeIfPresent(f.description, forKey: .description)
                    try container.encode(f.parameters, forKey: .parameters)
                    try container.encodeIfPresent(f.strict, forKey: .strict)
                case .webSearch:
                    try container.encode("web_search", forKey: .type)
                case .webSearchPreview:
                    try container.encode("web_search_preview", forKey: .type)
                case .fileSearch(let ids):
                    try container.encode("file_search", forKey: .type)
                    try container.encode(ids, forKey: .vector_store_ids)
                case .codeInterpreter:
                    try container.encode("code_interpreter", forKey: .type)
                case .imageGeneration:
                    try container.encode("image_generation", forKey: .type)
                }
            }
        }
    }
}
