//
//  MessageService.swift
//
//  Created by Reid Chatham on 3/31/23.
//

import Agents
import Foundation
import LangTools
import ToolKit


@MainActor
@Observable
public class MessageService {
    public let networkClient: NetworkClientProtocol
    public var messages: [Message] = [] {
        didSet {
            if let last = messages.last {
                messageUpdatedCallback?(last)
            }
        }
    }
    var tools: [Tool]?
    private(set) var conversationID = UUID()
    private var activeSends: [UUID: [UUID: Task<Void, Error>]] = [:]

    /// Ordered buffers of tool events fired by LangTools during each completion
    /// cycle. Events are keyed by send so concurrent streams cannot consume or
    /// discard one another's tool history.
    @ObservationIgnored nonisolated(unsafe) private var pendingToolEventsBySendID: [UUID: [LangToolsToolEvent]] = [:]
    @ObservationIgnored nonisolated(unsafe) private let toolEventLock = NSLock()
    /// Callback fired when a message is added or modified (for persistence)
    public var messageUpdatedCallback: ((Message) -> Void)?

    /// Optional hook called when an agent completes with a non-error result.
    /// Receives the raw result string and the agent name; return a `Message` to
    /// display it as structured content, or `nil` to fall through to the default
    /// agent-completion event rendering.
    /// Register this from the app target to keep `Chat` agnostic of specific agents.
    public var agentResultParser: ((_ result: String, _ agentName: String) -> Message?)?

    /// Snapshot of tools filtered by the current ToolManager state.
    /// Delegates to `ToolManager.filteredTools()` for the enabled-id set, then
    /// intersects with `self.tools` so future changes to ToolManager filtering
    /// logic are automatically picked up here.
    /// Hops to the main actor because ToolManager is @MainActor-isolated.
    @MainActor
    var filteredTools: [Tool]? {
        guard let enabledTools = ToolManager.shared.filteredTools() else { return nil }
        let enabledNames = Set(enabledTools.map { $0.name })
        // Agent tools come from `self.tools` (they carry the agent event handler).
        var result: [Tool] = (tools ?? []).filter { enabledNames.contains($0.name) }
        // Non-agent configs provide their own callbacks and are not in `self.tools`.
        let selfToolNames = Set((tools ?? []).map { $0.name })
        for config in ToolManager.shared.allToolConfigurations() where !config.isAgent && enabledNames.contains(config.id) && !selfToolNames.contains(config.id) {
            result.append(Tool(config.toTool()))
        }
        return result
    }

    public init(networkClient: NetworkClientProtocol = NetworkClient.shared, agents: [any Agent]? = nil, tools: [Tool]? = nil) {
        self.networkClient = networkClient
        self.tools = agents?.map { .init(agent: $0, eventHandler: handleAgentEvent) } + tools
    }

    public func send(message: String, stream: Bool = false) async throws {
        let requestConversationID = conversationID
        let sendID = UUID()
        let operation = Task { @MainActor in
            try await performSend(
                message: message,
                stream: stream,
                conversationID: requestConversationID,
                sendID: sendID
            )
        }
        activeSends[requestConversationID, default: [:]][sendID] = operation
        defer { removeActiveSend(id: sendID, conversationID: requestConversationID) }

        try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: {
            operation.cancel()
        }
    }

