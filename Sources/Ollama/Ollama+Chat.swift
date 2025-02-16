import Foundation
import LangTools
import OpenAI

extension Ollama {
    public static func chatRequest(model: Model, messages: [any LangToolsMessage], tools: [any LangToolsTool]?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) throws -> any LangToolsChatRequest {
        return Ollama.ChatRequest(model: model, messages: messages.map { Message($0) }, tools: tools?.map { OpenAI.Tool($0) }, toolEventHandler: toolEventHandler)
    }

    public struct ChatRequest: Codable, LangToolsChatRequest, LangToolsStreamableRequest, LangToolsToolCallingRequest {
        public typealias Response = ChatResponse
        public typealias LangTool = Ollama
        public static var endpoint: String { "api/chat" }

        // Required parameters
        public let model: OllamaModel
        public var messages: [Message]

        // Optional parameters
        public let format: GenerateFormat?
        public let options: GenerateOptions?
        public var stream: Bool?
        public let keep_alive: String?
        public let tools: [OpenAI.Tool]?

        @CodableIgnored
        public var toolEventHandler: ((LangToolsToolEvent) -> Void)?

        public init(model: Ollama.Model, messages: [any LangToolsMessage]) {
            self.model = model
            self.messages = messages.map { Message($0) }

            format = nil
            options = nil
            stream = nil
            keep_alive = nil
            tools = nil
        }

        public init(
            model: OllamaModel,
            messages: [Message],
            format: GenerateFormat? = nil,
            options: GenerateOptions? = nil,
            stream: Bool? = nil,
            keep_alive: String? = nil,
            tools: [OpenAI.Tool]? = nil,
            toolEventHandler: ((LangToolsToolEvent) -> Void)? = nil
        ) {
            self.model = model
            self.messages = messages
            self.format = format
            self.options = options
            self.stream = stream
            self.keep_alive = keep_alive
            self.tools = tools
            self.toolEventHandler = toolEventHandler
        }
    }

    public struct ChatResponse: Codable, LangToolsStreamableResponse, LangToolsToolCallingResponse {
        public typealias Delta = ChatDelta
        public typealias Message = Ollama.Message
        public typealias ToolSelection = Message.ToolSelection

        public let model: String
        public let created_at: String
        public let message: Message?
        public let done: Bool
        public let done_reason: String?
        public let total_duration: Int64?
        public let load_duration: Int64?
        public let prompt_eval_count: Int?
        public let prompt_eval_duration: Int64?
        public let eval_count: Int?
        public let eval_duration: Int64?

        public var delta: ChatDelta? { nil }

        public static var empty: ChatResponse {
            return ChatResponse(
                model: "",
                created_at: "",
                message: nil,
                done: false,
                done_reason: nil,
                total_duration: nil,
                load_duration: nil,
                prompt_eval_count: nil,
                prompt_eval_duration: nil,
                eval_count: nil,
                eval_duration: nil
            )
        }

        public func combining(with next: ChatResponse) -> ChatResponse {
            return ChatResponse(
                model: next.model,
                created_at: next.created_at,
                message: Message(
                    role: next.message?.role ?? message?.role ?? .assistant,
                    content: (message?.content.text ?? "") + (next.message?.content.text ?? ""),
                    images: next.message?.images,
                    tool_calls: next.message?.tool_calls ?? message?.tool_calls
                ),
                done: next.done,
                done_reason: next.done_reason,
                total_duration: next.total_duration,
                load_duration: next.load_duration,
                prompt_eval_count: next.prompt_eval_count,
                prompt_eval_duration: next.prompt_eval_duration,
                eval_count: next.eval_count,
                eval_duration: next.eval_duration
            )
        }
    }

    public struct Message: Codable, LangToolsMessage, LangToolsToolMessage {
        public typealias Content = LangToolsTextContent
        public typealias ToolSelection = ChatToolCall
        public typealias ToolResult = ChatToolResult

