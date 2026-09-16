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
import ChatUI

public final class Message: Codable, ObservableObject, Identifiable, Equatable, Hashable {
    public let uuid: UUID
    public var role: Role
    @Published public var contentType: ContentType
    public var imageDetail: ImageDetail?
    public let createdAt: Date
    /// Tool invocations made while producing this message. Rendered by ChatUI
    /// as expandable tool-call cards alongside the message bubble.
    @Published public var toolCalls: [ChatToolCall] = []
    public var id: UUID { uuid }

    public var text: String? {
        switch contentType {
        case .null: return nil
        case .string(let str): return str
        case .array(let arr): return arr.joined(separator: "\n")
        case .agentEvent(let content): return content.formattedText
        case .contentCards(let cards): return cards.message
        }
    }

    public init(uuid: UUID = UUID(), role: Role, contentType: ContentType = .null, imageDetail: ImageDetail? = nil, createdAt: Date = Date(), toolCalls: [ChatToolCall] = []) {
        self.uuid = uuid
        self.role = role
        self.contentType = contentType
        self.imageDetail = imageDetail
        self.createdAt = createdAt
        self.toolCalls = toolCalls
    }

    // Helper initializer for regular messages
    public convenience init(text: String, role: Role) { self.init(role: role, contentType: .string(text)) }

    // Coding keys for encoding/decoding
    enum CodingKeys: CodingKey { case uuid, role, contentType, imageDetail, createdAt, toolCalls }

    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try container.decode(UUID.self, forKey: .uuid)
        role = try container.decode(Role.self, forKey: .role)
        contentType = try container.decode(ContentType.self, forKey: .contentType)
        imageDetail = try container.decodeIfPresent(ImageDetail.self, forKey: .imageDetail)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        toolCalls = try container.decodeIfPresent([ChatToolCall].self, forKey: .toolCalls) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(uuid, forKey: .uuid)
        try container.encode(role, forKey: .role)
        try container.encode(contentType, forKey: .contentType)
        try container.encodeIfPresent(imageDetail, forKey: .imageDetail)
        try container.encode(createdAt, forKey: .createdAt)
        if !toolCalls.isEmpty {
            try container.encode(toolCalls, forKey: .toolCalls)
        }
    }

    public static func == (lhs: Message, rhs: Message) -> Bool {
        lhs.uuid == rhs.uuid &&
        lhs.role == rhs.role &&
        lhs.contentType == rhs.contentType &&
        lhs.imageDetail == rhs.imageDetail &&
        lhs.createdAt == rhs.createdAt &&
        lhs.toolCalls == rhs.toolCalls
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(uuid)
        hasher.combine(role)
        hasher.combine(contentType)
        hasher.combine(imageDetail)
        hasher.combine(createdAt)
        hasher.combine(toolCalls)
    }
}

// Role checks
extension Message {
    public var isUser: Bool { role == .user }
    public var isAssistant: Bool { role == .assistant }
    var isSystem: Bool { role == .system }
    var isToolCall: Bool { role == .tool }

    public var isStringContent: Bool {
        if case .string = contentType { return true }
        return false
    }

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
    /// Messages whose `toolCalls` are retained (kept in history) are replayed to
    /// the API as proper provider tool messages so the model retains tool-call
    /// context across turns. When `keepsToolCallsInHistory` is off, `toolCalls` is
    /// empty, so only text is sent (unchanged behavior).
    func toOpenAIMessages() -> [OpenAI.Message] {
        flatMap { message -> [OpenAI.Message] in
            let completed = message.toolCalls.filter { $0.status != .pending }
            guard !completed.isEmpty else {
                return [OpenAI.Message(role: message.role, content: message.text ?? "")]
            }
            let toolCalls = completed.enumerated().map { idx, call in
                OpenAI.Message.ToolCall(index: idx, id: call.id, type: .function, function: .init(name: call.name, arguments: call.arguments ?? "{}"))
            }
            let assistant: OpenAI.Message
            if let text = message.text, !text.isEmpty {
                assistant = try! OpenAI.Message(role: .assistant, content: .string(text), tool_calls: toolCalls)
            } else {
                assistant = OpenAI.Message(tool_selection: toolCalls)
            }
            var messages: [OpenAI.Message] = [assistant]
            for call in completed {
                messages.append(OpenAI.Message(tool_selection_id: call.id, result: call.result ?? ""))
            }
            return messages
        }
    }

    func toAnthropicMessages() -> [Anthropic.Message] {
        flatMap { message -> [Anthropic.Message] in
            guard message.role != .system else { return [] }
            let completed = message.toolCalls.filter { $0.status != .pending }
            guard !completed.isEmpty else {
                return [Anthropic.Message(role: .init(message.role), content: message.text ?? "")]
            }
            var content: [Anthropic.Message.Content.ContentType] = []
            if let text = message.text, !text.isEmpty {
                content.append(.text(.init(text: text)))
            }
            for call in completed {
                content.append(.toolUse(.init(id: call.id, name: call.name, input: call.arguments ?? "{}")))
            }
            let assistant = Anthropic.Message(role: .assistant, content: .array(content))
            let results: [Anthropic.Message.Content.ContentType] = completed.map {
                .toolResult(.init(tool_selection_id: $0.id, result: $0.result ?? "", is_error: $0.status == .failure))
            }
            return [assistant, Anthropic.Message(role: .user, content: .array(results))]
        }
    }

