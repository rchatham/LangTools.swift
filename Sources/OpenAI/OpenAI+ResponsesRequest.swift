//
//  OpenAI+ResponsesRequest.swift
//  OpenAI
//
//  Created by Reid Chatham on 6/24/26.
//

import Foundation
import LangTools

public extension OpenAI {
    func performResponsesRequest(
        messages: [Message],
        model: Model = .gpt4o_mini,
        stream: Bool = false,
        completion: @escaping (Result<OpenAI.ResponsesResponse, Error>) -> Void,
        didCompleteStreaming: ((Error?) -> Void)? = nil
    ) {
        perform(
            request: OpenAI.ResponsesRequest(model: model, messages: messages, stream: stream),
            completion: completion,
            didCompleteStreaming: didCompleteStreaming
        )
    }

    static func responsesRequest(
        model: any RawRepresentable,
        messages: [any LangToolsMessage],
        tools: [any LangToolsTool]? = nil,
        responseSchema: JSONSchema? = nil,
        toolEventHandler: @escaping (LangToolsToolEvent) -> Void = { _ in }
    ) throws -> ResponsesRequest {
        guard let model = model as? Model else { throw LangToolsError.invalidArgument("Unsupported model \(model)") }
        var request = ResponsesRequest(
            model: model,
            messages: messages.map { Message($0) },
            tools: tools?.map { Tool($0) },
            toolEventHandler: toolEventHandler
        )
        request.responseSchema = responseSchema
        return request
    }
}

extension OpenAI {
    public struct ResponsesRequest: Codable, LangToolsChatRequest, LangToolsStreamableRequest, LangToolsToolCallingRequest, LangToolsStructuredOutputRequest, LangToolsResponseUpdatingRequest {
        public typealias LangTool = OpenAI
        public typealias Response = ResponsesResponse
        public static var endpoint: String { "responses" }

        public let model: Model
        public var messages: [Message]
        public var stream: Bool?
        public let instructions: String?
        public let previous_response_id: String?
        public let max_output_tokens: Int?
        public let temperature: Double?
        public let top_p: Double?
        public let tools: [Tool]?
        public let tool_choice: ToolChoice?
        public let parallel_tool_calls: Bool?
        public var text: TextConfig?
        public let metadata: [String: String]?

        @CodableIgnored
        public var toolEventHandler: ((LangToolsToolEvent) -> Void)?

        public var responseSchema: JSONSchema? {
            get { text?.format.schema }
            set { text = newValue.map { TextConfig(schema: $0) } }
        }

        public var usesStructuredOutput: Bool { responseSchema != nil }

        public init(model: OpenAIModel, messages: [any LangToolsMessage]) {
            self.init(model: model, messages: messages.map { Message($0) })
        }

        public init(
            model: Model,
            messages: [Message],
            stream: Bool? = nil,
            instructions: String? = nil,
            previous_response_id: String? = nil,
            max_output_tokens: Int? = nil,
            temperature: Double? = nil,
            top_p: Double? = nil,
            tools: [Tool]? = nil,
            tool_choice: ToolChoice? = nil,
            parallel_tool_calls: Bool? = nil,
            text: TextConfig? = nil,
            metadata: [String: String]? = nil,
            toolEventHandler: @escaping (LangToolsToolEvent) -> Void = { _ in }
        ) {
            self.model = model
            self.messages = messages
            self.stream = stream
            self.instructions = instructions
            self.previous_response_id = previous_response_id
            self.max_output_tokens = max_output_tokens
            self.temperature = temperature
            self.top_p = top_p
            self.tools = tools
            self.tool_choice = tool_choice
            self.parallel_tool_calls = parallel_tool_calls
            self.text = text
            self.metadata = metadata
            self.toolEventHandler = toolEventHandler
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            model = try container.decode(Model.self, forKey: .model)
            messages = []
            stream = try container.decodeIfPresent(Bool.self, forKey: .stream)
            instructions = try container.decodeIfPresent(String.self, forKey: .instructions)
            previous_response_id = try container.decodeIfPresent(String.self, forKey: .previous_response_id)
            max_output_tokens = try container.decodeIfPresent(Int.self, forKey: .max_output_tokens)
            temperature = try container.decodeIfPresent(Double.self, forKey: .temperature)
            top_p = try container.decodeIfPresent(Double.self, forKey: .top_p)
            tools = nil
            tool_choice = try container.decodeIfPresent(ToolChoice.self, forKey: .tool_choice)
            parallel_tool_calls = try container.decodeIfPresent(Bool.self, forKey: .parallel_tool_calls)
            text = try container.decodeIfPresent(TextConfig.self, forKey: .text)
            metadata = try container.decodeIfPresent([String: String].self, forKey: .metadata)
            // ResponsesRequest decoding is used for outbound request inspection only.
            // The Responses API input/tools wire format is intentionally not inflated
            // back into OpenAI.Message/OpenAI.Tool models here.
            toolEventHandler = nil
        }

