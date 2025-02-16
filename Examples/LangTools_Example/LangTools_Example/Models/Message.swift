//
//  Message.swift
//
//  Created by Reid Chatham on 7/2/24.
//

import Foundation
import LangTools
import OpenAI
import Anthropic
import Ollama

class Message: Codable, ObservableObject, Identifiable, Equatable, Hashable {
    let uuid: UUID
    var role: Role
    @Published var contentType: ContentType
    var imageDetail: ImageDetail?

    var text: String? {
        switch contentType {
        case .null:
            return nil
        case .string(let str):
            return str
        case .array(let arr):
            return arr.joined(separator: "\n")
        case .agentEvent(let content):
            return content.formattedText
        }
    }

    init(uuid: UUID = UUID(),
         role: Role,
         contentType: ContentType = .null,
         imageDetail: ImageDetail? = nil) {
        self.uuid = uuid
        self.role = role
        self.contentType = contentType
        self.imageDetail = imageDetail
    }

    // Helper initializer for regular messages
    convenience init(text: String, role: Role) {
        self.init(role: role, contentType: .string(text))
    }

    // Coding keys for encoding/decoding
    enum CodingKeys: CodingKey {
        case uuid, role, contentType, imageDetail
    }

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try container.decode(UUID.self, forKey: .uuid)
        role = try container.decode(Role.self, forKey: .role)
        contentType = try container.decode(ContentType.self, forKey: .contentType)
        imageDetail = try container.decodeIfPresent(ImageDetail.self, forKey: .imageDetail)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(uuid, forKey: .uuid)
        try container.encode(role, forKey: .role)
        try container.encode(contentType, forKey: .contentType)
        try container.encodeIfPresent(imageDetail, forKey: .imageDetail)
    }

    static func == (lhs: Message, rhs: Message) -> Bool {
        lhs.uuid == rhs.uuid &&
        lhs.role == rhs.role &&
        lhs.contentType == rhs.contentType &&
        lhs.imageDetail == rhs.imageDetail
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(uuid)
        hasher.combine(role)
        hasher.combine(contentType)
        hasher.combine(imageDetail)
    }
}

// Role checks
extension Message {
    var isUser: Bool { role == .user }
    var isAssistant: Bool { role == .assistant }
    var isSystem: Bool { role == .system }
    var isToolCall: Bool { role == .tool }

    var isAgentEvent: Bool {
        if case .agentEvent = contentType { return true }
        return false
    }

    var childMessages: [Message] {
        if case .agentEvent(let content) = contentType {
            return content.children
        }
        return []
    }
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
        return self.filter { $0.role != .system }.map { message in
            Anthropic.Message(role: message.role.toAnthropicRole(), content: message.text ?? "")
        }
    }
    func createAnthropicSystemMessage() -> String? {
        return self.filter { $0.isSystem }.reduce("") { (!$0.isEmpty ? $0 + "\n---\n" : "") + ($1.text ?? "") }
    }
    func toOllamaMessages() -> [Ollama.Message] {
        return self.map { message in
            Ollama.Message(role: message.role.toOllamaRole(), content: message.text ?? "")
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
    func toOllamaRole() -> Ollama.Role {
        switch self {
        case .assistant: .assistant
        case .user: .user
        case .tool: .tool
        case .system, .developer: .system
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

enum ContentType: Codable, Equatable, Hashable {
    case null
    case string(String)
    case array([String])
    case agentEvent(AgentEventContent)

    // Custom coding keys for encoding/decoding
    private enum CodingKeys: String, CodingKey {
        case type, content, children
    }

    // Custom encoding
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .null:
            try container.encode("null", forKey: .type)
        case .string(let str):
            try container.encode("string", forKey: .type)
            try container.encode(str, forKey: .content)
        case .array(let arr):
            try container.encode("array", forKey: .type)
            try container.encode(arr, forKey: .content)
        case .agentEvent(let content):
            try container.encode("agentEvent", forKey: .type)
            try container.encode(content, forKey: .content)
        }
    }

    // Custom decoding
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "null":
            self = .null
        case "string":
            let content = try container.decode(String.self, forKey: .content)
            self = .string(content)
        case "array":
            let content = try container.decode([String].self, forKey: .content)
            self = .array(content)
        case "agentEvent":
            let content = try container.decode(AgentEventContent.self, forKey: .content)
            self = .agentEvent(content)
        default:
            self = .null
        }
    }

    static func ==(_ lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case (.string(let lstr), .string(let rstr)): return lstr == rstr
        case (.array(let larr), .array(let rarr)): return larr == rarr
        case (.agentEvent(let lcontent), .agentEvent(let rcontent)): return lcontent == rcontent
        default: return false
        }
    }

    func hash(into hasher: inout Hasher) {
        switch self {
        case .null:
            hasher.combine(0)
        case .string(let str):
            hasher.combine(1)
            hasher.combine(str)
        case .array(let arr):
            hasher.combine(2)
            hasher.combine(arr)
        case .agentEvent(let content):
            hasher.combine(3)
            hasher.combine(content)
        }
    }
}

