//
//  LangTools+Message.swift
//  LangTools
//
//  Created by Reid Chatham on 10/14/24.
//

import Foundation


public protocol LangToolsMessage: Codable {
    associatedtype Role: LangToolsRole
    associatedtype Content: LangToolsContent
    var role: Role { get }
    var content: Content { get }

    init(_ message: any LangToolsMessage)
    init(role: Role, content: Content)
}

extension LangToolsMessage {
    public init(_ message: any LangToolsMessage) {
        self.init(role: Role(message.role), content: Content(message.content))
    }
}

extension LangTools {
    public func systemMessage(_ message: String) -> any LangToolsMessage {
        LangToolsMessageImpl<LangToolsTextContent>(role: .system, string: message)
    }
    public func assistantMessage(_ message: String) -> any LangToolsMessage {
        LangToolsMessageImpl<LangToolsTextContent>(role: .assistant, string: message)
    }
    public func userMessage(_ message: String) -> any LangToolsMessage {
        LangToolsMessageImpl<LangToolsTextContent>(role: .user, string: message)
    }
}

public enum LangToolsRoleImpl: LangToolsRole {
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

public struct LangToolsMessageImpl<Content: LangToolsContent>: LangToolsMessage {
    public var role: LangToolsRoleImpl
    public var content: Content

    public init(role: LangToolsRoleImpl, string: String) {
        self.role = role
        self.content = Content(string: string)
    }

    public init(role: LangToolsRoleImpl, content: Content) {
        self.role = role
        self.content = content
    }
}

public protocol LangToolsMessageDelta: Codable {
    associatedtype Role: LangToolsRole
    var role: Role? { get }
    var content: String? { get }
}

public protocol LangToolsToolMessage: Codable {
    associatedtype ToolSelection: LangToolsToolSelection
    associatedtype ToolResult: LangToolsToolSelectionResult
    var tool_selection: [ToolSelection]? { get }
    init(tool_selection: [ToolSelection])
    static func messages(for tool_results: [ToolResult]) -> [Self]
}

public protocol LangToolsRole: Codable, Hashable {
    var isAssistant: Bool { get }
    var isUser: Bool { get }
    var isSystem: Bool { get }
    var isTool: Bool { get }

    init(_ role: any LangToolsRole)
}

public protocol LangToolsContent: Codable {
    associatedtype ContentType: LangToolsContentType
    var string: String? { get }
    var array: [ContentType]? { get }

    init(_ content: any LangToolsContent)
    init(string: String)
}

extension LangToolsContent {
    public var text: String {
        if let string = string {
            return string
        } else if let array = array, let text = array.first as? LangToolsTextContentType {
            // TODO: - fix to handle array's more robustly, multiple text
            return text.text
        } else {
            return ""
        }
    }
}

public protocol LangToolsContentType: Codable  {
    var type: String { get }

    var textContentType: LangToolsTextContentType? { get }
    var imageContentType: LangToolsImageContentType? { get }
    var audioContentType: LangToolsAudioContentType? { get }

    init(_ contentType: any LangToolsContentType) throws
}

public extension LangToolsContentType {
    var textContentType: LangToolsTextContentType? { self as? LangToolsTextContentType }
    var imageContentType: LangToolsImageContentType? { self as? LangToolsImageContentType }
    var audioContentType: LangToolsAudioContentType? { self as? LangToolsAudioContentType }
}

public protocol LangToolsTextContentType: LangToolsContentType {
    var text: String { get }
    init(text: String)
}

public extension LangToolsTextContentType {
    var type: String { "text" }

    init(_ contentType: any LangToolsContentType) throws {
        if let text = contentType.textContentType {
            self.init(text: text.text)
        } else {
            throw LangToolError.invalidContentType
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LangToolsTextContentCodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(text, forKey: .text)
    }
}

enum LangToolsTextContentCodingKeys: String, CodingKey {
    case type, text
}

public struct LangToolsTextContent: LangToolsTextContentType, LangToolsContent, ExpressibleByStringLiteral {
    public init(string: String) {
        text = string
    }

    public init(stringLiteral: String) {
       text = stringLiteral
    }

    public init(_ content: any LangToolsContent) {
        self.text = content.text
    }

    public var text: String
    public init(text: String) {
       self.text = text
    }

    public var string: String? { text }
    public var array: [LangToolsTextContent]? { [self] }
}

public protocol LangToolsImageContentType: LangToolsContentType {}

public extension LangToolsImageContentType {
//    var type: String { "image" } // TODO: verify this

    init(_ contentType: any LangToolsContentType) throws {
        if let image = contentType.imageContentType {
            fatalError("implement image! \(image)")
        } else {
            throw LangToolError.invalidContentType
        }
    }
}

public protocol LangToolsAudioContentType: LangToolsContentType {}

public extension LangToolsAudioContentType {
//    var type: String { "audio" } // TODO: verify this

    init(_ contentType: any LangToolsContentType) throws {
        if let audio = contentType.audioContentType {
            fatalError("implement audio! \(audio)")
        } else {
            throw LangToolError.invalidContentType
        }
    }
}

//public struct LangToolsImageContent: Codable {
//    var type: String
//
//    // OpenAI schema
//    public let image_url: ImageURL?
//    public init(image_url: ImageURL) {
//        self.image_url = image_url
//        self.type = "image_url"
//        source = nil
//    }
//
//    public struct ImageURL: Codable {
//        public let url: String
//        public let detail: Detail?
//        public init(url: String, detail: Detail? = nil) {
//            self.url = url
//            self.detail = detail
//        }
//    }
//    public enum Detail: String, Codable {
//        case auto, high, low
//    }
//
//    // Anthropic Schema
//    public let source: ImageSource?
//    public init(source: ImageSource) {
//        self.source = source
//        self.type = "image"
//        image_url = nil
//    }
//
//    public struct ImageSource: Codable {
//        var type: String = "base64"
//        public let media_type: MediaType
//        public let data: String
//        public init(data: String, media_type: MediaType) {
//            self.media_type = media_type
//            self.data = data
//        }
//
//        public enum MediaType: String, Codable {
//            case jpeg = "image/jpeg", png = "image/png", gif = "image/gif", webp = "image/webp"
//        }
//    }
//}
