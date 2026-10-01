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

private enum BufferedMessageEvent {
    case tool(LangToolsToolEvent)
    case agent(AgentEvent)
}

private enum SendUpdate {
    case responseChunk(String)
    case eventsAvailable
}

private struct PendingToolCallIdentity {
    let anchorMessageID: UUID
    let uiCallID: String
}

@MainActor
private final class RequestToolCallTracker {
    private var pendingCallsBySelectionID: [String: [PendingToolCallIdentity]] = [:]
    private var pendingCallsWithoutSelectionID: [PendingToolCallIdentity] = []

    func append(selectionID: String?, anchorMessageID: UUID, uiCallID: String) {
        let identity = PendingToolCallIdentity(anchorMessageID: anchorMessageID, uiCallID: uiCallID)
        guard let selectionID, !selectionID.isEmpty else {
            pendingCallsWithoutSelectionID.append(identity)
            return
        }
        pendingCallsBySelectionID[selectionID, default: []].append(identity)
    }

    func dequeue(selectionID: String) -> PendingToolCallIdentity? {
        guard !selectionID.isEmpty else {
            guard !pendingCallsWithoutSelectionID.isEmpty else { return nil }
            return pendingCallsWithoutSelectionID.removeFirst()
        }
        guard var pendingCalls = pendingCallsBySelectionID[selectionID],
              !pendingCalls.isEmpty
        else { return nil }

        let identity = pendingCalls.removeFirst()
        if pendingCalls.isEmpty {
            pendingCallsBySelectionID.removeValue(forKey: selectionID)
        } else {
            pendingCallsBySelectionID[selectionID] = pendingCalls
        }
        return identity
    }
}

private struct AgentReplayArguments: Encodable {
    let reason: String
}

/// Thread-safe request-scoped event storage. Provider and agent callbacks can
/// arrive off the main actor, so they only enqueue here; rendering remains on
/// `MessageService`'s main actor.
private final class SendEventBuffer: @unchecked Sendable {
    private struct State {
        var events: [BufferedMessageEvent] = []
        var agentCallIDCounts: [String: Int] = [:]
        var eventContinuation: AsyncStream<Void>.Continuation?
    }

    private let lock = NSLock()
    private var states: [UUID: State] = [:]

    func register(_ sendID: UUID) -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        lock.withLock {
            states[sendID] = State(eventContinuation: continuation)
        }
        return stream
    }

    func registerIfNeeded(_ sendID: UUID) {
        lock.withLock {
            if states[sendID] == nil {
                states[sendID] = State()
            }
        }
    }

    func remove(_ sendID: UUID) {
        let continuation = lock.withLock {
            states.removeValue(forKey: sendID)?.eventContinuation
        }
        continuation?.finish()
    }

    func enqueueAgent(_ event: AgentEvent, for sendID: UUID) {
        let continuation: AsyncStream<Void>.Continuation? = lock.withLock {
            guard states[sendID] != nil else { return nil }
            states[sendID]?.events.append(.agent(event))
            return states[sendID]?.eventContinuation
        }
        continuation?.yield()
    }

    func enqueueTool(_ event: LangToolsToolEvent, for sendID: UUID, agentToolNames: Set<String>) {
        let continuation: AsyncStream<Void>.Continuation? = lock.withLock {
            guard var state = states[sendID] else { return nil }
            switch event {
            case .toolCalled(let selection):
                let id = selection.id ?? selection.name ?? ""
                if agentToolNames.contains(selection.name ?? "") {
                    if !id.isEmpty {
                        state.agentCallIDCounts[id, default: 0] += 1
                    }
                    states[sendID] = state
                    return nil
                }
            case .toolCompleted(let result):
                let id = result?.tool_selection_id ?? ""
                if !id.isEmpty, let count = state.agentCallIDCounts[id], count > 0 {
                    if count == 1 {
                        state.agentCallIDCounts.removeValue(forKey: id)
                    } else {
                        state.agentCallIDCounts[id] = count - 1
                    }
                    states[sendID] = state
                    return nil
                }
            }
            state.events.append(.tool(event))
            states[sendID] = state
            return state.eventContinuation
        }
        continuation?.yield()
    }

    func takeEvents(for sendID: UUID) -> [BufferedMessageEvent] {
        lock.withLock {
            guard var state = states[sendID] else { return [] }
            let events = state.events
            state.events.removeAll(keepingCapacity: true)
            states[sendID] = state
            return events
        }
    }

    var eventCount: Int {
        lock.withLock { states.values.reduce(0) { $0 + $1.events.count } }
    }
}

