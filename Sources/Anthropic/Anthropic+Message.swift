import Foundation
import LangTools

extension Anthropic {
    public struct Message: Codable, LangToolsMessage, LangToolsToolMessage {

        public let role: Role
        public let content: Content

        public static func messages(for tool_results: [Content.ContentType.ToolResult]) -> [Anthropic.Message] {
            return [.init(role: .user, content: .array(tool_results.map{.toolResult($0)}))]
        }

        public init(tool_selection: [Content.ContentType.ToolUse]) {
            role = .assistant
            content = .array(tool_selection.map{.toolUse($0)})
        }

        public var tool_selection: [Content.ContentType.ToolUse]? {
            return content.tool_selection
        }

        public init(role: Role, content: String) {
            self.role = role
            self.content = Content.string(content)
        }

        public init(role: Role, content: Content) {
            self.role = role
            self.content = content
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            role = try container.decode(Role.self, forKey: .role)
            content = try container.decode(Content.self, forKey: .content)
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(role, forKey: .role)
            try container.encode(content, forKey: .content)
        }

        enum CodingKeys: String, CodingKey {
            case role, content
        }
    }

    public enum Role: String, Codable, LangToolsRole {
        case user, assistant

        public init(_ role: any LangToolsRole) {
            self = role.isUser ? .user : .assistant
        }

        public var isAssistant: Bool { self == .assistant }
        public var isUser: Bool { self == .user }
        public var isSystem: Bool { false }
        public var isTool: Bool { false }
    }

    public enum Content: Codable, LangToolsContent {
        case string(String)
        case array([ContentType])

        public init(string: String) {
            self = .string(string)
        }

        public init(_ content: any LangToolsContent) {
            if let string = content.string {
                self = .string(string)
            } else if let array = content.array {
                self = .array(array.compactMap { try? ContentType($0) })
            } else {
                fatalError("content not handled! \(content)")
            }
        }

        public var description: String {
            switch self {
            case .string(let str): return "text: \(str)"
            case .array(let arry): return "content: \(arry)"
            }
        }

        public var string: String? {
            if case .string(let str) = self { return str } else { return array?.first(where: { $0.textContent != nil })?.textContent?.text }
        }

        public var array: [ContentType]? {
            if case .array(let arr) = self { return arr } else { return nil }
        }

        public var tool_selection: [ContentType.ToolUse]? {
            if case .array(let arr) = self {
                let arr = arr.compactMap { $0.toolUse }
                return arr.isEmpty ? nil : arr
            } else { return nil }
        }

        public enum ContentType: Codable, CustomStringConvertible, LangToolsContentType {
            case text(TextContent)
            case image(ImageContent)
            case toolUse(ToolUse)
            case toolResult(ToolResult)

            public init(_ contentType: any LangToolsContentType) throws {
                if let text = contentType.textContentType {
                    self = .text(try .init(text))
                } else if let toolResult = contentType.toolResultContentType {
                    self = .toolResult(ToolResult(
                        tool_selection_id: toolResult.tool_selection_id,
                        result: toolResult.result,
                        is_error: toolResult.is_error
                    ))
                } else {
                    // Handle non-text content types
                    print("⚠️ Anthropic.Content.init() - Non-text content type: \(Swift.type(of: contentType))")
                    print("   Content: \(contentType)")

                    // For now, convert to text representation
                    // TODO: Implement proper audio and image support
                    let textRepresentation = String(describing: contentType)
                    self = .text(try .init(text: textRepresentation))
                }
            }

            public var description: String {
                switch self {
                case .text(let txt): return "text: \(txt.text)"
                case .image(let img): return "image: \(img.source.media_type)"
                case .toolUse(let toolUse): return "tool use: \(toolUse.name ?? "missing name")"
                case .toolResult(let toolResult): return "tool result: \(toolResult.content.description)"
                }
            }

            public var type: String {
                switch self {
                case .image(let img): return img.type
                case .text(let txt): return txt.type
                case .toolUse(let tool): return tool.type
                case .toolResult(let result): return result.type
                }
            }

            public var textContentType: LangToolsTextContentType? {
                if case .text(let txt) = self { return txt } else { return nil }
            }

            public var toolResultContentType: LangToolsToolResultContentType? {
                if case .toolResult(let result) = self { return result } else { return nil }
            }

