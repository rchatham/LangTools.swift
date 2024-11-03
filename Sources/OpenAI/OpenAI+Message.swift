import Foundation
import LangTools

public extension OpenAI {
    struct Message: Codable, CustomStringConvertible, LangToolsMessage {
        public typealias ToolSelection = ToolCall
        public typealias ToolResult = Content.ToolResultContent

        public static func messages(for tool_results: [Content.ToolResultContent]) -> [OpenAI.Message] {
            return tool_results.map { .init(tool_selection_id: $0.tool_selection_id, result: $0.result) }
        }

        public var tool_selection_id: String { tool_call_id ?? "no id" }

        public init(tool_selection_id: String, result: String) {
            role = .tool
            content = Content.array([.toolResult(.init(tool_selection_id: tool_selection_id, result: result))])
            name = nil
            tool_calls = nil
        }

        public init(tool_selection: [ToolCall]) {
            role = .assistant
            content = .null
            name = nil
            tool_calls = tool_selection
        }

        public let role: Role
        public let content: Content
        public let name: String?
        public let tool_calls: [ToolCall]?
        public var tool_call_id: String? {
            if let tool = toolResult { return tool.tool_selection_id }; return nil
        }
        var toolResult: ToolResult? {
            if case .toolResult(let tool) = content.array?.first { return tool }; return nil
        }

        public var tool_selection: [ToolCall]? { tool_calls }


        public var description: String {
            let tools: String? = tool_calls?.reduce("") {
                let name = $1.function.name ?? ""
                return $0.isEmpty ? (name) : ($0 + "," + name)
            }
            return """
                message info:
                  role: \(role)
                  content: \(content)
                  name: \(name ?? "")
                  tool_calls: \(tools ?? "")
                  tool_call_id: \(tool_call_id ?? "")
                """
        }

        public init(role: Role, content: String) {
            self.role = role
            self.content = Content.string(content)
            self.name = nil
            self.tool_calls = nil
        }
        
        public init(role: Role, content: Content, name: String? = nil, tool_calls: [ToolCall]? = nil) throws {
            switch role {
            case .user: if case .null = content { throw MessageError.missingContent }
            case .tool: guard case .array(let arr) = content, case .toolResult(_) = arr[0] else { throw MessageError.missingContent }
            case .system, .assistant: if case .array(_) = content { throw MessageError.invalidContent }
            }

            if role != .assistant, let tool_calls = tool_calls {
                print("\(role.rawValue.capitalized) is not able to use tool calls: \(tool_calls.description). Please check your configuration, only assistant messages are allowed to contain tool calls")
            }
            if role != .tool, case .array(let arr) = content, case .toolResult(let tool) = arr[0] {
                print("\(role.rawValue.capitalized) can not have tool_call_id: \(tool.tool_selection_id). Please check your configuration, only tool meesages may have a tool_call_id.")
            }

            self.role = role
            self.content = content
            self.name = name
            self.tool_calls = role == .assistant ? tool_calls : nil
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(role, forKey: .role)
            if let tool_call_id, let toolResult {
                try container.encode(tool_call_id, forKey: .tool_call_id)
                try container.encode(Content.string(toolResult.result), forKey: .content)
            } else {
                try container.encode(content, forKey: .content)
            }
            try container.encodeIfPresent(name, forKey: .name)
            try container.encodeIfPresent(tool_calls, forKey: .tool_calls)
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            role = try container.decode(Role.self, forKey: .role)
            if let tool_call_id = try container.decodeIfPresent(String.self, forKey: .tool_call_id), let result = try container.decode(Content.self, forKey: .content).string {
                self.content = Content.array([.toolResult(.init(tool_selection_id: tool_call_id, result: result))])
            } else {
                content = try container.decode(Content.self, forKey: .content)
            }
            name = try container.decodeIfPresent(String.self, forKey: .name)
            tool_calls = try container.decodeIfPresent([ToolCall].self, forKey: .tool_calls)
        }

        enum CodingKeys: String, CodingKey { case role, content, name, tool_calls, tool_call_id }

        public enum Role: String, Codable, LangToolsRole {
            case system, user, assistant, tool
        }
        
        public enum Content: Codable, CustomStringConvertible, LangToolsContent {
            case null
            case string(String)
            case array([ContentType])