        public func updated(response: Decodable) throws -> Decodable {
            response
        }

        public func responseUpdater() -> (Decodable) throws -> Decodable {
            let streamState = ResponsesStreamState()
            return { response in
                guard let response = response as? ResponsesResponse else { return response }
                return streamState.updating(response)
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(model, forKey: .model)
            try container.encode(responsesInputItems, forKey: .input)
            try container.encodeIfPresent(stream, forKey: .stream)
            try container.encodeIfPresent(combinedInstructions, forKey: .instructions)
            try container.encodeIfPresent(previous_response_id, forKey: .previous_response_id)
            try container.encodeIfPresent(max_output_tokens, forKey: .max_output_tokens)
            try container.encodeIfPresent(temperature, forKey: .temperature)
            try container.encodeIfPresent(top_p, forKey: .top_p)
            try container.encodeIfPresent(tools?.map(ResponsesTool.init), forKey: .tools)
            try container.encodeIfPresent(tool_choice, forKey: .tool_choice)
            try container.encodeIfPresent(parallel_tool_calls, forKey: .parallel_tool_calls)
            try container.encodeIfPresent(text, forKey: .text)
            try container.encodeIfPresent(metadata, forKey: .metadata)
        }

        private var combinedInstructions: String? {
            let messageInstructions = messages
                .filter { $0.role == .system || $0.role == .developer }
                .map(\.content.text)
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            let explicitInstructions = instructions.flatMap { $0.isEmpty ? nil : $0 }
            if let explicitInstructions, !messageInstructions.isEmpty {
                return explicitInstructions + "\n\n" + messageInstructions
            }
            return explicitInstructions ?? (messageInstructions.isEmpty ? nil : messageInstructions)
        }

        private var responsesInputItems: [InputItem] {
            messages.flatMap(InputItem.items(for:))
        }

        enum CodingKeys: String, CodingKey {
            case model, input, stream, instructions, previous_response_id, max_output_tokens
            case temperature, top_p, tools, tool_choice, parallel_tool_calls, text, metadata
        }

        public struct TextConfig: Codable {
            public var format: TextFormat

            public init(schema: JSONSchema) {
                self.format = TextFormat(schema: schema)
            }
        }

        public struct TextFormat: Codable {
            public let type: String
            public let name: String
            public let schema: JSONSchema
            public let strict: Bool

            public init(schema: JSONSchema) {
                self.type = "json_schema"
                self.name = OpenAI.sanitizeStructuredOutputName(schema.title ?? "structured_response")
                self.schema = schema
                self.strict = true
            }
        }

        public enum ToolChoice: Codable {
            case none, auto, required
            case tool(String)

            public func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                case .none:
                    try container.encode("none")
                case .auto:
                    try container.encode("auto")
                case .required:
                    try container.encode("required")
                case .tool(let name):
                    try container.encode(ToolChoiceObject(type: "function", name: name))
                }
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let stringValue = try? container.decode(String.self) {
                    switch stringValue {
                    case "none": self = .none
                    case "auto": self = .auto
                    case "required": self = .required
                    default:
                        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid value for ToolChoice: \(stringValue)")
                    }
                } else {
                    let object = try container.decode(ToolChoiceObject.self)
                    guard object.type == "function" else {
                        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid tool choice type: \(object.type)")
                    }
                    self = .tool(object.name)
                }
            }

