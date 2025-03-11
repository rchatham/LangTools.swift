//
//  MessageService.swift
//
//  Created by Reid Chatham on 3/31/23.
//

import Foundation
import LangTools
import OpenAI
import Anthropic
import XAI
import Gemini
import Ollama
import Agents
import ChatUI
import SwiftUI

@Observable
class MessageService {
    let networkClient: NetworkClient
    var messages: [Message] = []

    init(networkClient: NetworkClient = NetworkClient.shared) {
        self.networkClient = networkClient
    }

    var tools: [Tool]? {
        return [
            .init(
                name: "getCurrentWeather",
                description: "Get the current weather",
                tool_schema: .init(
                    properties: [
                        "location": .init(
                            type: "string",
                            description: "The city and state, e.g. San Francisco, CA"),
                        "format": .init(
                            type: "string",
                            enumValues: ["celsius", "fahrenheit"],
                            description: "The temperature unit to use. Infer this from the users location.")
                    ],
                    required: ["location", "format"]),
                callback: { [weak self] in
                    self?.getCurrentWeather(location: $0["location"]!.stringValue!, format: $0["format"]!.stringValue!)
                }),
            .init(
                name: "getAnswerToUniverse",
                description: "The answer to the universe, life, and everything.",
                tool_schema: .init(),
                callback: { _ in
                    "42"
                }),
            .init(
                name: "getTopMichelinStarredRestaurants",
                description: "Get the top Michelin starred restaurants near a location",
                tool_schema: .init(
                    properties: [
                        "location": .init(
                            type: "string",
                            description: "The city and state, e.g. San Francisco, CA")
                    ],
                    required: ["location"]),
                callback: { [weak self] in
                    self?.getTopMichelinStarredRestaurants(location: $0["location"]!.stringValue!)
                }),

            // Calendar agent tool
            .init(
                name: "manage_calendar",
                description: """
                    Manage calendar events - create, read, update, or delete calendar events. 
                    Can handle natural language requests like "Schedule a meeting tomorrow" or 
                    "What's on my calendar next week?"
                    """,
                tool_schema: .init(
                    properties: [
                        "request": .init(
                            type: "string",
                            description: "The calendar-related request in natural language"
                        )
                    ],
                    required: ["request"]),
                callback: { [weak self] args in
                    guard let request = args["request"]?.stringValue else {
                        return "Invalid calendar request"
                    }
                    // TODO: - decide if this should spin off a separate async Task and add a message when it returns
                    return await self?.handleCalendarRequest(request)
                }),

            // Reminder agent tool
            .init(
                name: "manage_reminders",
                description: """
                    Manage reminders - create, read, update, or complete reminders. create, edit, or update reminder lists. 
                    Can handle natural language requests like "Remind me to call mom tomorrow" or 
                    "What are my upcoming reminders?"
                    """,
                tool_schema: .init(
                    properties: [
                        "request": .init(
                            type: "string",
                            description: "The reminder-related request in natural language"
                        )
                    ],
                    required: ["request"]),
                callback: { [weak self] args in
                    guard let request = args["request"]?.stringValue else {
                        return "Invalid reminder request"
                    }
                    return await self?.handleReminderRequest(request)
                }),

            // Research agent tool
            .init(
                name: "perform_research",
                description: """
                    Perform in-depth research on topics using internet sources and AI analysis. \
                    Can handle natural language requests like "Research quantum computing advances" or \
                    "What are the latest developments in AI safety?"
                    """,
                tool_schema: .init(
                    properties: [
                        "request": .init(
                            type: "string",
                            description: "The research request in natural language"
                        )
                    ],
                    required: ["request"]),
                callback: { [weak self] args in
                    guard let request = args["request"]?.stringValue else {
                        return "Invalid research request"
                    }
                    return await self?.handleResearchRequest(request)
                }),
        ]
    }

    func send(message: String, stream: Bool = false) async throws {
        await MainActor.run {
            messages.append(Message(text: message, role: .user))
        }

        var currentMessages = messages
        if !currentMessages.contains(where: { $0.isSystem }) {
            currentMessages.insert(Message(text: UserDefaults.systemMessage, role: .system), at: 0)
        }

        let toolChoice = (tools?.isEmpty ?? true) ? nil : OpenAI.ChatCompletionRequest.ToolChoice.auto
        var content: String = ""
        do {
            for try await chunk in try networkClient.streamChatCompletionRequest(messages: currentMessages, stream: stream, tools: tools, toolChoice: toolChoice) {
                content += chunk
                guard let last = messages.last else { continue }
                if !last.isAssistant {
                    if chunk.isEmpty { continue }
                    content = chunk.trimingLeadingNewlines()
                }
                let message = Message(uuid: last.isAssistant ? last.uuid : UUID(), role: .assistant, contentType: .string(content.trimingTrailingNewlines()))

                await MainActor.run {
                    if last.uuid == message.uuid { messages[messages.count - 1] = message }
                    else { messages.append(message) }
                }
            }
        } catch {
            if messages.last?.isAssistant ?? false {
                // TODO: - Should mark that the last message as errored
            } else {
                // remove last user message
                messages.removeLast()
            }
            throw error
        }
    }