@MainActor
@Observable
public class MessageService {
    public let networkClient: NetworkClientProtocol
    public var messages: [Message] = [] {
        didSet {
            if let last = messages.last {
                notifyMessageUpdated(
                    last,
                    keepsToolCallsInHistory: ToolSettings.shared.keepsToolCallsInHistory
                )
            }
        }
    }
    var tools: [Tool]?
    @ObservationIgnored private let agents: [any Agent]
    private(set) var conversationID = UUID()
    private var activeSends: [UUID: [UUID: Task<Void, Error>]] = [:]
    @ObservationIgnored private let eventBuffer = SendEventBuffer()
    /// Retains the pre-request test/helper API without sharing production send state.
    @ObservationIgnored private let compatibilitySendID = UUID()

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
    func filteredTools(for sendID: UUID) -> [Tool]? {
        guard let enabledTools = ToolManager.shared.filteredTools() else { return nil }
        let enabledNames = Set(enabledTools.map { $0.name })
        let agentTools = agents
            .filter { enabledNames.contains($0.name) }
            .map { agent in
                Tool(agent: agent) { [weak self] event in
                    self?.enqueueAgentEvent(event, for: sendID)
                }
            }
        var result = agentTools + (tools ?? []).filter { enabledNames.contains($0.name) }
        let suppliedToolNames = Set(result.map { $0.name })
        for config in ToolManager.shared.allToolConfigurations() where !config.isAgent && enabledNames.contains(config.id) && !suppliedToolNames.contains(config.id) {
            result.append(Tool(config.toTool()))
        }
        return result
    }

    public init(networkClient: NetworkClientProtocol = NetworkClient.shared, agents: [any Agent]? = nil, tools: [Tool]? = nil) {
        self.networkClient = networkClient
        self.agents = agents ?? []
        self.tools = tools
    }

    public func send(message: String, stream: Bool = false) async throws {
        let requestConversationID = conversationID
        let sendID = UUID()
        let eventNotifications = eventBuffer.register(sendID)
        let operation = Task { @MainActor in
            try await performSend(
                message: message,
                stream: stream,
                conversationID: requestConversationID,
                sendID: sendID,
                eventNotifications: eventNotifications
            )
        }
        activeSends[requestConversationID, default: [:]][sendID] = operation
        defer {
            eventBuffer.remove(sendID)
            removeActiveSend(id: sendID, conversationID: requestConversationID)
        }

        try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: {
            operation.cancel()
        }
    }