            private struct ToolChoiceObject: Codable {
                let type: String
                let name: String
            }
        }

        public struct ResponsesTool: Encodable {
            public let type: String = "function"
            public let name: String
            public let description: String?
            public let parameters: Tool.FunctionSchema.Parameters
            public let strict: Bool?

            public init(_ tool: Tool) {
                self.name = tool.name
                self.description = tool.description
                self.parameters = tool.tool_schema
                self.strict = nil
            }
        }

        public enum InputItem: Encodable {
            case message(role: Message.Role, content: [ContentItem])
            case functionCall(callID: String, name: String, arguments: String)
            case functionCallOutput(callID: String, output: String)

            static func items(for message: Message) -> [InputItem] {
                switch message.role {
                case .system, .developer:
                    return []
                case .user, .assistant:
                    var items: [InputItem] = []
                    let messageContent = (ContentItem.items(for: message.content, role: message.role) ?? [])
                        + ContentItem.refusalItems(for: message.refusal, role: message.role)
                    if !messageContent.isEmpty {
                        items.append(.message(role: message.role, content: messageContent))
                    }
                    items.append(contentsOf: (message.tool_calls ?? []).enumerated().map { offset, toolCall in
                        .functionCall(
                            callID: toolCall.id ?? Self.stableToolCallID(for: toolCall, offset: offset),
                            name: toolCall.name ?? "",
                            arguments: toolCall.arguments
                        )
                    })
                    return items
                case .tool:
                    guard let toolResult = message.toolResult else { return [] }
                    return [.functionCallOutput(callID: toolResult.tool_selection_id, output: toolResult.result)]
                }
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                switch self {
                case .message(let role, let content):
                    try container.encode("message", forKey: .type)
                    try container.encode(role, forKey: .role)
                    try container.encode(content, forKey: .content)
                case .functionCall(let callID, let name, let arguments):
                    try container.encode("function_call", forKey: .type)
                    try container.encode(callID, forKey: .call_id)
                    try container.encode(name, forKey: .name)
                    try container.encode(arguments, forKey: .arguments)
                case .functionCallOutput(let callID, let output):
                    try container.encode("function_call_output", forKey: .type)
                    try container.encode(callID, forKey: .call_id)
                    try container.encode(output, forKey: .output)
                }
            }

            private static func stableToolCallID(for toolCall: Message.ToolCall, offset: Int) -> String {
                "tool_call_\(toolCall.index ?? offset)"
            }

            enum CodingKeys: String, CodingKey { case type, role, content, call_id, name, arguments, output }
        }

        public struct ContentItem: Encodable {
            public let type: String
            public let text: String?
            public let image_url: Message.Content.ImageContent.ImageURL?
            public let refusal: String?

            static func refusalItems(for refusal: String?, role: Message.Role) -> [ContentItem] {
                guard role == .assistant, let refusal, !refusal.isEmpty else { return [] }
                return [ContentItem(type: "refusal", text: nil, image_url: nil, refusal: refusal)]
            }

