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

public final class Message: Codable, Sendable, ObservableObject, Identifiable, Equatable, Hashable {
    public let uuid: UUID
    public var role: Role
    @Published public var contentType: ContentType
    public var imageDetail: ImageDetail?
    public var id: UUID { uuid }

    public var text: String? {
        switch contentType {
        case .null: return nil
        case .string(let str): return str
        case .array(let arr): return arr.joined(separator: "\n")
        case .agentEvent(let content): return content.formattedText
        }
    }

    public init(uuid: UUID = UUID(), role: Role, contentType: ContentType = .null, imageDetail: ImageDetail? = nil) {
        self.uuid = uuid
        self.role = role
        self.contentType = contentType
        self.imageDetail = imageDetail
    }

    // Helper initializer for regular messages
    public convenience init(text: String, role: Role) { self.init(role: role, contentType: .string(text)) }

    // Coding keys for encoding/decoding
    enum CodingKeys: CodingKey { case uuid, role, contentType, imageDetail }

    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try container.decode(UUID.self, forKey: .uuid)
        role = try container.decode(Role.self, forKey: .role)
        contentType = try container.decode(ContentType.self, forKey: .contentType)
        imageDetail = try container.decodeIfPresent(ImageDetail.self, forKey: .imageDetail)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(uuid, forKey: .uuid)
        try container.encode(role, forKey: .role)
        try container.encode(contentType, forKey: .contentType)
        try container.encodeIfPresent(imageDetail, forKey: .imageDetail)
    }

    public static func == (lhs: Message, rhs: Message) -> Bool {
        lhs.uuid == rhs.uuid &&
        lhs.role == rhs.role &&
        lhs.contentType == rhs.contentType &&
        lhs.imageDetail == rhs.imageDetail
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(uuid)
        hasher.combine(role)
        hasher.combine(contentType)
        hasher.combine(imageDetail)
    }
}

// Role checks
extension Message {
    public var isUser: Bool { role == .user }
    public var isAssistant: Bool { role == .assistant }
    var isSystem: Bool { role == .system }
    var isToolCall: Bool { role == .tool }

    public var isAgentEvent: Bool {
        if case .agentEvent = contentType { return true }
        return false
    }

    public var parent: Message? {
        if case .agentEvent(let content) = contentType { return content.parent }
        return nil
    }

    public var childMessages: [Message] {
        if case .agentEvent(let content) = contentType { return content.children }
        return []
    }
}

//enum Role: String, Codable {
//    case system, assistant, user
//}

public extension Array<Message> {
    func toOpenAIMessages() -> [OpenAI.Message] { map { .init(role: $0.role, content: $0.text ?? "") } }
    func toAnthropicMessages() -> [Anthropic.Message] { filter { $0.role != .system }.map { .init(role: .init($0.role), content: $0.text ?? "") } }
    func createAnthropicSystemMessage() -> String? { filter { $0.isSystem }.reduce("") { (!$0.isEmpty ? $0 + "\n---\n" : "") + ($1.text ?? "") } }
    func toOllamaMessages() -> [Ollama.Message] { map { .init(role: .init($0.role), content: $0.text ?? "") } }
}

public extension Array<Tool> {
    func convertTools<Tool: LangToolsTool>() -> [Tool] { return self.map { .init($0) } }
}

public extension OpenAI.ChatCompletionRequest.ToolChoice {
    func toAnthropicToolChoice() -> Anthropic.MessageRequest.ToolChoice? {
        switch self {
        case .none: return nil
        case .auto: return .auto
        case .required: return .any
        case .tool(let toolWrapper): switch toolWrapper { case .function(let name): return .tool(name) }
        }
    }
}

// TODO: - support more types of content. i.e. images, video, audio, pdf, etc.
public enum ContentType: Codable, Equatable, Hashable {
    case null
    case string(String)
    // TODO: - support more types of content for array
    case array([String])
    // TODO: - rename this as thread?
    case agentEvent(AgentEventContent)

    // Custom coding keys for encoding/decoding
    private enum CodingKeys: String, CodingKey { case type, content, children }

    // Custom encoding
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .null: try container.encode("null", forKey: .type)
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
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        // case "null": self = .null
        case "string":
            let content = try container.decode(String.self, forKey: .content)
            self = .string(content)
        case "array":
            let content = try container.decode([String].self, forKey: .content)
            self = .array(content)
        case "agentEvent":
            let content = try container.decode(AgentEventContent.self, forKey: .content)
            self = .agentEvent(content)
        default: self = .null
        }
    }

    public static func ==(_ lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case (.string(let lstr), .string(let rstr)): return lstr == rstr
        case (.array(let larr), .array(let rarr)): return larr == rarr
        case (.agentEvent(let lcontent), .agentEvent(let rcontent)): return lcontent == rcontent
        default: return false
        }
    }

    public func hash(into hasher: inout Hasher) {
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

public enum ImageDetail: String, Codable {
    case auto, high, low
}

public struct AgentEventContent: Codable, Equatable, Hashable {
    let type: AgentEventType
    let agentName: String
    let details: String
    weak var parent: Message?
    var children: [Message]

    var formattedText: String {
        "\(type.icon) Agent '\(agentName)' \(details)"
    }

    // TODO: - Re-evaluate the following implementation, it is very coupled with
    // the insert function for [Message] and has implications for the way agent
    // interactions are displayed in ChatUI.
    var hasCompleted: Bool {
        if [.completed, .failed].contains(type) { return true }
        return children.contains { if case .agentEvent(let content) = $0.contentType { [.completed, .failed].contains(content.type) } else { false } }
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(type)
        hasher.combine(agentName)
        hasher.combine(details)
        hasher.combine(children)
    }
}

public enum AgentEventType: String, Codable {
    case started
    case delegated
    case toolCalled
    case toolCompleted
    case completed
    case failed
    case error

    var icon: String {
        switch self {
        case .started: return "🤖"
        case .delegated: return "🔄"
        case .toolCalled: return "🛠️"
        case .toolCompleted: return "✅"
        case .completed: return "🏁"
        case .failed: return "⚠️"
        case .error: return "‼️"
        }
    }
}

// Factory methods for agent events
extension Message {
    static func agentEvent(type: AgentEventType, agentName: String, details: String, children: [Message] = []) -> Message {
        let content = AgentEventContent(type: type, agentName: agentName, details: details, children: children)
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
        result: String,
        is_error: Bool = false
    ) -> Message {
        .agentEvent(
            type: is_error ? .failed : .completed,
            agentName: agentName,
            details: (is_error ? "failed: " : "completed: ") + result
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
