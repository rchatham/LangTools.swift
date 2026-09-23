//
//  MessageService.swift
//
//  Created by Reid Chatham on 3/31/23.
//

import Agents
import ChatUI
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

    /// Transient flag set when a tool call completes during the current send,
    /// forcing the follow-up response to start a new assistant message.
    @ObservationIgnored private var toolBreakOccurred: Bool = false
    /// Ordered buffer of tool events fired by LangTools during a completion
    /// cycle. Drained on the main actor before each streamed chunk is processed
    /// so parallel tool calls all attach to the same message in order.
    @ObservationIgnored nonisolated(unsafe) private var pendingToolEvents: [LangToolsToolEvent] = []
    @ObservationIgnored nonisolated(unsafe) private var pendingAgentEvents: [AgentEvent] = []
    @ObservationIgnored nonisolated(unsafe) private let toolEventLock = NSLock()
    /// ids of tool calls made by agent-wrapped tools this send, so their lifecycle
    /// events can be skipped (agents surface their own UI via `handleAgentEvent`).
    @ObservationIgnored nonisolated(unsafe) private var agentCallIDs: Set<String> = []

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
                conversationID: requestConversationID
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

    private func performSend(message: String, stream: Bool, conversationID requestConversationID: UUID) async throws {
        guard conversationID == requestConversationID else { throw CancellationError() }
        // Reset per-send tool state so a prior send's break can't leak into this one.
        toolBreakOccurred = false
        clearPendingToolEvents()
        let userMessage = Message(text: message, role: .user)
        messages.append(userMessage)

        do {
            var currentMessages = messages
            currentMessages.insert(Message(text: systemMessage(), role: .system), at: 0)

            let activeTools = filteredTools

            // Agent tools surface their own UI via `handleAgentEvent`; skip their
            // tool-call events so they don't also render as ChatToolCall cards.
            let agentToolNames = Set(ToolManager.shared.allToolConfigurations().filter { $0.isAgent }.map { $0.id })
            let toolEventHandler: (LangToolsToolEvent) -> Void = { [weak self] event in
                guard let self else { return }
                switch event {
                case .toolCalled(let sel):
                    let id = sel.id ?? sel.name ?? ""
                    if agentToolNames.contains(sel.name ?? "") {
                        self.rememberAgentCall(id)
                        return
                    }
                    self.enqueueToolEvent(event)
                case .toolCompleted(let res):
                    if self.forgetAgentCall(res?.tool_selection_id ?? "") { return }
                    self.enqueueToolEvent(event)
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

            var content: String = ""
            for try await chunk in responseStream {
                guard conversationID == requestConversationID else { throw CancellationError() }
                // Apply any tool/agent events that fired since the last chunk (in order)
                // before processing this chunk, so a parallel batch of tool calls
                // all land on the same message and the follow-up text starts a new one.
                drainToolEvents()
                drainAgentEvents()

                content += chunk
                // Continue the last message only when it is a plain assistant text
                // message that has not been split by a tool-call break.
                let lastIsStreamable = messages.last.map { $0.isAssistant && $0.isStringContent && $0.toolCalls.isEmpty && !toolBreakOccurred } ?? false
                if !lastIsStreamable {
                    if chunk.isEmpty { continue }
                    content = chunk.trimingLeadingNewlines()
                }
                let messageUuid = if lastIsStreamable, let last = messages.last { last.uuid } else { UUID() }
                let trimmed = content.trimingTrailingNewlines()

                if let last = messages.last, last.uuid == messageUuid {
                    // Update the existing assistant message in place so tool-call
                    // state accumulated on it is preserved.
                    last.contentType = .string(trimmed)
                } else {
                    // Starting a new assistant message. If a tool-call break
                    // caused the split, the previous message retains its tool
                    // cards unless keepsToolCallsInHistory is disabled.
                    if toolBreakOccurred, let last = messages.last {
                        if !ToolSettings.shared.keepsToolCallsInHistory {
                            last.toolCalls = []
                        }
                        toolBreakOccurred = false
                    }
                    messages.append(Message(uuid: messageUuid, role: .assistant, contentType: .string(trimmed)))
                }
            }
            try Task.checkCancellation()
            guard conversationID == requestConversationID else { throw CancellationError() }
            // Flush any tool/agent events that fired after the last chunk (e.g. a tool
            // call with no follow-up response).
            drainToolEvents()
            drainAgentEvents()
        } catch {
            guard conversationID == requestConversationID else { throw CancellationError() }
            // Drop any tool events that fired but were never drained so they don't
            // attach to a future send's assistant message.
            clearPendingToolEvents()
            if messages.last?.isAssistant ?? false {
                // TODO: - Should mark the last message as errored
            } else {
                // remove last user message
                messages.removeLast()
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
    /// Buffers a tool event in arrival order for ordered main-actor draining.
    /// Called from LangTools' completion loop (off the main actor); the lock
    /// makes this safe without main-actor isolation.
    nonisolated func enqueueToolEvent(_ event: LangToolsToolEvent) {
        toolEventLock.lock()
        pendingToolEvents.append(event)
        toolEventLock.unlock()
    }

    /// Clears any buffered tool events without applying them.
    nonisolated func clearPendingToolEvents() {
        toolEventLock.lock()
        pendingToolEvents.removeAll()
        pendingAgentEvents.removeAll()
        agentCallIDs.removeAll()
        toolEventLock.unlock()
    }

    /// Records a tool-call id as belonging to an agent tool so its events are skipped.
    nonisolated func rememberAgentCall(_ id: String) {
        guard !id.isEmpty else { return }
        toolEventLock.lock()
        agentCallIDs.insert(id)
        toolEventLock.unlock()
    }

    /// Returns true (and removes the id) if the tool-call id belongs to an agent tool.
    nonisolated func forgetAgentCall(_ id: String) -> Bool {
        guard !id.isEmpty else { return false }
        toolEventLock.lock()
        defer { toolEventLock.unlock() }
        return agentCallIDs.remove(id) != nil
    }

    /// Applies all buffered tool events (in order) to the current assistant
    /// message on the main actor, then clears the buffer. Called before each
    /// streamed chunk so parallel tool calls attach to the same message. If the
    /// model made a tool call with no preceding text (no assistant message yet),
    /// an assistant message is created to hold the tool-call cards.
    func drainToolEvents() {
        toolEventLock.lock()
        let events = pendingToolEvents
        pendingToolEvents.removeAll()
        toolEventLock.unlock()
        guard !events.isEmpty else { return }
        if messages.last?.isAssistant != true {
            messages.append(Message(role: .assistant, contentType: .null))
        }
        guard let last = messages.last, last.isAssistant else { return }
        for event in events {
            last.applyToolEvent(event)
            if case .toolCompleted = event {
                toolBreakOccurred = true
            }
        }
    }
}

extension MessageService {
    /// Buffers an agent event in arrival order. Called from the agent framework
    /// (off the main actor); drained in order on the main actor by `drainAgentEvents`.
    nonisolated func handleAgentEvent(_ event: AgentEvent) {
        toolEventLock.lock()
        pendingAgentEvents.append(event)
        toolEventLock.unlock()
    }

    /// Applies all buffered agent events (in order) to the current assistant
    /// message's `toolCalls`, building agent cards with nested children.
    func drainAgentEvents() {
        toolEventLock.lock()
        let events = pendingAgentEvents
        pendingAgentEvents.removeAll()
        toolEventLock.unlock()
        guard !events.isEmpty, let last = messages.last, last.isAssistant else { return }
        for event in events {
            applyAgentEvent(event, to: last)
        }
    }

    @MainActor
    private func applyAgentEvent(_ event: AgentEvent, to last: Message) {
        switch event {
        case .started(let agent, let parent, let task):
            // If a delegation card already exists under `parent` (created by
            // agentTransfer/agentHandoff), update its details instead of creating
            // a duplicate — otherwise one card stays pending forever.
            if let parent {
                var calls = last.toolCalls
                if !Self.updateAgentChildDetails(agent, parent: parent, append: "started: \(task)", in: &calls) {
                    Self.appendChild(ChatToolCall(id: UUID().uuidString, name: agent, kind: .agent, status: .pending, details: "started: \(task)"), toAgent: parent, in: &calls)
                }
                last.toolCalls = calls
            } else {
                last.toolCalls.append(ChatToolCall(id: UUID().uuidString, name: agent, kind: .agent, status: .pending, details: "started: \(task)"))
            }

        case .agentTransfer(let agent, let to, let reason), .agentHandoff(let agent, let to, let reason):
            let label = event.isHandoff ? "handed off" : "delegated"
            let call = ChatToolCall(id: UUID().uuidString, name: to, kind: .agent, status: .pending, details: "\(label): \(reason)")
            var calls = last.toolCalls
            Self.appendChild(call, toAgent: agent, in: &calls)
            last.toolCalls = calls

        case .toolCalled(let agent, let tool, let args):
            let call = ChatToolCall(id: UUID().uuidString, name: tool, kind: .tool, arguments: args, status: .pending)
            var calls = last.toolCalls
            Self.appendChild(call, toAgent: agent, in: &calls)
            last.toolCalls = calls

        case .toolCompleted(let agent, let result):
            // result can be nil when a tool produces no output; still complete the
            // pending child so it doesn't stay stuck on the spinner.
            var calls = last.toolCalls
            Self.completePendingChild(ofAgent: agent, result: result ?? "", status: .success, in: &calls)
            last.toolCalls = calls

        case .completed(let agent, let result, let is_error):
            var calls = last.toolCalls
            let status: ChatToolCall.Status = is_error ? .failure : .success
            if !is_error, let cardMessage = agentResultParser?(result, agent) {
                Self.setAgentStatus(agent, status: .success, result: nil, in: &calls)
                Self.completeRemainingPending(ofAgent: agent, status: .success, in: &calls)
                last.toolCalls = calls
                toolBreakOccurred = true
                messages.append(cardMessage)
            } else {
                Self.setAgentStatus(agent, status: status, result: result, in: &calls)
                Self.completeRemainingPending(ofAgent: agent, status: status, in: &calls)
                last.toolCalls = calls
                toolBreakOccurred = true
            }

        case .error(let agent, let message):
            // A tool error: complete the pending tool child as a failure. The agent
            // itself may continue, so do NOT mark the agent failed here; `completed`
            // handles agent status. (If this is an agent-level error, there is no
            // pending child to complete, which is harmless.)
            var calls = last.toolCalls
            Self.completePendingChild(ofAgent: agent, result: message, status: .failure, in: &calls)
            last.toolCalls = calls

        default: break
        }
    }

    /// Recursively appends a child tool call under the agent call named `agent`.
    @MainActor
    static func appendChild(_ child: ChatToolCall, toAgent agent: String, in calls: inout [ChatToolCall]) {
        for i in calls.indices {
            if calls[i].kind == .agent && calls[i].name == agent {
                calls[i].children.append(child)
                return
            }
            appendChild(child, toAgent: agent, in: &calls[i].children)
        }
    }

    /// If the agent named `agent` already has a child agent named `agent` under
    /// `parent`, append `append` to that child's details (deduping delegations).
    @MainActor
    static func updateAgentChildDetails(_ agent: String, parent: String, append details: String, in calls: inout [ChatToolCall]) -> Bool {
        for i in calls.indices {
            if calls[i].kind == .agent && calls[i].name == parent {
                if let j = calls[i].children.firstIndex(where: { $0.kind == .agent && $0.name == agent }) {
                    calls[i].children[j].details = [calls[i].children[j].details, details].compactMap { $0 }.joined(separator: "\n")
                    return true
                }
                return false
            }
            if updateAgentChildDetails(agent, parent: parent, append: details, in: &calls[i].children) { return true }
        }
        return false
    }

    /// Completes the oldest pending child of the agent call named `agent`.
    /// `AgentEvent.toolCompleted`/`.error` carry no tool name, so match in call
    /// order (FIFO) — robust for both sequential and concurrent tool calls.
    @MainActor
    static func completePendingChild(ofAgent agent: String, result: String, status: ChatToolCall.Status, in calls: inout [ChatToolCall]) {
        for i in calls.indices {
            if calls[i].kind == .agent && calls[i].name == agent {
                if let idx = calls[i].children.firstIndex(where: { $0.status == .pending }) {
                    calls[i].children[idx].status = status
                    calls[i].children[idx].result = result
                }
                return
            }
            completePendingChild(ofAgent: agent, result: result, status: status, in: &calls[i].children)
        }
    }

    /// Marks any still-pending direct children of the agent as `status`. Safety
    /// net so no child stays on the spinner once the agent has terminated.
    @MainActor
    static func completeRemainingPending(ofAgent agent: String, status: ChatToolCall.Status, in calls: inout [ChatToolCall]) {
        for i in calls.indices {
            if calls[i].kind == .agent && calls[i].name == agent {
                for j in calls[i].children.indices where calls[i].children[j].status == .pending {
                    calls[i].children[j].status = status
                }
                return
            }
            completeRemainingPending(ofAgent: agent, status: status, in: &calls[i].children)
        }
    }

    /// Sets the status/result of the agent call named `agent`.
    @MainActor
    static func setAgentStatus(_ agent: String, status: ChatToolCall.Status, result: String?, in calls: inout [ChatToolCall]) {
        for i in calls.indices {
            if calls[i].kind == .agent && calls[i].name == agent {
                calls[i].status = status
                if let result { calls[i].result = result }
                return
            }
            setAgentStatus(agent, status: status, result: result, in: &calls[i].children)
        }
    }
}

private extension AgentEvent {
    var isHandoff: Bool {
        if case .agentHandoff = self { return true }
        return false
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