    private func performSend(
        message: String,
        stream: Bool,
        conversationID requestConversationID: UUID,
        sendID: UUID,
        eventNotifications: AsyncStream<Void>
    ) async throws {
        guard conversationID == requestConversationID else { throw CancellationError() }
        let userMessage = Message(text: message, role: .user)
        let userMessageID = userMessage.uuid
        messages.append(userMessage)
        var anchorMessageID: UUID?
        var assistantMessageIDs: Set<UUID> = []
        var toolBreakOccurred = false
        let toolCallTracker = RequestToolCallTracker()
        let keepsToolCallsInHistory = ToolSettings.shared.keepsToolCallsInHistory
        let selectedModel = UserDefaults.model
        let replayService = selectedModel.apiService

        do {
            var currentMessages = requestMessages(keepsToolCallsInHistory: keepsToolCallsInHistory)
            currentMessages.insert(Message(text: systemMessage(), role: .system), at: 0)

            let activeTools = filteredTools(for: sendID)
            let agentToolNames = Set(agents.map(\.name))
            let toolEventHandler: (LangToolsToolEvent) -> Void = { [weak self] event in
                self?.enqueueToolEvent(event, for: sendID, agentToolNames: agentToolNames)
            }

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
            let updates = Self.merge(
                responseStream: responseStream,
                eventNotifications: eventNotifications
            )
            for try await update in updates {
                guard conversationID == requestConversationID else { throw CancellationError() }
                drainEvents(
                    for: sendID,
                    anchorMessageID: &anchorMessageID,
                    toolBreakOccurred: &toolBreakOccurred,
                    keepsToolCallsInHistory: keepsToolCallsInHistory,
                    replayService: replayService,
                    toolCallTracker: toolCallTracker
                )
                if let anchorMessageID { assistantMessageIDs.insert(anchorMessageID) }
                guard case .responseChunk(let chunk) = update else { continue }

                content += chunk
                let anchor = assistantMessage(withID: anchorMessageID)
                let anchorIsStreamable = anchor.map {
                    $0.isAssistant && $0.isStringContent && $0.toolCalls.isEmpty && !toolBreakOccurred
                } ?? false
                if !anchorIsStreamable {
                    if chunk.isEmpty { continue }
                    content = chunk.trimingLeadingNewlines()
                }
                let trimmed = content.trimingTrailingNewlines()

                if anchorIsStreamable, let anchor {
                    anchor.contentType = .string(trimmed)
                    notifyMessageUpdated(anchor, keepsToolCallsInHistory: keepsToolCallsInHistory)
                } else {
                    if toolBreakOccurred {
                        clearToolHistoryIfNeeded(
                            for: anchorMessageID,
                            keepsToolCallsInHistory: keepsToolCallsInHistory
                        )
                        toolBreakOccurred = false
                    }
                    let responseMessage = Message(role: .assistant, contentType: .string(trimmed))
                    anchorMessageID = responseMessage.uuid
                    assistantMessageIDs.insert(responseMessage.uuid)
                    messages.append(responseMessage)
                }
            }
            try Task.checkCancellation()
            guard conversationID == requestConversationID else { throw CancellationError() }
            drainEvents(
                for: sendID,
                anchorMessageID: &anchorMessageID,
                toolBreakOccurred: &toolBreakOccurred,
                keepsToolCallsInHistory: keepsToolCallsInHistory,
                replayService: replayService,
                toolCallTracker: toolCallTracker
            )
            if let anchorMessageID { assistantMessageIDs.insert(anchorMessageID) }
            clearToolHistoryIfNeeded(
                in: assistantMessageIDs,
                keepsToolCallsInHistory: keepsToolCallsInHistory
            )
            failPendingToolCalls(
                in: assistantMessageIDs,
                reason: "Tool call ended without a completion result."
            )
        } catch {
            guard conversationID == requestConversationID else { throw CancellationError() }
            // Preserve lifecycle events that fired before the failure, then run
            // the same terminal cleanup as a successful stream.
            drainEvents(
                for: sendID,
                anchorMessageID: &anchorMessageID,
                toolBreakOccurred: &toolBreakOccurred,
                keepsToolCallsInHistory: keepsToolCallsInHistory,
                replayService: replayService,
                toolCallTracker: toolCallTracker
            )
            if let anchorMessageID { assistantMessageIDs.insert(anchorMessageID) }
            clearToolHistoryIfNeeded(
                in: assistantMessageIDs,
                keepsToolCallsInHistory: keepsToolCallsInHistory
            )
            if anchorMessageID == nil {
                messages.removeAll { $0.uuid == userMessageID }
            }
            failPendingToolCalls(
                in: assistantMessageIDs,
                reason: error.localizedDescription
            )
            throw error
        }
    }