            var textContent: TextContent? { if case .text(let text) = self { return text } else { return nil }}
            var imageContent: ImageContent? { if case .image(let img) = self { return img } else { return nil }}
            var toolUse: ToolUse? { if case .toolUse(let toolUse) = self { return toolUse } else { return nil }}
            var toolResult: ToolResult? { if case .toolResult(let toolResult) = self { return toolResult } else { return nil }}

            public init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let text = try? container.decode(TextContent.self) { self = .text(text) }
                else if let img = try? container.decode(ImageContent.self) { self = .image(img) }
                else if let toolUse = try? container.decode(ToolUse.self) { self = .toolUse(toolUse) }
                else if let toolResult = try? container.decode(ToolResult.self) { self = .toolResult(toolResult) }
                else { throw DecodingError.typeMismatch(ContentType.self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown content type")) }
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                case .text(let txt): try container.encode(txt)
                case .image(let img): try container.encode(img)
                case .toolUse(let toolUse): try container.encode(toolUse)
                case .toolResult(let toolResult): try container.encode(toolResult)
                }
            }

            public struct TextContent: Codable, LangToolsTextContentType {
                public let type: String = "text"
                public let text: String
                public init(text: String) {
                    self.text = text
                }

                enum CodingKeys: String, CodingKey {
                    case type, text
                }
            }

            public struct ImageContent: Codable, LangToolsImageContentType {
                public let type: String = "image"
                public let source: ImageSource
                public init(source: ImageSource) {
                    self.source = source
                }

                enum CodingKeys: String, CodingKey {
                    case type, source
                }

                public struct ImageSource: Codable {
                    let type: String = "base64"
                    public let media_type: MediaType
                    public let data: String
                    public init(data: String, media_type: MediaType) {
                        self.media_type = media_type
                        self.data = data
                    }

                    public enum MediaType: String, Codable {
                        case jpeg = "image/jpeg", png = "image/png", gif = "image/gif", webp = "image/webp"
                    }

                    enum CodingKeys: String, CodingKey {
                        case type, media_type, data
                    }
                }
            }

            public struct ToolUse: Codable, LangToolsContentType, LangToolsToolSelection {
                public let type: String = "tool_use"
                public let id: String?
                public let name: String?
                public let input: String

                public var arguments: String { input }

                public init(_ contentType: any LangToolsContentType) throws {
                    fatalError("init not implemented for tool use content type")
                }

                public init(id: String?, name: String?, input: String) {
                    self.id = id
                    self.name = name
                    self.input = input
                }

                enum CodingKeys: String, CodingKey {
                    case type, id, name, input
                }

                public init(from decoder: any Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    self.id = try container.decodeIfPresent(String.self, forKey: .id)
                    self.name = try container.decodeIfPresent(String.self, forKey: .name)
                    self.input = try container.decodeIfPresent(JSON.self, forKey: .input)?.jsonString ?? ""
                }

                public func encode(to encoder: any Encoder) throws {
                    var container = encoder.container(keyedBy: CodingKeys.self)
                    try container.encode(type, forKey: .type)
                    try container.encodeIfPresent(id, forKey: .id)
                    try container.encodeIfPresent(name, forKey: .name)
                    if !input.isEmpty { try container.encode(try JSON(string: input), forKey: .input) }
                }
            }

            public struct ToolResult: Codable, LangToolsToolResultContentType {
                public let type: String = "tool_result"
                public let tool_use_id: String
                public let is_error: Bool
                public let content: Content // Cannot be toolUse or toolResult ContentType

                public var tool_selection_id: String { tool_use_id }
                public var result: String { content.string ?? "" }
                public init(tool_selection_id: String, result: String, is_error: Bool = false) {
                    tool_use_id = tool_selection_id
                    content = .string(result)
                    self.is_error = is_error
                }

                public init(_ contentType: any LangToolsContentType) throws {
                    if let toolResult = contentType.toolResultContentType {
                        tool_use_id = toolResult.tool_selection_id
                        content = .string(toolResult.result)
                        is_error = toolResult.is_error
                    } else {
                        throw LangToolsError.invalidContentType
                    }
                }

                enum CodingKeys: String, CodingKey {
                    case type, tool_use_id, is_error, content
                }
            }
        }
        
        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let str = try? container.decode(String.self) { self = .string(str) }
            else if let arr = try? container.decode([ContentType].self) { self = .array(arr) }
            else { throw DecodingError.typeMismatch(Content.self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown content type")) }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let txt): try container.encode(txt)
            case .array(let array): try container.encode(array)
            }
        }
    }
}
