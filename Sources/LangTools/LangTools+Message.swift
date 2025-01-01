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

public protocol LangToolsRole: Codable {

}

public protocol LangToolsContent: Codable {
    associatedtype ContentType: LangToolsContentType
    var string: String? { get }
    var array: [ContentType]? { get }
}

public protocol LangToolsContentType: Codable  {
    var type: String { get }
}

public protocol LangToolsTextContentType: LangToolsContentType {
    var text: String { get }
    init(text: String)
}

public extension LangToolsTextContentType {
    var type: String { "text" }
}

public struct TextContent: LangToolsTextContentType {
    public let text: String
    public init(text: String) {
        self.text = text
    }
}

public protocol LangToolsImageContentType: LangToolsContentType {

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
