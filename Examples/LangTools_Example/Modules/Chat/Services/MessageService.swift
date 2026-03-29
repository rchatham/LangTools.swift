//
//  MessageService.swift
//
//  Created by Reid Chatham on 3/31/23.
//

import Agents
import Foundation
import LangTools
import ToolKit


@Observable
public class MessageService: Sendable {
    public let networkClient: NetworkClientProtocol
    public var messages: [Message] = [] {
        didSet {
            if let last = messages.last {
                messageUpdatedCallback?(last)
            }
        }
    }
    var tools: [Tool]?

    /// Callback fired when a message is added or modified (for persistence)
    public var messageUpdatedCallback: ((Message) -> Void)?

    /// Snapshot of tools filtered by the current ToolManager state.
    /// Delegates to `ToolManager.filteredTools()` for the enabled-id set, then
    /// intersects with `self.tools` so future changes to ToolManager filtering
    /// logic are automatically picked up here.
    /// Hops to the main actor because ToolManager is @MainActor-isolated.
    @MainActor
    var filteredTools: [Tool]? {
        guard let enabledTools = ToolManager.shared.filteredTools() else { return nil }
        let enabledNames = Set(enabledTools.map { $0.name })
        return tools?.filter { enabledNames.contains($0.name) }
    }

    public init(networkClient: NetworkClientProtocol = NetworkClient.shared, agents: [any Agent]? = nil, tools: [Tool]? = nil) {
        self.networkClient = networkClient
        self.tools = agents?.map { .init(agent: $0, eventHandler: handleAgentEvent) } + tools
    }

    public func send(message: String, stream: Bool = false) async throws {
        let userMessage = Message(text: message, role: .user)
        await MainActor.run {
            messages.append(userMessage)
        }

        do {
            var currentMessages = messages
            currentMessages.insert(Message(text: systemMessage(), role: .system), at: 0)

            // Snapshot filtered tools on the main actor before entering the async stream.
            let activeTools = await filteredTools

            var content: String = ""
            for try await chunk in try networkClient.streamChatCompletionRequest(messages: currentMessages, stream: stream, tools: activeTools) {
                content += chunk
                if !(messages.last?.isAssistant ?? false) {
                    if chunk.isEmpty { continue }
                    content = chunk.trimingLeadingNewlines()
                }
                let messageUuid = if let last = messages.last, last.isAssistant { last.uuid } else { UUID() }
                let message = Message(uuid: messageUuid, role: .assistant, contentType: .string(content.trimingTrailingNewlines()))

                await MainActor.run {
                    if let last = messages.last, last.uuid == message.uuid { messages[messages.count - 1] = message }
                    else { messages.append(message) }
                }
            }
        } catch {
            if messages.last?.isAssistant ?? false {
                // TODO: - Should mark the last message as errored
            } else {
                // remove last user message
                await MainActor.run {
                    messages.removeLast()
                }
            }
            throw error
        }
    }

    func systemMessage() -> String {
        UserDefaults.systemMessage + "\n\nWhen using agent tools, you should relay all the critical details from the agent's response, the user will not have access to the agent's response. Your answer should be specific and comprehensive, but provide only the relevant information to the user or parent agent."
    }

    public func deleteMessage(id: UUID) { Task { @MainActor in messages.removeAll(where: { $0.uuid == id }) } }
    public func clearMessages() { Task { @MainActor in messages.removeAll() } }
}

extension MessageService {
    func handleAgentEvent(_ event: AgentEvent) {
        Task { @MainActor in

            switch event {
            case .started(let agent, let parent, let task):
                let message = Message.createAgentStartEvent(agentName: agent, task: task)
                if let parent {
                    messages.append(message, for: parent)
                } else {
                    messages.append(message)
                }

            case .agentTransfer(let agent, let to, let reason):
                let message = Message.createAgentDelegationEvent(
                    fromAgent: agent,
                    toAgent: to,
                    reason: reason
                )
                messages.append(message, for: agent)

            case .toolCalled(let agent, let tool, let args):
                let message = Message.createAgentToolCallEvent(
                    agentName: agent,
                    tool: tool,
                    arguments: args
                )
                messages.append(message, for: agent)

            case .toolCompleted(let agent, let result):
                guard let result else { break }
                // Check if result contains structured content cards
                if let cardMessage = parseContentCards(from: result) {
                    messages.append(cardMessage, for: agent)
                } else {
                    let message = Message.createAgentToolReturnedEvent(
                        agentName: agent,
                        result: result
                    )
                    messages.append(message, for: agent)
                }

            case .completed(let agent, let result, let structuredResult, let is_error):
                // Check for structured content cards in the result
                if let data = structuredResult, !is_error {
                    // Try to parse as EventCards (can add more card types here)
                    if let cardMessage = parseStructuredResult(data, for: agent) {
                        messages.append(cardMessage, for: agent)
                    }
                }

                let message = Message.createAgentCompletionEvent(
                    agentName: agent,
                    result: result,
                    is_error: is_error
                )
                messages.append(message, for: agent)

            case .error(let agent, let error):
                let message = Message.createAgentErrorEvent(
                    agentName: agent,
                    error: error
                )
                messages.append(message, for: agent)

            default: fatalError("we are not testing this right now")
            }
        }
    }