    func createAnthropicSystemMessage() -> String? { filter { $0.isSystem }.reduce("") { (!$0.isEmpty ? $0 + "\n---\n" : "") + ($1.text ?? "") } }

    func toOllamaMessages() -> [Ollama.Message] {
        // Ollama tool-call replay is not supported: `Ollama.ChatToolCall` has no
        // public initializer, so retained tool calls cannot be reconstructed into
        // provider messages. Tool-call context is therefore not replayed to
        // Ollama across turns (text-only, unchanged behavior).
        map { Ollama.Message(role: .init($0.role), content: $0.text ?? "") }
    }
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
    // Content cards for structured agent responses
    case contentCards(ContentCardsContent)

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
        case .contentCards(let cards):
            try container.encode("contentCards", forKey: .type)
            try container.encode(cards, forKey: .content)
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
        case "contentCards":
            let content = try container.decode(ContentCardsContent.self, forKey: .content)
            self = .contentCards(content)
        default: self = .null
        }
    }

    public static func ==(_ lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case (.string(let lstr), .string(let rstr)): return lstr == rstr
        case (.array(let larr), .array(let rarr)): return larr == rarr
        case (.agentEvent(let lcontent), .agentEvent(let rcontent)): return lcontent == rcontent
        case (.contentCards(let lcards), .contentCards(let rcards)): return lcards == rcards
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
        case .contentCards(let cards):
            hasher.combine(4)
            hasher.combine(cards)
        }
    }
}

public enum ImageDetail: String, Codable {
    case auto, high, low
}

public struct AgentEventContent: Codable, Equatable, Hashable {
    public let type: AgentEventType
    public let agentName: String
    public let details: String
    public weak var parent: Message?
    public var children: [Message]
    
    public init(type: AgentEventType, agentName: String, details: String, parent: Message? = nil, children: [Message] = []) {
        self.type = type
        self.agentName = agentName
        self.details = details
        self.parent = parent
        self.children = children
    }

    public var formattedText: String {
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

    public var icon: String {
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
    /// Updates the tool-call lifecycle for this message from a LangTools event.
    /// Used by `MessageService` to surface non-agent tool activity to ChatUI.
    public func applyToolEvent(_ event: LangToolsToolEvent) {
        switch event {
        case .toolCalled(let selection):
            // Always append a new pending card. Provider tool-call ids are not
            // guaranteed to be unique (e.g. Ollama reports "ollama" for every
            // call), so we cannot dedupe by id. Each completion is matched to
            // the most recent pending card in `.toolCompleted` below.
            let arguments = selection.arguments.isEmpty ? nil : selection.arguments
            toolCalls.append(
                ChatToolCall(
                    id: UUID().uuidString,
                    name: selection.name ?? "tool",
                    arguments: arguments,
                    status: .pending,
                    result: nil
                )
            )
        case .toolCompleted(let result):
            guard let result else { return }
            let status: ChatToolCall.Status = result.is_error ? .failure : .success
            // Tool events arrive as strict (.toolCalled, .toolCompleted) pairs
            // in arrival order, so complete the most recent pending card.
            if let index = toolCalls.lastIndex(where: { $0.status == .pending }) {
                let existing = toolCalls[index]
                toolCalls[index] = ChatToolCall(
                    id: existing.id,
                    name: existing.name,
                    arguments: existing.arguments,
                    status: status,
                    result: result.result
                )
            } else {
                toolCalls.append(
                    ChatToolCall(
                        id: UUID().uuidString,
                        name: "tool",
                        arguments: nil,
                        status: status,
                        result: result.result
                    )
                )
            }
        }
    }

    public static func agentEvent(type: AgentEventType, agentName: String, details: String, children: [Message] = []) -> Message {
        let content = AgentEventContent(type: type, agentName: agentName, details: details, children: children)
        return Message(role: .system, contentType: .agentEvent(content))
    }

    static func createAgentStartEvent(agentName: String, task: String) -> Message {
        .agentEvent(
            type: .started,
            agentName: agentName,
            details: "started: \(task)"
        )
    }

    static func createAgentDelegationEvent(
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

    static func createAgentToolCallEvent(
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

    static func createAgentToolReturnedEvent(
        agentName: String,
        result: String
    ) -> Message {
        .agentEvent(
            type: .toolCompleted,
            agentName: agentName,
            details: "tool result: \(result)"
        )
    }

    static func createAgentCompletionEvent(
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

    static func createAgentErrorEvent(
        agentName: String,
        error: String
    ) -> Message {
        .agentEvent(
            type: .error,
            agentName: agentName,
            details: "error: \(error)"
        )
    }

    public static func contentCards(_ content: ContentCardsContent) -> Message {
        Message(role: .assistant, contentType: .contentCards(content))
    }
}