    private func performSend(message: String, stream: Bool, conversationID requestConversationID: UUID, sendID: UUID) async throws {
        guard conversationID == requestConversationID else { throw CancellationError() }
        beginToolEventBuffer(for: sendID)
        defer { clearPendingToolEvents(for: sendID) }

        let userMessage = Message(text: message, role: .user)
        messages.append(userMessage)
        var assistantMessageID: UUID?
        var assistantMessageIDs: Set<UUID> = []

        do {
            var currentMessages = messages
            currentMessages.insert(Message(text: systemMessage(), role: .system), at: 0)

            let activeTools = filteredTools

            // Agent tools surface their own UI via `handleAgentEvent`; skip their
            // tool-call events so they don't also render as ChatToolCall cards.
            // Remaining tool events are buffered per send; they are drained in
            // order on the main actor before each chunk below so parallel tool
            // calls all attach to this send's assistant message.
            let agentToolNames = Set(ToolManager.shared.allToolConfigurations().filter { $0.isAgent }.map { $0.id })
            var rememberedAgentCallIDs: Set<String> = []
            let toolEventHandler: (LangToolsToolEvent) -> Void = { [weak self] event in
                guard let self else { return }
                switch event {
                case .toolCalled(let sel):
                    let id = sel.id ?? sel.name ?? ""
                    if agentToolNames.contains(sel.name ?? "") {
                        if !id.isEmpty { rememberedAgentCallIDs.insert(id) }
                        return
                    }
                    self.enqueueToolEvent(event, for: sendID)
                case .toolCompleted(let res):
                    if let id = res?.tool_selection_id, rememberedAgentCallIDs.remove(id) != nil { return }
                    self.enqueueToolEvent(event, for: sendID)
                }
            }

            let selectedModel = UserDefaults.model
            let responseStream: AsyncThrowingStream<String, Error>
            if let conversationClient = networkClient as? any ConversationAwareNetworkClientProtocol {
                responseStream = try conversationClient.streamChatCompletionRequest(
                    messages: currentMessages,
                    model: selectedModel,
                    conversationID: requestConversationID,
                    stream: stream,
                    tools: activeTools,
                    toolChoice: nil,
                    toolEventHandler: toolEventHandler
                )
            } else {
                responseStream = try networkClient.streamChatCompletionRequest(
                    messages: currentMessages,
                    model: selectedModel,
                    stream: stream,
                    tools: activeTools,
                    toolChoice: nil,
                    toolEventHandler: toolEventHandler
                )
            }

            var content = ""
            for try await chunk in responseStream {
                guard conversationID == requestConversationID else { throw CancellationError() }
                // Apply this send's tool events before its next chunk. A completed
                // call splits follow-up text into a new assistant message.
                if drainToolEvents(
                    for: sendID,
                    assistantMessageID: &assistantMessageID,
                    assistantMessageIDs: &assistantMessageIDs
                ) {
                    if let assistantMessageID,
                       !ToolSettings.shared.keepsToolCallsInHistory,
                       let toolMessage = messages.first(where: { $0.uuid == assistantMessageID }) {
                        toolMessage.toolCalls = []
                    }
                    assistantMessageID = nil
                    content = ""
                }

                guard !chunk.isEmpty else { continue }
                content += assistantMessageID == nil ? chunk.trimingLeadingNewlines() : chunk
                let trimmed = content.trimingTrailingNewlines()

                if let assistantMessageID,
                   let assistantMessage = messages.first(where: { $0.uuid == assistantMessageID }) {
                    assistantMessage.contentType = .string(trimmed)
                } else {
                    let assistantMessage = Message(role: .assistant, contentType: .string(trimmed))
                    messages.append(assistantMessage)
                    assistantMessageID = assistantMessage.uuid
                    assistantMessageIDs.insert(assistantMessage.uuid)
                }
            }
            try Task.checkCancellation()
            guard conversationID == requestConversationID else { throw CancellationError() }
            // Flush any tool events that fired after the last chunk (e.g. a tool
            // call with no follow-up response).
            _ = drainToolEvents(
                for: sendID,
                assistantMessageID: &assistantMessageID,
                assistantMessageIDs: &assistantMessageIDs
            )
            failPendingToolCalls(
                in: assistantMessageIDs,
                reason: "Tool call ended without a completion result."
            )
        } catch {
            guard conversationID == requestConversationID else { throw CancellationError() }
            // A nested follow-up can fail after tools have already emitted their
            // lifecycle events but before yielding text. Preserve those events and
            // mark every incomplete call owned by this send as failed.
            _ = drainToolEvents(
                for: sendID,
                assistantMessageID: &assistantMessageID,
                assistantMessageIDs: &assistantMessageIDs
            )
            if assistantMessageIDs.isEmpty {
                messages.removeAll(where: { $0.uuid == userMessage.uuid })
            } else {
                failPendingToolCalls(in: assistantMessageIDs, reason: error.localizedDescription)
            }
            throw error
        }
    }

    private func removeActiveSend(id: UUID, conversationID: UUID) {
        activeSends[conversationID]?.removeValue(forKey: id)
        if activeSends[conversationID]?.isEmpty == true {
            activeSends.removeValue(forKey: conversationID)
        }
    }

