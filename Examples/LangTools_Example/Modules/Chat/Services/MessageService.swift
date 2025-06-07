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
import SwiftUI

@Observable
public class MessageService {
    public let networkClient: NetworkClient
    public var messages: [Message] = []
    var tools: [Tool]?

    /// Returns a filtered list of tools based on tool settings
    var filteredTools: [Tool]? {
        // Return nil if master tool switch is disabled
        guard ToolSettings.shared.toolsEnabled else { return nil }

        // If tools exist, filter them based on individual tool settings
        return tools?.filter { ToolSettings.shared.isToolEnabled(name: $0.name) }
    }

    public init(networkClient: NetworkClient = NetworkClient.shared, agents: [Agent]? = nil, tools: [Tool]? = nil) {
        self.networkClient = networkClient
        self.tools = agents?.map { .init(agent: $0, eventHandler: handleAgentEvent) } + tools
    }

    public func send(message: String, stream: Bool = false) async throws {
        await MainActor.run {
            messages.append(Message(text: message, role: .user))
        }

        var currentMessages = messages
        currentMessages.insert(Message(text: systemMessage(), role: .system), at: 0)

        var content: String = ""
        do {
            for try await chunk in try networkClient.streamChatCompletionRequest(messages: currentMessages, stream: stream, tools: filteredTools) {
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
//
//            case .agentHandoff(let agent, let to, let reason):
//                let message = Message.createHandoffEvent(
//                    fromAgent: agent,
//                    toAgent: to,
//                    reason: reason
//                )
//
//                messages.insert(message, for: agent)

            case .toolCalled(let agent, let tool, let args):
                let message = Message.createToolCallEvent(
                    agentName: agent,
                    tool: tool,
                    arguments: args
                )

                messages.insert(message, for: agent)

            case .toolCompleted(let agent, let result):
                guard let result else { break }
                let message = Message.createToolReturnedEvent(
                    agentName: agent,
                    result: result // ?? "Missing agent result."
                )

                messages.insert(message, for: agent)

            case .completed(let agent, let result, let is_error):
                let message = Message.createCompletionEvent(
                    agentName: agent,
                    result: result,
                    is_error: is_error
                )

                messages.insert(message, for: agent)

            case .error(let agent, let error):
                let message = Message.createErrorEvent(
                    agentName: agent,
                    error: error
                )

                messages.insert(message, for: agent)

            default: fatalError("we are not testing this right now")
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