enum ImageDetail: String, Codable {
    case auto, high, low
}

struct AgentEventContent: Codable, Equatable, Hashable {
    let type: AgentEventType
    let agentName: String
    let details: String
    var children: [Message]

    var formattedText: String {
        "\(type.icon) Agent '\(agentName)' \(details)"
    }

    var hasCompleted: Bool {
        if type == .completed { return true }
        return children.contains { if case .agentEvent(let content) = $0.contentType { content.type == .completed } else { false } }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(type)
        hasher.combine(agentName)
        hasher.combine(details)
        hasher.combine(children)
    }
}

enum AgentEventType: String, Codable {
    case started
    case delegated
    case toolCalled
    case toolCompleted
    case completed
    case error

    var icon: String {
        switch self {
        case .started: return "🤖"
        case .delegated: return "🔄"
        case .toolCalled: return "🛠️"
        case .toolCompleted: return "✅"
        case .completed: return "🏁"
        case .error: return "❌"
        }
    }
}

// Factory methods for agent events
extension Message {
    static func agentEvent(
        type: AgentEventType,
        agentName: String,
        details: String,
        children: [Message] = []
    ) -> Message {
        let content = AgentEventContent(
            type: type,
            agentName: agentName,
            details: details,
            children: children
        )
        return Message(role: .system, contentType: .agentEvent(content))
    }

    static func createStartEvent(agentName: String, task: String) -> Message {
        .agentEvent(
            type: .started,
            agentName: agentName,
            details: "started: \(task)"
        )
    }

    static func createDelegationEvent(
        fromAgent: String,
        toAgent: String,
        reason: String,
        children: [Message] = []
    ) -> Message {
        .agentEvent(
            type: .delegated,
            agentName: fromAgent,
            details: "delegated to '\(toAgent)': \(reason)",
            children: children
        )
    }

    static func createToolCallEvent(
        agentName: String,
        tool: String,
        arguments: String
    ) -> Message {
        .agentEvent(
            type: .toolCalled,
            agentName: agentName,
            details: "using tool: \(tool), arguments: \(arguments)"
        )
    }

    static func createToolReturnedEvent(
        agentName: String,
        result: String
    ) -> Message {
        .agentEvent(
            type: .toolCompleted,
            agentName: agentName,
            details: "tool result: \(result)"
        )
    }

    static func createCompletionEvent(
        agentName: String,
        result: String
    ) -> Message {
        .agentEvent(
            type: .completed,
            agentName: agentName,
            details: "completed: \(result)"
        )
    }

    static func createErrorEvent(
        agentName: String,
        error: String
    ) -> Message {
        .agentEvent(
            type: .error,
            agentName: agentName,
            details: "error: \(error)"
        )
    }
}