    nonisolated private static func merge(
        responseStream: AsyncThrowingStream<String, Error>,
        eventNotifications: AsyncStream<Void>
    ) -> AsyncThrowingStream<SendUpdate, Error> {
        AsyncThrowingStream { continuation in
            let responseTask = Task {
                do {
                    for try await chunk in responseStream {
                        try Task.checkCancellation()
                        continuation.yield(.responseChunk(chunk))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            let eventTask = Task {
                for await _ in eventNotifications {
                    guard !Task.isCancelled else { return }
                    continuation.yield(.eventsAvailable)
                }
            }
            continuation.onTermination = { @Sendable _ in
                responseTask.cancel()
                eventTask.cancel()
            }
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
        let sends = activeSends.removeValue(forKey: previousConversationID) ?? [:]
        let sendsToDrain = Array(sends.values)
        sends.keys.forEach { eventBuffer.remove($0) }
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
    nonisolated private func enqueueToolEvent(_ event: LangToolsToolEvent, for sendID: UUID, agentToolNames: Set<String>) {
        eventBuffer.enqueueTool(event, for: sendID, agentToolNames: agentToolNames)
    }

    nonisolated private func enqueueAgentEvent(_ event: AgentEvent, for sendID: UUID) {
        eventBuffer.enqueueAgent(event, for: sendID)
    }

    /// Compatibility helpers used by focused mapping tests. Production callbacks
    /// always use a request-specific send id.
    nonisolated func enqueueToolEvent(_ event: LangToolsToolEvent) {
        eventBuffer.registerIfNeeded(compatibilitySendID)
        eventBuffer.enqueueTool(event, for: compatibilitySendID, agentToolNames: [])
    }

    nonisolated func handleAgentEvent(_ event: AgentEvent) {
        eventBuffer.registerIfNeeded(compatibilitySendID)
        eventBuffer.enqueueAgent(event, for: compatibilitySendID)
    }

    func drainToolEvents() {
        drainCompatibilityEvents()
    }

    func drainAgentEvents() {
        drainCompatibilityEvents()
    }

    /// Focused test hook for verifying callbacks from completed sends are rejected.
    var bufferedEventCountForTesting: Int {
        eventBuffer.eventCount
    }

    private func drainCompatibilityEvents() {
        var anchorMessageID = messages.last(where: \.isAssistant)?.uuid
        var toolBreakOccurred = false
        drainEvents(
            for: compatibilitySendID,
            anchorMessageID: &anchorMessageID,
            toolBreakOccurred: &toolBreakOccurred,
            keepsToolCallsInHistory: ToolSettings.shared.keepsToolCallsInHistory,
            replayService: UserDefaults.model.apiService
        )
    }

    private func drainEvents(
        for sendID: UUID,
        anchorMessageID: inout UUID?,
        toolBreakOccurred: inout Bool,
        keepsToolCallsInHistory: Bool,
        replayService: APIService,
        toolCallTracker: RequestToolCallTracker? = nil
    ) {
        let events = eventBuffer.takeEvents(for: sendID)
        guard !events.isEmpty else { return }

        for event in events {
            let updatedMessage: Message
            switch event {
            case .tool(.toolCalled(let selection)):
                let anchor = eventAnchor(for: &anchorMessageID)
                anchor.applyToolEvent(.toolCalled(selection))
                if let uiCallID = anchor.toolCalls.last?.id {
                    toolCallTracker?.append(
                        selectionID: selection.id,
                        anchorMessageID: anchor.uuid,
                        uiCallID: uiCallID
                    )
                }
                updatedMessage = anchor

            case .tool(.toolCompleted(let result)):
                if let result,
                   let identity = toolCallTracker?.dequeue(selectionID: result.tool_selection_id),
                   let message = assistantMessage(withID: identity.anchorMessageID),
                   let index = message.toolCalls.firstIndex(where: {
                       $0.id == identity.uiCallID && $0.kind == .tool && $0.status == .pending
                   }) {
                    message.toolCalls[index].status = result.is_error ? .failure : .success
                    message.toolCalls[index].result = result.result
                    toolBreakOccurred = identity.anchorMessageID == anchorMessageID
                    updatedMessage = message
                } else {
                    let anchor = eventAnchor(for: &anchorMessageID)
                    if toolCallTracker == nil {
                        anchor.applyToolEvent(.toolCompleted(result))
                    } else if let result {
                        appendOrphanToolCompletion(result, to: anchor)
                    }
                    toolBreakOccurred = true
                    updatedMessage = anchor
                }

            case .agent(let agentEvent):
                let anchor = eventAnchor(for: &anchorMessageID)
                applyAgentEvent(
                    agentEvent,
                    to: anchor,
                    toolBreakOccurred: &toolBreakOccurred,
                    keepsToolCallsInHistory: keepsToolCallsInHistory,
                    replayService: replayService
                )
                updatedMessage = anchor
            }

            if !keepsToolCallsInHistory {
                updatedMessage.providerToolResults = [:]
                updatedMessage.providerToolResultServices = [:]
            }
            notifyMessageUpdated(updatedMessage, keepsToolCallsInHistory: keepsToolCallsInHistory)
        }
    }

    private func eventAnchor(for anchorMessageID: inout UUID?) -> Message {
        if let existing = assistantMessage(withID: anchorMessageID) {
            return existing
        }
        let anchor = Message(role: .assistant, contentType: .null)
        anchorMessageID = anchor.uuid
        messages.append(anchor)
        return anchor
    }

    private func appendOrphanToolCompletion(
        _ result: any LangToolsToolSelectionResult,
        to message: Message
    ) {
        message.toolCalls.append(
            ChatToolCall(
                id: UUID().uuidString,
                name: "tool",
                arguments: nil,
                status: result.is_error ? .failure : .success,
                result: result.result
            )
        )
    }

    private func requestMessages(keepsToolCallsInHistory: Bool) -> [Message] {
        guard !keepsToolCallsInHistory else { return messages }
        return messages.compactMap { message in
            let sanitized = sanitizedHistoryCopy(of: message)
            return isSemanticallyEmptyAssistantAnchor(sanitized) ? nil : sanitized
        }
    }

    private func clearToolHistoryIfNeeded(in assistantMessageIDs: Set<UUID>, keepsToolCallsInHistory: Bool) {
        guard !keepsToolCallsInHistory else { return }
        for messageID in assistantMessageIDs {
            clearToolHistoryIfNeeded(for: messageID, keepsToolCallsInHistory: false)
        }
    }

    private func clearToolHistoryIfNeeded(for anchorMessageID: UUID?, keepsToolCallsInHistory: Bool) {
        guard !keepsToolCallsInHistory,
              let anchor = assistantMessage(withID: anchorMessageID)
        else { return }
        let hadToolHistory = !anchor.toolCalls.isEmpty || !anchor.providerToolResults.isEmpty
        anchor.toolCalls = []
        anchor.providerToolResults = [:]
        anchor.providerToolResultServices = [:]
        if isSemanticallyEmptyAssistantAnchor(anchor) {
            messages.removeAll { $0.uuid == anchor.uuid }
        } else if hadToolHistory {
            notifyMessageUpdated(anchor, keepsToolCallsInHistory: false)
        }
    }

    private func notifyMessageUpdated(_ message: Message, keepsToolCallsInHistory: Bool) {
        guard let messageUpdatedCallback else { return }
        if keepsToolCallsInHistory {
            messageUpdatedCallback(message)
            return
        }

        let sanitized = sanitizedHistoryCopy(of: message)
        guard !isSemanticallyEmptyAssistantAnchor(sanitized) else { return }
        messageUpdatedCallback(sanitized)
    }

    private func sanitizedHistoryCopy(of message: Message) -> Message {
        Message(
            uuid: message.uuid,
            role: message.role,
            contentType: message.contentType,
            imageDetail: message.imageDetail,
            createdAt: message.createdAt
        )
    }

    private func isSemanticallyEmptyAssistantAnchor(_ message: Message) -> Bool {
        guard message.isAssistant,
              message.toolCalls.isEmpty,
              message.providerToolResults.isEmpty
        else { return false }

        switch message.contentType {
        case .null:
            return true
        case .string(let content):
            return content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .array(let content):
            return content.allSatisfy {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        case .agentEvent, .contentCards:
            return false
        }
    }

    private func assistantMessage(withID id: UUID?) -> Message? {
        guard let id else { return nil }
        return messages.first { $0.uuid == id && $0.isAssistant }
    }

    /// Marks every pending tool call owned by this send as failed so cards do
    /// not spin forever when the stream fails or ends without a completion
    /// result. Completed calls are left untouched.
    private func failPendingToolCalls(in assistantMessageIDs: Set<UUID>, reason: String) {
        for message in messages where assistantMessageIDs.contains(message.uuid) {
            message.failPendingToolCalls(reason: reason)
        }
    }
    @MainActor
    private func applyAgentEvent(
        _ event: AgentEvent,
        to last: Message,
        toolBreakOccurred: inout Bool,
        keepsToolCallsInHistory: Bool,
        replayService: APIService
    ) {
        switch event {
        case .started(let agent, let parent, let task):
            let arguments = Self.agentReplayArguments(reason: task)
            // If a delegation card already exists under `parent` (created by
            // agentTransfer/agentHandoff), update its details and replay arguments
            // instead of creating a duplicate — otherwise one card stays pending forever.
            if let parent {
                var calls = last.toolCalls
                if !Self.updateAgentChildDetails(
                    agent,
                    parent: parent,
                    append: "started: \(task)",
                    arguments: arguments,
                    in: &calls
                ) {
                    Self.appendChild(
                        ChatToolCall(
                            id: UUID().uuidString,
                            name: agent,
                            kind: .agent,
                            arguments: arguments,
                            status: .pending,
                            details: "started: \(task)"
                        ),
                        toAgent: parent,
                        in: &calls
                    )
                }
                last.toolCalls = calls
            } else {
                last.toolCalls.append(
                    ChatToolCall(
                        id: UUID().uuidString,
                        name: agent,
                        kind: .agent,
                        arguments: arguments,
                        status: .pending,
                        details: "started: \(task)"
                    )
                )
            }

        case .agentTransfer(let agent, let to, let reason), .agentHandoff(let agent, let to, let reason):
            let label = event.isHandoff ? "handed off" : "delegated"
            let call = ChatToolCall(
                id: UUID().uuidString,
                name: to,
                kind: .agent,
                arguments: Self.agentReplayArguments(reason: reason),
                status: .pending,
                details: "\(label): \(reason)"
            )
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
                if let callID = Self.setAgentStatus(agent, status: .success, result: nil, in: &calls),
                   keepsToolCallsInHistory {
                    last.providerToolResults[callID] = result
                    last.providerToolResultServices[callID] = replayService
                }
                last.toolCalls = calls
                toolBreakOccurred = true
                messages.append(cardMessage)
            } else {
                Self.setAgentStatus(agent, status: status, result: result, in: &calls)
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

        }
    }

    private static func agentReplayArguments(reason: String) -> String {
        do {
            let data = try JSONEncoder().encode(AgentReplayArguments(reason: reason))
            return String(decoding: data, as: UTF8.self)
        } catch {
            preconditionFailure("Failed to encode agent replay arguments: \(error)")
        }
    }

    /// Appends beneath the most recently created pending invocation named `agent`.
    @MainActor
    static func appendChild(_ child: ChatToolCall, toAgent agent: String, in calls: inout [ChatToolCall]) {
        _ = updateMostRecentPendingAgent(agent, in: &calls) { call in
            call.children.append(child)
        }
    }

    /// Updates the most recent pending delegated invocation under the most recent
    /// pending parent, keeping repeated same-named delegations as separate cards.
    @MainActor
    static func updateAgentChildDetails(
        _ agent: String,
        parent: String,
        append details: String,
        arguments: String? = nil,
        in calls: inout [ChatToolCall]
    ) -> Bool {
        var didUpdate = false
        _ = updateMostRecentPendingAgent(parent, in: &calls) { parentCall in
            guard let index = parentCall.children.lastIndex(where: {
                $0.kind == .agent && $0.name == agent && $0.status == .pending
            }) else { return }
            let existing = parentCall.children[index]
            let updatedDetails = [existing.details, details]
                .compactMap { $0 }
                .joined(separator: "\n")
            parentCall.children[index] = ChatToolCall(
                id: existing.id,
                name: existing.name,
                kind: existing.kind,
                arguments: arguments ?? existing.arguments,
                status: existing.status,
                result: existing.result,
                details: updatedDetails,
                children: existing.children
            )
            didUpdate = true
        }
        return didUpdate
    }

    /// Completes the oldest pending tool child of the most recent pending agent
    /// invocation. Agent children are never consumed by tool completion/error events.
    @MainActor
    static func completePendingChild(ofAgent agent: String, result: String, status: ChatToolCall.Status, in calls: inout [ChatToolCall]) {
        _ = updateMostRecentPendingAgent(agent, in: &calls) { call in
            guard let index = call.children.firstIndex(where: {
                $0.kind == .tool && $0.status == .pending
            }) else { return }
            call.children[index].status = status
            call.children[index].result = result
        }
    }

    /// Reconciles every pending descendant of the most recent matching invocation.
    /// Existing terminal states, especially failures, are preserved.
    @MainActor
    static func completeRemainingPending(ofAgent agent: String, status: ChatToolCall.Status, in calls: inout [ChatToolCall]) {
        _ = updateMostRecentAgent(agent, in: &calls) { call in
            reconcilePendingDescendants(in: &call.children, status: status)
        }
    }

    /// Terminates the most recent pending invocation and reconciles all of its
    /// descendants without modifying earlier terminal invocations.
    @MainActor
    @discardableResult
    static func setAgentStatus(_ agent: String, status: ChatToolCall.Status, result: String?, in calls: inout [ChatToolCall]) -> String? {
        var updatedCallID: String?
        _ = updateMostRecentPendingAgent(agent, in: &calls) { call in
            updatedCallID = call.id
            call.status = status
            if let result { call.result = result }
            reconcilePendingDescendants(in: &call.children, status: status)
        }
        return updatedCallID
    }

    @MainActor
    private static func updateMostRecentPendingAgent(
        _ agent: String,
        in calls: inout [ChatToolCall],
        update: (inout ChatToolCall) -> Void
    ) -> Bool {
        for index in calls.indices.reversed() {
            if updateMostRecentPendingAgent(agent, in: &calls[index].children, update: update) {
                return true
            }
            if calls[index].kind == .agent && calls[index].name == agent && calls[index].status == .pending {
                update(&calls[index])
                return true
            }
        }
        return false
    }

    @MainActor
    private static func updateMostRecentAgent(
        _ agent: String,
        in calls: inout [ChatToolCall],
        update: (inout ChatToolCall) -> Void
    ) -> Bool {
        for index in calls.indices.reversed() {
            if updateMostRecentAgent(agent, in: &calls[index].children, update: update) {
                return true
            }
            if calls[index].kind == .agent && calls[index].name == agent {
                update(&calls[index])
                return true
            }
        }
        return false
    }

    @MainActor
    private static func reconcilePendingDescendants(in calls: inout [ChatToolCall], status: ChatToolCall.Status) {
        for index in calls.indices {
            let descendantStatus: ChatToolCall.Status = calls[index].status == .failure ? .failure : status
            if calls[index].status == .pending {
                calls[index].status = descendantStatus
            }
            reconcilePendingDescendants(in: &calls[index].children, status: descendantStatus)
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