        public let role: Role
        // Wrapping in LangToolsTextContent for api consistency.
        public let content: LangToolsTextContent
        public let images: [String]?
        public let tool_calls: [ChatToolCall]?

        public var tool_selection: [ChatToolCall]? { tool_calls }

        public init(role: Role, content: String, images: [String]? = nil, tool_calls: [ChatToolCall]? = nil) {
            self.role = role
            self.content = LangToolsTextContent(text: content)
            self.images = images
            self.tool_calls = tool_calls
        }

        public init(role: Ollama.Role, content: LangToolsTextContent) {
            self.role = role
            self.content = content
            images = nil
            tool_calls = nil
        }

        public init(tool_selection: [ChatToolCall]) {
            self.role = .assistant
            self.content = ""
            self.images = nil
            self.tool_calls = tool_selection
        }

        public static func messages(for tool_results: [ChatToolResult]) -> [Message] {
            return tool_results.map { result in
                Message(role: .tool, content: result.result)
            }
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            role = try container.decode(Role.self, forKey: .role)
            content = LangToolsTextContent(text: try container.decode(String.self, forKey: .content))
            images = try container.decodeIfPresent([String].self, forKey: .images)
            tool_calls = try container.decodeIfPresent([ChatToolCall].self, forKey: .tool_calls)
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(role, forKey: .role)
            try container.encode(content.text, forKey: .content)
            try container.encodeIfPresent(images, forKey: .images)
            try container.encodeIfPresent(tool_calls, forKey: .tool_calls)
        }

        enum CodingKeys: String, CodingKey {
            case role, content, images, tool_calls
        }
    }

    public struct ChatToolCall: Codable, LangToolsToolSelection {
        public let id: String?
        public let name: String?
        public var arguments: String { function.arguments.string ?? "" }

        public let function: Function

        public struct Function: Codable {
            public let name: String
            public let arguments: [String:String]
        }
    }

    public struct ChatToolResult: Codable, LangToolsToolSelectionResult {
        public let tool_selection_id: String
        public let result: String

        public init(tool_selection_id: String, result: String, is_error: Bool = false) {
            self.tool_selection_id = tool_selection_id
            self.result = result
        }
    }

    public struct ChatDelta: Codable, LangToolsMessageDelta {
        public typealias Role = Message.Role
        
        public let role: Role?
        public let content: String?
    }

    public enum Role: String, Codable, LangToolsRole {
        case system, user, assistant, tool

        public init(_ role: any LangToolsRole) {
            if role.isAssistant { self = .assistant }
            else if role.isUser { self = .user }
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

// Convenience extension for easier API usage
public extension Ollama {
    /// Send a chat message to get a completion from an Ollama model.
    /// - Parameters:
    ///   - model: The name of the model to use
    ///   - messages: The conversation history
    ///   - format: Optional format for structured output
    ///   - options: Additional model parameters
    /// - Returns: The chat completion response
    func chat(
        model: OllamaModel,
        messages: [Message],
        format: GenerateFormat? = nil,
        options: GenerateOptions? = nil,
        tools: [OpenAI.Tool]? = nil
    ) async throws -> ChatResponse {
        return try await perform(request: ChatRequest(
            model: model,
            messages: messages,
            format: format,
            options: options,
            tools: tools
        ))
    }
    
    /// Stream a chat completion for the given conversation.
    /// - Parameters:
    ///   - model: The name of the model to use
    ///   - messages: The conversation history
    ///   - options: Additional model parameters
    /// - Returns: A stream of chat completion responses
    func streamChat(
        model: OllamaModel,
        messages: [Message],
        options: GenerateOptions? = nil,
        tools: [OpenAI.Tool]? = nil
    ) -> AsyncThrowingStream<ChatResponse, Error> {
        return stream(request: ChatRequest(
            model: model,
            messages: messages,
            options: options,
            stream: true,
            tools: tools
        ))
    }
}