    func systemMessage() -> String {
        UserDefaults.systemMessage + "\n\nWhen agent tools return results, those results are displayed visually to the user as content cards. Do not repeat or summarize information already shown in the cards. You may add a brief natural-language acknowledgment but should not list out details the user can already see. Answer follow-up questions about the content if asked. If an agent tool returns an error, explain the error to the user."
    }

    public func deleteMessage(id: UUID) { messages.removeAll(where: { $0.uuid == id }) }

    public func clearMessages() {
        let previousConversationID = conversationID
        let sendsToDrain = activeSends.removeValue(forKey: previousConversationID).map { Array($0.values) } ?? []
        conversationID = UUID()
        messages.removeAll()
        sendsToDrain.forEach { $0.cancel() }

        let conversationClient = networkClient as? any ConversationAwareNetworkClientProtocol
        Task {
            for send in sendsToDrain {
                _ = await send.result
            }
            await conversationClient?.endConversation(id: previousConversationID)
        }
    }
}

extension MessageService {
    /// Registers a send before its callback can emit tool events.
    nonisolated func beginToolEventBuffer(for sendID: UUID) {
        toolEventLock.lock()
        pendingToolEventsBySendID[sendID] = []
        toolEventLock.unlock()
    }

    /// Buffers a tool event in arrival order for ordered main-actor draining.
    /// Called from LangTools' completion loop (off the main actor); the lock
    /// makes this safe without main-actor isolation.
    nonisolated func enqueueToolEvent(_ event: LangToolsToolEvent, for sendID: UUID) {
        toolEventLock.lock()
        if pendingToolEventsBySendID[sendID] != nil {
            pendingToolEventsBySendID[sendID, default: []].append(event)
        }
        toolEventLock.unlock()
    }

    /// Clears one send's buffered tool events without affecting concurrent sends.
    nonisolated func clearPendingToolEvents(for sendID: UUID) {
        toolEventLock.lock()
        pendingToolEventsBySendID.removeValue(forKey: sendID)
        toolEventLock.unlock()
    }

    /// Applies one send's buffered events to its current assistant message and
    /// returns whether a completed call requires follow-up text to start a new
    /// message. If no assistant message exists yet, one is created for the cards.
    @discardableResult
    func drainToolEvents(
        for sendID: UUID,
        assistantMessageID: inout UUID?,
        assistantMessageIDs: inout Set<UUID>
    ) -> Bool {
        toolEventLock.lock()
        let events = pendingToolEventsBySendID[sendID] ?? []
        if pendingToolEventsBySendID[sendID] != nil {
            pendingToolEventsBySendID[sendID] = []
        }
        toolEventLock.unlock()
        guard !events.isEmpty else { return false }

        let assistantMessage: Message
        if let assistantMessageID,
           let existingMessage = messages.first(where: { $0.uuid == assistantMessageID }) {
            assistantMessage = existingMessage
        } else {
            assistantMessage = Message(role: .assistant, contentType: .null)
            messages.append(assistantMessage)
            assistantMessageID = assistantMessage.uuid
        }
        assistantMessageIDs.insert(assistantMessage.uuid)

        var completedToolCall = false
        for event in events {
            assistantMessage.applyToolEvent(event)
            if case .toolCompleted = event {
                completedToolCall = true
            }
        }
        return completedToolCall
    }

    private func failPendingToolCalls(in assistantMessageIDs: Set<UUID>, reason: String) {
        for message in messages where assistantMessageIDs.contains(message.uuid) {
            message.failPendingToolCalls(reason: reason)
        }
    }
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
                // Give the app-level parser first crack at structured results.
                // Append at the top level so content cards appear in the main conversation.
                // agentResultParser is the injection point for structured agent results.
                // ContentCardRegistry.shared.agentResultParser provides the default implementation.
                if !is_error, let cardMessage = agentResultParser?(result, agent) {
                    messages.append(cardMessage)
                } else {
                    let message = Message.createAgentCompletionEvent(
                        agentName: agent,
                        result: result,
                        is_error: is_error
                    )
                    messages.append(message, for: agent)
                }

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
