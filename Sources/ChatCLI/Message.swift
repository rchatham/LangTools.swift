//
//  Message.swift
//
//  Created by Reid Chatham on 7/2/24.
//

import Foundation
import OpenAI
import Anthropic

class Message: Codable, ObservableObject {
    let uuid: UUID
    var text: String?
    var role: Role
    var contentType: ContentType?
    var imageDetail: ImageDetail?

    init(uuid: UUID = UUID(), text: String, role: Role) {
        self.uuid = uuid
        self.text = text
        self.role = role
    }
}

extension Message: Equatable, Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(uuid)
        hasher.combine(text)
        hasher.combine(role)
        hasher.combine(contentType)
        hasher.combine(imageDetail)
    }
    static func == (lhs: Message, rhs: Message) -> Bool {
        lhs.uuid == rhs.uuid &&
        lhs.text == rhs.text &&
        lhs.role == rhs.role &&
        lhs.contentType == rhs.contentType &&
        lhs.imageDetail == rhs.imageDetail
    }
}

extension Message {
    var isUser: Bool { role == .user }
    var isAssistant: Bool { role == .assistant }
    var isSystem: Bool { role == .system }
    var isToolCall: Bool { role == .tool }
}

//enum Role: String, Codable {
//    case system, assistant, user
//}

extension Array<Message> {
    func toOpenAIMessages() -> [OpenAI.Message] {
        return self.map { message in
            OpenAI.Message(role: message.role, content: message.text ?? "")
        }
    }
    func toAnthropicMessages() -> [Anthropic.Message] {
        return self.map { message in
            Anthropic.Message(role: message.role.toAnthropicRole(), content: message.text ?? "")
        }
    }
}

extension Array<OpenAI.Tool> {
    func toAnthropicTools() -> [Anthropic.Tool] {
        return self.map {
            Anthropic.Tool(
                name: $0.name,
                description: $0.description ?? "",
                tool_schema: .init(
                    properties: $0.tool_schema.properties.mapValues {
                        Anthropic.Tool.InputSchema.Property(
                            type: $0.type,
                            enumValues: $0.enumValues,
                            description: $0.description)
                    },
                    required: $0.tool_schema.required),
                callback: $0.callback)
        }
    }
}

extension OpenAI.Message.Role {
    func toAnthropicRole() -> Anthropic.Role {
        switch self {
        case .assistant: return .assistant
        case .user: return .user
        default: fatalError("role not handled ya fool!")
        }
    }
}

extension OpenAI.ChatCompletionRequest.ToolChoice {
    func toAnthropicToolChoice() -> Anthropic.MessageRequest.ToolChoice? {
        switch self {
        case .none: return nil
        case .auto: return .auto
        case .required: return .any
        case .tool(let toolWrapper): switch toolWrapper { case .function(let name): return .tool(name) }
        }
    }
}

enum ContentType: String, Codable {
    case null, string, array
}

enum ImageDetail: String, Codable {
    case auto, high, low
}