            static func items(for content: Message.Content, role: Message.Role) -> [ContentItem]? {
                let textType = role == .assistant ? "output_text" : "input_text"
                switch content {
                case .null:
                    return nil
                case .string(let text):
                    return [ContentItem(type: textType, text: text, image_url: nil, refusal: nil)]
                case .array(let parts):
                    return parts.compactMap { part in
                        switch part {
                        case .text(let text): return ContentItem(type: textType, text: text.text, image_url: nil, refusal: nil)
                        case .image(let image): return ContentItem(type: "input_image", text: nil, image_url: image.image_url, refusal: nil)
                        case .refusal(let refusal): return ContentItem(type: "refusal", text: nil, image_url: nil, refusal: refusal.refusal)
                        // Audio/tool-result parts are not valid Responses input
                        // content items in this request encoder and are intentionally omitted.
                        case .toolResult, .audio: return nil
                        }
                    }
                }
            }
        }
    }

    public struct ResponsesResponse: Decodable, LangToolsStreamableChatResponse, LangToolsToolCallingResponse, LangToolsStructuredOutputResponse {
        public typealias Delta = OpenAI.Message.Delta
        public typealias Message = OpenAI.Message
        public typealias ToolSelection = Message.ToolCall

        public var id: String?
        public var object: String?
        public var created_at: Int?
        public var status: String?
        public var model: String?
        public var output: [OutputItem]
        public var usage: Usage?

        private var streamType: String?
        private var outputIndex: Int?
        private var contentIndex: Int?
        private static let maxStreamOutputItems = 4096
        private static let maxStreamContentItems = 4096

        private var item: OutputItem?
        private var textDelta: String?
        private var refusalDelta: String?
        private var argumentsDelta: String?

        public var message: OpenAI.Message? {
            let text = output.compactMap { $0.messageText }.joined()
            let refusal = output.compactMap { $0.messageRefusal }.joined()
            let toolCalls = output.enumerated().compactMap { index, item -> OpenAI.Message.ToolCall? in
                guard item.type == "function_call", !item.isEmptyFunctionCallPlaceholder else { return nil }
                return OpenAI.Message.ToolCall(
                    // Responses stream deltas are keyed by output_index, so preserve
                    // the output-array index rather than renumbering tool calls.
                    index: index,
                    id: item.stableToolCallID(outputIndex: index),
                    type: .function,
                    function: .init(name: item.name ?? "", arguments: item.arguments ?? "")
                )
            }
            let messageRefusal = refusal.isEmpty ? nil : refusal
            if !toolCalls.isEmpty {
                return try? OpenAI.Message(role: .assistant, content: text.isEmpty ? .null : .string(text), name: nil, tool_calls: toolCalls, audio: nil, refusal: messageRefusal)
            }
            guard !text.isEmpty || messageRefusal != nil else { return nil }
            return try? OpenAI.Message(role: .assistant, content: text.isEmpty ? .null : .string(text), name: nil, tool_calls: nil, audio: nil, refusal: messageRefusal)
        }

        public var delta: OpenAI.Message.Delta? {
            if let textDelta { return .init(role: .assistant, content: textDelta, tool_calls: nil, audio: nil, refusal: nil) }
            if let refusalDelta { return .init(role: .assistant, content: nil, tool_calls: nil, audio: nil, refusal: refusalDelta) }
            if streamType == "response.output_item.added", let item, item.type == "function_call" {
                let index = outputIndex ?? 0
                return .init(
                    role: .assistant,
                    content: nil,
                    tool_calls: [OpenAI.Message.ToolCall(
                        index: index,
                        id: item.stableToolCallID(outputIndex: index),
                        type: .function,
                        function: .init(name: item.name ?? "", arguments: item.arguments ?? "")
                    )],
                    audio: nil,
                    refusal: nil
                )
            }
            if let argumentsDelta {
                let index = outputIndex ?? 0
                let existing = item
                return .init(
                    role: .assistant,
                    content: nil,
                    tool_calls: [OpenAI.Message.ToolCall(
                        index: index,
                        id: existing?.stableToolCallID(outputIndex: index) ?? "",
                        type: .function,
                        function: .init(name: existing?.name ?? "", arguments: argumentsDelta)
                    )],
                    audio: nil,
                    refusal: nil
                )
            }
            return nil
        }

        public var jsonContent: String? { output.compactMap { $0.messageText }.first }

        public static var empty: ResponsesResponse {
            ResponsesResponse(id: nil, object: nil, created_at: nil, status: nil, model: nil, output: [], usage: nil)
        }

        public init(id: String?, object: String?, created_at: Int?, status: String?, model: String?, output: [OutputItem], usage: Usage?) {
            self.id = id
            self.object = object
            self.created_at = created_at
            self.status = status
            self.model = model
            self.output = output
            self.usage = usage
            self.streamType = nil
            self.outputIndex = nil
            self.contentIndex = nil
            self.item = nil
            self.textDelta = nil
            self.refusalDelta = nil
            self.argumentsDelta = nil
        }

        private init(streamType: String, outputIndex: Int?, contentIndex: Int?, item: OutputItem?, textDelta: String?, refusalDelta: String?, argumentsDelta: String?, response: ResponsesResponse?) {
            self.id = response?.id
            self.object = response?.object
            self.created_at = response?.created_at
            self.status = response?.status
            self.model = response?.model
            self.output = response?.output ?? []
            self.usage = response?.usage
            self.streamType = streamType
            self.outputIndex = outputIndex
            self.contentIndex = contentIndex
            self.item = item
            self.textDelta = textDelta
            self.refusalDelta = refusalDelta
            self.argumentsDelta = argumentsDelta
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decodeIfPresent(String.self, forKey: .type)
            if type == "response.output_text.delta" || type == "response.refusal.delta" {
                let delta = try container.decodeIfPresent(String.self, forKey: .delta)
                self.init(
                    streamType: type ?? "",
                    outputIndex: try container.decodeIfPresent(Int.self, forKey: .output_index),
                    contentIndex: try container.decodeIfPresent(Int.self, forKey: .content_index),
                    item: nil,
                    textDelta: type == "response.output_text.delta" ? delta : nil,
                    refusalDelta: type == "response.refusal.delta" ? delta : nil,
                    argumentsDelta: nil,
                    response: nil
                )
                return
            }
            if type == "response.function_call_arguments.delta" {
                self.init(
                    streamType: type ?? "",
                    outputIndex: try container.decodeIfPresent(Int.self, forKey: .output_index),
                    contentIndex: nil,
                    item: nil,
                    textDelta: nil,
                    refusalDelta: nil,
                    argumentsDelta: try container.decodeIfPresent(String.self, forKey: .delta),
                    response: nil
                )
                return
            }
            if type == "response.output_item.added" {
                self.init(
                    streamType: type ?? "",
                    outputIndex: try container.decodeIfPresent(Int.self, forKey: .output_index),
                    contentIndex: nil,
                    item: try container.decodeIfPresent(OutputItem.self, forKey: .item),
                    textDelta: nil,
                    refusalDelta: nil,
                    argumentsDelta: nil,
                    response: nil
                )
                return
            }
            if type == "response.completed" {
                self.init(
                    streamType: type ?? "",
                    outputIndex: nil,
                    contentIndex: nil,
                    item: nil,
                    textDelta: nil,
                    refusalDelta: nil,
                    argumentsDelta: nil,
                    response: try container.decodeIfPresent(ResponsesResponse.self, forKey: .response)
                )
                return
            }

            self.init(
                id: try container.decodeIfPresent(String.self, forKey: .id),
                object: try container.decodeIfPresent(String.self, forKey: .object),
                created_at: try container.decodeIfPresent(Int.self, forKey: .created_at),
                status: try container.decodeIfPresent(String.self, forKey: .status),
                model: try container.decodeIfPresent(String.self, forKey: .model),
                output: try container.decodeIfPresent([OutputItem].self, forKey: .output) ?? [],
                usage: try container.decodeIfPresent(Usage.self, forKey: .usage)
            )
            streamType = type
            outputIndex = try container.decodeIfPresent(Int.self, forKey: .output_index)
            contentIndex = try container.decodeIfPresent(Int.self, forKey: .content_index)
            item = try container.decodeIfPresent(OutputItem.self, forKey: .item)
            textDelta = nil
            refusalDelta = nil
            argumentsDelta = nil
        }

        public func combining(with next: ResponsesResponse) -> ResponsesResponse {
            if output.isEmpty, id == nil, next.streamType == nil { return next }
            if next.streamType == "response.completed", next.hasCompletedResponsePayload { return next }

            var combined = ResponsesResponse(
                id: next.id ?? id,
                object: next.object ?? object,
                created_at: next.created_at ?? created_at,
                status: next.status ?? status,
                model: next.model ?? model,
                output: output,
                usage: next.usage ?? usage
            )

            if next.streamType == "response.output_item.added", let item = next.item {
                let index = next.outputIndex ?? combined.output.count
                combined.setOutputItem(item, at: index)
            } else if let delta = next.textDelta {
                let outputIndex = next.outputIndex ?? 0
                let contentIndex = next.contentIndex ?? 0
                combined.appendText(delta, outputIndex: outputIndex, contentIndex: contentIndex)
            } else if let delta = next.refusalDelta {
                let outputIndex = next.outputIndex ?? 0
                let contentIndex = next.contentIndex ?? 0
                combined.appendRefusal(delta, outputIndex: outputIndex, contentIndex: contentIndex)
            } else if let delta = next.argumentsDelta {
                let outputIndex = next.outputIndex ?? 0
                combined.appendArguments(delta, outputIndex: outputIndex)
            }
            return combined
        }

        private mutating func setOutputItem(_ item: OutputItem, at index: Int) {
            guard Self.isValidOutputIndex(index) else { return }
            while output.count <= index { output.append(.emptyMessage) }
            output[index] = item
        }

        private mutating func appendText(_ text: String, outputIndex: Int, contentIndex: Int) {
            guard Self.isValidOutputIndex(outputIndex), Self.isValidContentIndex(contentIndex) else { return }
            while output.count <= outputIndex { output.append(.emptyMessage) }
            output[outputIndex].appendText(text, contentIndex: contentIndex)
        }

        private mutating func appendRefusal(_ refusal: String, outputIndex: Int, contentIndex: Int) {
            guard Self.isValidOutputIndex(outputIndex), Self.isValidContentIndex(contentIndex) else { return }
            while output.count <= outputIndex { output.append(.emptyMessage) }
            output[outputIndex].appendRefusal(refusal, contentIndex: contentIndex)
        }

        private mutating func appendArguments(_ arguments: String, outputIndex: Int) {
            guard Self.isValidOutputIndex(outputIndex) else { return }
            while output.count <= outputIndex { output.append(.emptyFunctionCall) }
            output[outputIndex].appendArguments(arguments)
        }

        private static func isValidOutputIndex(_ index: Int) -> Bool {
            index >= 0 && index < maxStreamOutputItems
        }

        private static func isValidContentIndex(_ index: Int) -> Bool {
            index >= 0 && index < maxStreamContentItems
        }

        public struct Usage: Codable {
            public let input_tokens: Int?
            public let output_tokens: Int?
            public let total_tokens: Int?
        }

        public struct OutputItem: Decodable {
            public var id: String?
            public var type: String
            public var status: String?
            public var role: OpenAI.Message.Role?
            public var content: [ContentItem]?
            public var call_id: String?
            public var name: String?
            public var arguments: String?
            public var output: String?

            static var emptyMessage: OutputItem {
                OutputItem(id: nil, type: "message", status: nil, role: .assistant, content: [], call_id: nil, name: nil, arguments: nil, output: nil)
            }

            static var emptyFunctionCall: OutputItem {
                OutputItem(id: nil, type: "function_call", status: nil, role: nil, content: nil, call_id: nil, name: nil, arguments: "", output: nil)
            }

            var messageText: String? {
                // Initial Responses support surfaces assistant message text/refusals and
                // function calls. Other output item types (reasoning, web/file search,
                // etc.) are decoded for forward compatibility but intentionally ignored
                // by the LangTools chat-message projection until first-class models exist.
                guard type == "message" else { return nil }
                return content?.compactMap(\.text).joined()
            }

            var messageRefusal: String? {
                guard type == "message" else { return nil }
                return content?.compactMap(\.refusal).joined()
            }

            var isEmptyFunctionCallPlaceholder: Bool {
                type == "function_call" && id == nil && call_id == nil && (name ?? "").isEmpty && (arguments ?? "").isEmpty
            }

            func stableToolCallID(outputIndex: Int) -> String {
                call_id ?? id ?? "response_function_call_\(outputIndex)"
            }

            mutating func appendText(_ text: String, contentIndex: Int) {
                if content == nil { content = [] }
                while content!.count <= contentIndex { content!.append(.outputText("")) }
                content![contentIndex].text = (content![contentIndex].text ?? "") + text
            }

            mutating func appendRefusal(_ refusal: String, contentIndex: Int) {
                if content == nil { content = [] }
                while content!.count <= contentIndex { content!.append(.refusal("")) }
                content![contentIndex].refusal = (content![contentIndex].refusal ?? "") + refusal
            }

            mutating func appendArguments(_ delta: String) {
                type = "function_call"
                arguments = (arguments ?? "") + delta
            }
        }

        public struct ContentItem: Decodable {
            public var type: String
            public var text: String?
            public var refusal: String?

            static func outputText(_ text: String) -> ContentItem {
                ContentItem(type: "output_text", text: text, refusal: nil)
            }

            static func refusal(_ refusal: String) -> ContentItem {
                ContentItem(type: "refusal", text: nil, refusal: refusal)
            }
        }

        private var hasCompletedResponsePayload: Bool {
            streamType == "response.completed" && (id != nil || object != nil || created_at != nil || status != nil || model != nil || !output.isEmpty || usage != nil)
        }

        fileprivate var startsNewOutputStream: Bool {
            streamType == "response.output_item.added" && outputIndex == 0
        }

        fileprivate var endsOutputStream: Bool {
            streamType == "response.completed"
        }

        fileprivate var streamFunctionCallMetadata: (Int, OutputItem)? {
            guard streamType == "response.output_item.added",
                  let outputIndex,
                  let item,
                  item.type == "function_call" else { return nil }
            return (outputIndex, item)
        }

        fileprivate var streamArgumentsOutputIndex: Int? {
            guard argumentsDelta != nil else { return nil }
            return outputIndex
        }

        fileprivate mutating func applyStreamFunctionCallMetadata(_ item: OutputItem) {
            guard argumentsDelta != nil else { return }
            self.item = item
        }

        enum CodingKeys: String, CodingKey {
            case id, object, created_at, status, model, output, usage, type
            case output_index, content_index, item, delta, response
        }
    }

    private final class ResponsesStreamState {
        // One ResponsesStreamState is created per stream invocation by
        // ResponsesRequest.responseUpdater(), so function-call metadata is scoped to
        // that stream instead of being shared by copied/reused request values.
        private var functionCallsByOutputIndex: [Int: ResponsesResponse.OutputItem] = [:]

        func updating(_ response: ResponsesResponse) -> ResponsesResponse {
            var response = response
            if response.startsNewOutputStream || response.endsOutputStream {
                functionCallsByOutputIndex.removeAll()
            }
            if let (outputIndex, item) = response.streamFunctionCallMetadata {
                functionCallsByOutputIndex[outputIndex] = item
            }
            if let outputIndex = response.streamArgumentsOutputIndex,
               let item = functionCallsByOutputIndex[outputIndex] {
                response.applyStreamFunctionCallMetadata(item)
            }
            return response
        }
    }
}

