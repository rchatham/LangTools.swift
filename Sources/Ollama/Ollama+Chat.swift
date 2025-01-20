import Foundation
import LangTools
import OpenAI

extension Ollama {
    public struct ChatRequest: Codable, LangToolsRequest, LangToolsStreamableRequest, LangToolsToolCallingRequest {
        public typealias Response = ChatResponse
        public typealias LangTool = Ollama
        public static var endpoint: String { "api/chat" }

        // Required parameters
        public let model: String
        public var messages: [Message]

        // Optional parameters
        public let format: GenerateFormat?
        public let options: GenerateOptions?
        public var stream: Bool?
        public let keep_alive: String?
        public let tools: [OpenAI.Tool]?

        public init(
            model: String,
            messages: [Message],
            format: GenerateFormat? = nil,
            options: GenerateOptions? = nil,
            stream: Bool? = nil,
            keep_alive: String? = nil,
            tools: [OpenAI.Tool]? = nil
        ) {
            self.model = model
            self.messages = messages
            self.format = format
            self.options = options
            self.stream = stream
            self.keep_alive = keep_alive
            self.tools = tools
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
                    content: (message?.content ?? "") + (next.message?.content ?? ""),
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
        public typealias Content = String
        public typealias ToolSelection = ChatToolCall
        public typealias ToolResult = ChatToolResult

        public let role: Role
        public let content: String
        public let images: [String]?
        public let tool_calls: [ChatToolCall]?

        public var tool_selection: [ChatToolCall]? { tool_calls }

        public init(role: Role, content: Content, images: [String]? = nil, tool_calls: [ChatToolCall]? = nil) {
            self.role = role
            self.content = content
            self.images = images
            self.tool_calls = tool_calls
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

        public init(tool_selection_id: String, result: String) {
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
        model: String,
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
        model: String,
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

extension String: LangToolsContent, LangToolsContentType {
    public var type: String { "string" }
    public var string: String? { self }
    public var array: [Self]? { nil }
}