            public var description: String {
                switch self {
                case .null: return "null"
                case .string(let str): return "string: \(str)"
                case .array(let arr): return "array: \(arr)"
                }
            }

            public var string: String? {
                if case .string(let str) = self { return str } else { return nil }
            }

            public var array: [ContentType]? {
                if case .array(let arr) = self { return arr } else { return nil }
            }

            public enum ContentType: Codable, CustomStringConvertible, LangToolsContentType {
                case text(TextContent)
                case image(ImageContent)
                case toolResult(ToolResultContent)

                public var description: String {
                    switch self {
                    case .text(let txt): return "text: \(txt.text)"
                    case .image(let img): return "image: \(img.image_url)"
                    case .toolResult(let tool): return "tool_id: \(tool.tool_selection_id), result: \(tool.result)"
                    }
                }
                
                public var type: String {
                    switch self {
                    case .image(let img): return img.type
                    case .text(let txt): return txt.type
                    case .toolResult(let tool): return "tool_selection"
                    }
                }
                
                public init(from decoder: Decoder) throws {
                    let container = try decoder.singleValueContainer()
                    if let text = try? container.decode(TextContent.self) { self = .text(text) }
                    else if let img = try? container.decode(ImageContent.self) { self = .image(img) }
                    else { throw DecodingError.typeMismatch(ContentType.self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown content type")) }
                }

                public func encode(to encoder: Encoder) throws {
                    var container = encoder.singleValueContainer()
                    switch self {
                    case .text(let txt): try container.encode(txt)
                    case .image(let img): try container.encode(img)
                    case .toolResult(let tool): try container.encode(tool.result)
                    }
                }
            }
            
            public struct TextContent: LangToolsTextContentType {
                public let text: String
                public init(text: String) {
                    self.text = text
                }
            }

            public struct ImageContent: LangToolsImageContentType {
                public var type: String { "image_url" }
                public let image_url: ImageURL
                public init(image_url: ImageURL) {
                    self.image_url = image_url
                }

                public struct ImageURL: Codable {
                    public let url: String
                    public let detail: Detail?
                    public init(url: String, detail: Detail? = nil) {
                        self.url = url
                        self.detail = detail
                    }
                }

                public enum Detail: String, Codable {
                    case auto, high, low
                }
            }

            public struct ToolResultContent: LangToolsToolSelectionResult {
                public var tool_selection_id: String
                public var result: String
                public init(tool_selection_id: String, result: String) {
                    self.tool_selection_id = tool_selection_id
                    self.result = result
                }
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let str = try? container.decode(String.self) { self = .string(str) }
                else if let arr = try? container.decode([ContentType].self) { self = .array(arr) }
                else if container.decodeNil() { self = .null }
                else { throw DecodingError.typeMismatch(Content.self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown content type")) }
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                case .string(let txt): try container.encode(txt)
                case .array(let array): try container.encode(array)
                case .null: try container.encodeNil()
                }
            }
        }

        public enum MessageError: Error {
            case invalidRole, missingContent, invalidContent
        }

        public struct Delta: Codable, LangToolsMessageDelta {
            public let role: Role?
            public let content: String?
            public let tool_calls: [ToolCall]?

            public var tool_selection: [ToolCall]? { tool_calls }
        }

        public struct ToolCall: Codable, CustomStringConvertible, LangToolsToolSelection {
            public let index: Int?
            public let id: String?
            public let type: ToolType?
            public let function: Function

            public var arguments: String { function.arguments }
            public var name: String? { function.name }

            public var description: String {
                return """
                tool call:
                  index:    \(index != nil ? "\(index!)" : "no index")
                  id:       \(id ?? "no idea")
                  type:     \(type?.rawValue ?? "no type")
                  function: \(function.name ?? "name missing"): \(function.arguments)
                """
            }

            public init(index: Int, id: String, type: ToolType, function: Function) {
                self.index = index
                self.id = id
                self.type = type
                self.function = function
            }

            public enum ToolType: String, Codable {
                case function
            }

            public struct Function: Codable {
                public let name: String?
                public let arguments: String
                public init(name: String, arguments: String) {
                    self.name = name
                    self.arguments = arguments
                }
            }
        }
    }
}