    // MARK: - Agent to Card Type Mapping

    /// Maps agent names to their corresponding card types
    /// The consumer (e.g., EnhancedMessageView) uses this type to decode the appropriate model
    /// NOTE: Keys must match the agent's `name` property exactly (camelCase)
    private static let agentCardTypes: [String: String] = [
        "calendarAgent": "event",
        "weatherAgent": "weather",
        "contactsAgent": "contact",
        "mapsAgent": "location",   // MapsAgent, not LocationAgent
        "financeAgent": "finance"
    ]

    /// Parse tool result for structured content cards (legacy string-based parsing)
    /// Returns a Message with contentCards if found, nil otherwise
    private func parseContentCards(from result: String) -> Message? {
        // Check for card JSON markers (legacy approach)
        let markers: [(prefix: String, type: String)] = [
            ("EVENT_CARDS_JSON:", "event"),
            ("WEATHER_CARDS_JSON:", "weather"),
            ("CONTACT_CARDS_JSON:", "contact"),
            ("LOCATION_CARDS_JSON:", "location"),
            ("FINANCE_CARDS_JSON:", "finance")
        ]

        for marker in markers {
            if result.hasPrefix(marker.prefix) {
                let jsonString = String(result.dropFirst(marker.prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                // Count items by parsing as generic array
                if let data = jsonString.data(using: .utf8),
                   let items = try? JSONDecoder().decode([AnyCodable].self, from: data) {
                    let count = items.count
                    let content = ContentCardsContent(
                        cardType: marker.type,
                        message: count > 0 ? "Found \(count) \(marker.type)\(count == 1 ? "" : "s")" : nil,
                        cardsJSON: jsonString,
                        cardCount: count
                    )
                    return Message.contentCards(content)
                }
            }
        }

        return nil
    }

    /// Parse structured result data from agent completion (new structured output approach)
    /// Returns a Message with contentCards if data matches a known card type
    private func parseStructuredResult(_ data: Data, for agent: String) -> Message? {
        // Determine card type from agent name
        guard let cardType = Self.agentCardTypes[agent] else {
            return nil
        }

        // Convert data to JSON string for storage
        guard let jsonString = String(data: data, encoding: .utf8) else {
            return nil
        }

        // Try to determine if it's a single item or array, and get count
        var cardCount = 1
        var cardsJSON = jsonString

        // Check if it's already an array
        if let items = try? JSONDecoder().decode([AnyCodable].self, from: data) {
            cardCount = items.count
        } else if (try? JSONDecoder().decode(AnyCodable.self, from: data)) != nil {
            // Single item - wrap in array for consistent handling
            cardsJSON = "[\(jsonString)]"
            cardCount = 1
        } else {
            return nil
        }

        let message: String? = cardCount > 0 ? "Found \(cardCount) \(cardType)\(cardCount == 1 ? "" : "s")" : nil

        let content = ContentCardsContent(
            cardType: cardType,
            message: message,
            cardsJSON: cardsJSON,
            cardCount: cardCount
        )
        return Message.contentCards(content)
    }
}

// MARK: - Generic JSON Wrapper for Type-Agnostic Parsing

/// A type-erased Codable wrapper for counting JSON items without knowing their concrete type
private struct AnyCodable: Codable {
    init(from decoder: Decoder) throws {
        // We don't need to store the value, just successfully decode it
        _ = try decoder.singleValueContainer()
    }

    func encode(to encoder: Encoder) throws {
        // Not needed for our use case
    }
}

extension Array<Message> {
    mutating func append(_ message: Message, for agent: String) {
        if let msg = last, case .agentEvent(var content) = msg.contentType, !content.hasCompleted {
            if content.agentName == agent {
                content.children.append(message)
                self.last?.contentType = .agentEvent(content)
                return
            } else if content.children.contains(message, for: agent) {
                content.children.append(message, for: agent)
                self.last?.contentType = .agentEvent(content)
                return
            }
        }
        self.append(message)
    }

    func contains(_ message: Message, for agent: String) -> Bool {
        for msg in self {
            if case .agentEvent(let content) = msg.contentType {
                if content.agentName == agent || content.children.contains(message, for: agent) {
                    return true
                }
            }
        }
        return false
    }
}

func +<E>(lhs: Array<E>?, rhs: Array<E>?) -> Array<E>? {
    if let lhs = lhs, let rhs = rhs {
        return lhs + rhs
    } else if let lhs = lhs {
        return lhs
    } else if let rhs = rhs {
        return rhs
    } else {
        return nil
    }
}