public extension OpenAI {
    // This parser intentionally applies to every OpenAI streaming endpoint so
    // shared SSE framing lines are handled consistently across request types.
    // It lives with Responses because Responses adds event-prefixed SSE frames;
    // existing chat-completion streams continue through the same parser.
    static func decodeStream<T: Decodable>(_ buffer: String) throws -> T? {
        if buffer.hasPrefix("event:") { return nil }
        return if buffer.hasPrefix("data:"),
                  !buffer.contains("[DONE]"),
                  let data = buffer.dropFirst(5).trimmingCharacters(in: .whitespaces).data(using: .utf8) {
            try Self.decodeResponse(data: data)
        } else { nil }
    }
}

private extension OpenAI {
    static func sanitizeStructuredOutputName(_ name: String) -> String {
        let cleaned = name
            .unicodeScalars
            .map { CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-")).contains($0) ? Character($0) : "_" }
            .map(String.init)
            .joined()
        let truncated = String(cleaned.prefix(64))
        return truncated.isEmpty ? "structured_response" : truncated
    }
}

private extension OpenAI.Message.Content {
    var text: String {
        switch self {
        case .null: return ""
        case .string(let text): return text
        case .array(let parts):
            return parts.compactMap { part in
                if case .text(let text) = part { return text.text }
                return nil
            }.joined()
        }
    }
}