    func handleCalendarRequest(_ request: String) async -> String {
        // Create a context for the calendar agent with the user's request
        let context = AgentContext(messages: [
            LangToolsMessageImpl<LangToolsTextContent>(
                role: .user,
                string: request
            )
        ]) { event in
            Task { await self.handleAgentEvent(event) }
        }

        // Execute the request through the calendar agent
        let calendarAgent = networkClient.calendarAgent()
        do {
            let response = try await calendarAgent.execute(context: context)
            return response
        } catch {
            return "Failed to handle request: \(error.localizedDescription)"
        }
    }

    func handleReminderRequest(_ request: String) async -> String {
        // Create a context for the reminder agent with the user's request
        let context = AgentContext(messages: [
            LangToolsMessageImpl<LangToolsTextContent>(
                role: .user,
                string: request
            )
        ]) { event in
            Task { await self.handleAgentEvent(event) }
        }

        // Execute the request through the reminder agent
        let reminderAgent = networkClient.reminderAgent()
        do {
            let response = try await reminderAgent.execute(context: context)
            return response
        } catch {
            return "Failed to handle request: \(error.localizedDescription)"
        }
    }

    func handleResearchRequest(_ request: String) async -> String {
        // Create a context for the reminder agent with the user's request
        let context = AgentContext(messages: [
            LangToolsMessageImpl<LangToolsTextContent>(
                role: .user,
                string: request
            )
        ]) { event in
            Task { await self.handleAgentEvent(event) }
        }

        // Execute the request through the reminder agent
        guard let researchAgent = networkClient.researchAgent() else { return "Failed to initialize ResearchAgent, need to update serper api key." }
        do {
            let response = try await researchAgent.execute(context: context)
            return response
        } catch {
            return "Failed to handle request: \(error.localizedDescription)"
        }
    }

    func deleteMessage(id: UUID) { messages.removeAll(where: { $0.uuid == id }) }
    func clearMessages() { messages.removeAll() }
    @objc func getCurrentWeather(location:String, format: String) -> String { return "27" }
    func getTopMichelinStarredRestaurants(location: String) -> String { return "The French Laundry" }
}

extension MessageService {
    func handleAgentEvent(_ event: AgentEvent) async {
        await MainActor.run {
            switch event {
            case .started(let agent, let parent, let task):
                if let parent {
                    messages.insert(.createStartEvent(agentName: agent, task: task), for: parent)
                } else {
                    messages.append(.createStartEvent(agentName: agent, task: task))
                }

            case .agentTransfer(let agent, let to, let reason):
                let message = Message.createDelegationEvent(
                    fromAgent: agent,
                    toAgent: to,
                    reason: reason
                )

                messages.insert(message, for: agent)

            case .toolCalled(let agent, let tool, let args):
                let message = Message.createToolCallEvent(
                    agentName: agent,
                    tool: tool,
                    arguments: args
                )

                messages.insert(message, for: agent)

            case .toolCompleted(agent: let agent, result: let result):
                let message = Message.createToolReturnedEvent(
                    agentName: agent,
                    result: result ?? "Missing agent result."
                )

                messages.insert(message, for: agent)

            case .completed(let agent, let result, let is_error):
                let message = Message.createCompletionEvent(
                    agentName: agent,
                    result: result
                )

                messages.insert(message, for: agent)

            case .error(let agent, let error):
                let message = Message.createErrorEvent(
                    agentName: agent,
                    error: error
                )

                messages.insert(message, for: agent)
            }
        }
    }
}

extension Array<Message> {
    mutating func insert(_ message: Message, for agent: String) {
        for (idx, msg) in self.enumerated() {
            if case .agentEvent(var content) = msg.contentType, !content.hasCompleted {
                if content.agentName == agent {
                    content.children.append(message)
                    self[idx].contentType = .agentEvent(content)
                    return
                } else if content.children.contains(message, for: agent) {
                    content.children.insert(message, for: agent)
                    self[idx].contentType = .agentEvent(content)
                    return
                }
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

extension String {
    func trimingTrailingNewlines() -> String {
        return trimingTrailingCharacters(using: .newlines)
    }

    func trimingTrailingCharacters(using characterSet: CharacterSet = .whitespacesAndNewlines) -> String {
        guard let index = lastIndex(where: { !CharacterSet(charactersIn: String($0)).isSubset(of: characterSet) }) else {
            return self
        }

        return String(self[...index])
    }

    func trimingLeadingNewlines() -> String {
        return trimingLeadingCharacters(using: .newlines)
    }

    func trimingLeadingCharacters(using characterSet: CharacterSet = .whitespacesAndNewlines) -> String {
        guard let index = firstIndex(where: { !CharacterSet(charactersIn: String($0)).isSubset(of: characterSet) }) else {
            return self
        }

        return String(self[index...])
    }
}
