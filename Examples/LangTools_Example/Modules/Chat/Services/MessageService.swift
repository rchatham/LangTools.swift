//
//  MessageService.swift
//
//  Created by Reid Chatham on 3/31/23.
//

import Agents
import Foundation
import LangTools

var useMultiAgent: Bool = false

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

    /// Returns a filtered list of tools based on tool settings
    var filteredTools: [Tool]? {
        // Return nil if master tool switch is disabled
        guard ToolSettings.shared.toolsEnabled else { return nil }

        // If tools exist, filter them based on individual tool settings
        return tools?.filter { ToolSettings.shared.isToolEnabled(name: $0.name) }
    }

    public init(networkClient: NetworkClientProtocol = NetworkClient.shared, agents: [Agent]? = nil, tools: [Tool]? = nil) {
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

            var content: String = ""
            for try await chunk in try networkClient.streamChatCompletionRequest(messages: currentMessages, stream: stream, tools: filteredTools) {
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
                let message = Message.createAgentToolReturnedEvent(
                    agentName: agent,
                    result: result
                )
                messages.append(message, for: agent)

            case .completed(let agent, let result, let is_error):
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
