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
    case responseChunk(String, eventsUpTo: UInt64)
    case eventsAvailable(upTo: UInt64)
}

private struct SequencedBufferedMessageEvent {
    let sequence: UInt64
    let event: BufferedMessageEvent
}

private struct PendingToolCallIdentity {
    let selectionID: String?
    let anchorMessageID: UUID
    let uiCallID: String
    let name: String?
    let arguments: String?
}

@MainActor
private final class RequestToolCallTracker {
    private var pendingCalls: [PendingToolCallIdentity] = []
    private var toolAnchorMessageIDs: [UUID] = []
    private var toolCallCount = 0
    let maxIterations: Int?

    init(maxIterations: Int? = nil) {
        self.maxIterations = maxIterations
    }

    var isAtLimit: Bool {
        guard let max = maxIterations else { return false }
        return toolCallCount >= max
    }

    func incrementCount() { toolCallCount += 1 }

    func append(
        selectionID: String?,
        anchorMessageID: UUID,
        uiCallID: String,
        name: String?,
        arguments: String?
    ) {
        pendingCalls.append(
            PendingToolCallIdentity(
                selectionID: selectionID.flatMap { $0.isEmpty ? nil : $0 },
                anchorMessageID: anchorMessageID,
                uiCallID: uiCallID,
                name: name,
                arguments: arguments
            )
        )
        recordToolAnchor(anchorMessageID)
    }

    func dequeue(selectionID: String) -> PendingToolCallIdentity? {
        let index: Int?
        if selectionID.isEmpty {
            index = pendingCalls.firstIndex(where: { $0.selectionID == nil })
                ?? pendingCalls.indices.first
        } else {
            index = pendingCalls.firstIndex(where: { $0.selectionID == selectionID })
        }
        guard let index else { return nil }
        return pendingCalls.remove(at: index)
    }

    func dequeueEarliest() -> PendingToolCallIdentity? {
        guard !pendingCalls.isEmpty else { return nil }
        return pendingCalls.removeFirst()
    }

    func recordToolAnchor(_ messageID: UUID) {
        guard toolAnchorMessageIDs.last != messageID else { return }
        toolAnchorMessageIDs.append(messageID)
    }

    func latestToolAnchor(in messages: [Message]) -> Message? {
        for messageID in toolAnchorMessageIDs.reversed() {
            if let message = messages.first(where: {
                $0.uuid == messageID && $0.isAssistant && !$0.toolCalls.isEmpty
            }) {
                return message
            }
        }
        return nil
    }

    var trackedAnchorMessageIDs: Set<UUID> {
        Set(toolAnchorMessageIDs)
    }
}

private struct AgentReplayArguments: Encodable {
    let reason: String
}

private final class SendEstablishment: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, any Error>?
    private var continuations: [CheckedContinuation<Void, any Error>] = []

    func wait() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                if let result {
                    continuation.resume(with: result)
                } else {
                    continuations.append(continuation)
                }
            }
        }
    }

    func succeed() {
        resolve(.success(()))
    }

    func fail(_ error: any Error) {
        resolve(.failure(error))
    }

    private func resolve(_ result: Result<Void, any Error>) {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, any Error>] in
            guard self.result == nil else { return [] }
            self.result = result
            let pending = continuations
            continuations.removeAll()
            return pending
        }
        pending.forEach { $0.resume(with: result) }
    }
}

/// Thread-safe request-scoped event storage. Provider and agent callbacks can
/// arrive off the main actor, so they only enqueue here; rendering remains on
/// `MessageService`'s main actor.
private final class SendEventBuffer: @unchecked Sendable {
    private struct State {
        var events: [SequencedBufferedMessageEvent] = []
        var latestSequence: UInt64 = 0
        var agentCallIDCounts: [String: Int] = [:]
        var eventContinuation: AsyncStream<UInt64>.Continuation?
    }

    private let lock = NSLock()
    private var states: [UUID: State] = [:]

    func register(_ sendID: UUID) -> AsyncStream<UInt64> {
        let (stream, continuation) = AsyncStream<UInt64>.makeStream(
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
        lock.withLock {
            guard var state = states[sendID] else { return }
            state.latestSequence += 1
            state.events.append(
                SequencedBufferedMessageEvent(sequence: state.latestSequence, event: .agent(event))
            )
            states[sendID] = state
            state.eventContinuation?.yield(state.latestSequence)
        }
    }

    func enqueueTool(_ event: LangToolsToolEvent, for sendID: UUID, agentToolNames: Set<String>) {
        lock.withLock {
            guard var state = states[sendID] else { return }
            switch event {
            case .toolCalled(let selection):
                let id = selection.id ?? selection.name ?? ""
                if agentToolNames.contains(selection.name ?? "") {
                    if !id.isEmpty {
                        state.agentCallIDCounts[id, default: 0] += 1
                    }
                    states[sendID] = state
                    return
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
                    return
                }
            }
            state.latestSequence += 1
            state.events.append(
                SequencedBufferedMessageEvent(sequence: state.latestSequence, event: .tool(event))
            )
            states[sendID] = state
            state.eventContinuation?.yield(state.latestSequence)
        }
    }

    /// Runs `body` while holding the same lock used to sequence events so the
    /// watermark and the queued response update form one ordering boundary.
    func withCurrentWatermark(for sendID: UUID, _ body: (UInt64) -> Void) {
        lock.withLock {
            guard let state = states[sendID] else { return }
            body(state.latestSequence)
        }
    }

    func takeEvents(for sendID: UUID, upTo watermark: UInt64? = nil) -> [BufferedMessageEvent] {
        lock.withLock {
            guard var state = states[sendID] else { return [] }
            let count = watermark.map { watermark in
                state.events.prefix { $0.sequence <= watermark }.count
            } ?? state.events.count
            let events = state.events.prefix(count).map(\.event)
            state.events.removeFirst(count)
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
    /// Generated messages owned by failed attempts, keyed by the stable user message id.
    /// This is intentionally ephemeral and excluded from persisted conversation history.
    private var failedAttemptGeneratedMessageIDs: [UUID: Set<UUID>] = [:]
    @ObservationIgnored private let eventBuffer = SendEventBuffer()
    /// Test-only gate after a response update is queued but before it is applied.
    @ObservationIgnored var responseChunkPreApplyHook: (() async -> Void)?
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

    /// Optional hook called when a tool or agent completes successfully.
    /// Receives the raw result string, the tool/agent name, and the call's kind;
    /// returns an optional `ChatToolCall.DisplayContent` to render rich content
    /// beneath the call card. When this returns `nil`, the legacy
    /// `agentResultParser` is still consulted for agents.
    public var resultContentParser: ((_ result: String, _ name: String, _ kind: ChatToolCall.Kind) -> ChatToolCall.DisplayContent?)?

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
        let operation = sendOperation(message: message, stream: stream)
        try await withTaskCancellationHandler {
            try await operation.waitForCompletion()
        } onCancel: {
            operation.cancel()
        }
    }

    public func sendOperation(message: String, stream: Bool = false) -> ChatSendOperation {
        let userMessage = Message(text: message, role: .user)
        messages.append(userMessage)
        return makeSendOperation(userMessage: userMessage, stream: stream)
    }

    public func retryOperation(messageID: UUID, stream: Bool = false) throws -> ChatSendOperation {
        guard let userMessage = messages.first(where: { $0.uuid == messageID && $0.isUser }),
              userMessage.sendFailure != nil
        else { throw ChatMessageServiceError.retryUnsupported }

        let generatedIDs = failedAttemptGeneratedMessageIDs.removeValue(forKey: messageID) ?? []
        messages.removeAll { $0.uuid == messageID || generatedIDs.contains($0.uuid) }
        messages.append(userMessage)
        setSendFailure(nil, on: userMessage)
        userMessage.wasResponseStopped = false
        return makeSendOperation(userMessage: userMessage, stream: stream)
    }

    public func markResponseStopped(messageID: UUID) {
        guard let message = messages.first(where: { $0.uuid == messageID && $0.isUser }) else { return }
        message.wasResponseStopped = true
        notifyMessageUpdated(message, keepsToolCallsInHistory: ToolSettings.shared.keepsToolCallsInHistory)
    }

    private func makeSendOperation(
        userMessage: Message,
        stream: Bool
    ) -> ChatSendOperation {
        let requestConversationID = conversationID
        let sendID = UUID()
        let establishment = SendEstablishment()
        let eventNotifications = eventBuffer.register(sendID)
        let requestSnapshot = requestMessages(
            keepsToolCallsInHistory: ToolSettings.shared.keepsToolCallsInHistory
        )

        let completion = Task { @MainActor in
            defer {
                eventBuffer.remove(sendID)
                removeActiveSend(id: sendID, conversationID: requestConversationID)
            }
            do {
                try await performSend(
                    userMessage: userMessage,
                    stream: stream,
                    conversationID: requestConversationID,
                    sendID: sendID,
                    requestSnapshot: requestSnapshot,
                    establishment: establishment,
                    eventNotifications: eventNotifications
                )
            } catch {
                establishment.fail(error)
                throw error
            }
        }
        activeSends[requestConversationID, default: [:]][sendID] = completion
        let establishmentTask = Task { try await establishment.wait() }

        return ChatSendOperation(
            id: sendID,
            messageID: userMessage.uuid,
            establishment: establishmentTask,
            completion: completion,
            cancel: {
                establishmentTask.cancel()
                completion.cancel()
            }
        )
    }

    private func performSend(
        userMessage: Message,
        stream: Bool,
        conversationID requestConversationID: UUID,
        sendID: UUID,
        requestSnapshot: [Message],
        establishment: SendEstablishment,
        eventNotifications: AsyncStream<UInt64>
    ) async throws {
        guard conversationID == requestConversationID else { throw CancellationError() }
        let userMessageID = userMessage.uuid
        var anchorMessageID: UUID?
        var assistantMessageIDs: Set<UUID> = []
        var generatedMessageIDs: Set<UUID> = []
        var toolBreakOccurred = false
        let toolCallTracker = RequestToolCallTracker(maxIterations: ToolSettings.shared.maxToolIterations)
        let keepsToolCallsInHistory = ToolSettings.shared.keepsToolCallsInHistory
        let selectedModel = UserDefaults.model
        let replayService = selectedModel.apiService

        do {
            var currentMessages = requestSnapshot
            currentMessages.insert(Message(text: systemMessage(), role: .system), at: 0)

            let activeTools = filteredTools(for: sendID)
            let agentToolNames = Set(agents.map(\.name))
            let toolEventHandler: (LangToolsToolEvent) -> Void = { [weak self] event in
                self?.enqueueToolEvent(event, for: sendID, agentToolNames: agentToolNames)
            }

            try Task.checkCancellation()
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
            try Task.checkCancellation()
            establishment.succeed()

            var content = ""
            let updates = Self.merge(
                responseStream: responseStream,
                eventNotifications: eventNotifications,
                eventBuffer: eventBuffer,
                sendID: sendID
            )
            for try await update in updates {
                guard conversationID == requestConversationID else { throw CancellationError() }
                let chunk: String
                switch update {
                case .eventsAvailable(let watermark):
                    drainEvents(
                        for: sendID,
                        upTo: watermark,
                        responseToMessageID: userMessageID,
                        anchorMessageID: &anchorMessageID,
                        toolBreakOccurred: &toolBreakOccurred,
                        generatedMessageIDs: &generatedMessageIDs,
                        keepsToolCallsInHistory: keepsToolCallsInHistory,
                        replayService: replayService,
                        toolCallTracker: toolCallTracker
                    )
                    if let anchorMessageID { assistantMessageIDs.insert(anchorMessageID) }
                    continue

                case .responseChunk(let responseChunk, let watermark):
                    await responseChunkPreApplyHook?()
                    drainEvents(
                        for: sendID,
                        upTo: watermark,
                        responseToMessageID: userMessageID,
                        anchorMessageID: &anchorMessageID,
                        toolBreakOccurred: &toolBreakOccurred,
                        generatedMessageIDs: &generatedMessageIDs,
                        keepsToolCallsInHistory: keepsToolCallsInHistory,
                        replayService: replayService,
                        toolCallTracker: toolCallTracker
                    )
                    if let anchorMessageID { assistantMessageIDs.insert(anchorMessageID) }
                    chunk = responseChunk
                }

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
                    let responseMessage = Message(role: .assistant, contentType: .string(trimmed), responseToMessageID: userMessageID)
                    anchorMessageID = responseMessage.uuid
                    assistantMessageIDs.insert(responseMessage.uuid)
                    generatedMessageIDs.insert(responseMessage.uuid)
                    messages.append(responseMessage)
                }
            }
            try Task.checkCancellation()
            guard conversationID == requestConversationID else { throw CancellationError() }
            drainEvents(
                for: sendID,
                responseToMessageID: userMessageID,
                anchorMessageID: &anchorMessageID,
                toolBreakOccurred: &toolBreakOccurred,
                generatedMessageIDs: &generatedMessageIDs,
                keepsToolCallsInHistory: keepsToolCallsInHistory,
                replayService: replayService,
                toolCallTracker: toolCallTracker
            )
            if let anchorMessageID { assistantMessageIDs.insert(anchorMessageID) }
            assistantMessageIDs.formUnion(toolCallTracker.trackedAnchorMessageIDs)
            clearToolHistoryIfNeeded(
                in: assistantMessageIDs,
                keepsToolCallsInHistory: keepsToolCallsInHistory
            )
            failPendingToolCalls(
                in: assistantMessageIDs,
                reason: "Tool call ended without a completion result.",
                keepsToolCallsInHistory: keepsToolCallsInHistory
            )
            failedAttemptGeneratedMessageIDs.removeValue(forKey: userMessageID)
            setSendFailure(nil, on: userMessage)
        } catch {
            guard conversationID == requestConversationID else { throw CancellationError() }
            // Preserve lifecycle events that fired before the failure, then run
            // the same terminal cleanup as a successful stream.
            drainEvents(
                for: sendID,
                responseToMessageID: userMessageID,
                anchorMessageID: &anchorMessageID,
                toolBreakOccurred: &toolBreakOccurred,
                generatedMessageIDs: &generatedMessageIDs,
                keepsToolCallsInHistory: keepsToolCallsInHistory,
                replayService: replayService,
                toolCallTracker: toolCallTracker
            )
            if let anchorMessageID { assistantMessageIDs.insert(anchorMessageID) }
            assistantMessageIDs.formUnion(toolCallTracker.trackedAnchorMessageIDs)
            clearToolHistoryIfNeeded(
                in: assistantMessageIDs,
                keepsToolCallsInHistory: keepsToolCallsInHistory
            )
            failPendingToolCalls(
                in: assistantMessageIDs,
                reason: error.localizedDescription,
                keepsToolCallsInHistory: keepsToolCallsInHistory
            )
            if error is CancellationError || Task.isCancelled {
                setSendFailure(nil, on: userMessage)
                throw CancellationError()
            }
            failedAttemptGeneratedMessageIDs[userMessageID] = generatedMessageIDs
            setSendFailure(ChatSendFailure(message: error.localizedDescription), on: userMessage)
            throw error
        }
    }

    nonisolated private static func merge(
        responseStream: AsyncThrowingStream<String, Error>,
        eventNotifications: AsyncStream<UInt64>,
        eventBuffer: SendEventBuffer,
        sendID: UUID
    ) -> AsyncThrowingStream<SendUpdate, Error> {
        AsyncThrowingStream { continuation in
            let responseTask = Task {
                do {
                    for try await chunk in responseStream {
                        try Task.checkCancellation()
                        eventBuffer.withCurrentWatermark(for: sendID) { watermark in
                            continuation.yield(.responseChunk(chunk, eventsUpTo: watermark))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            let eventTask = Task {
                for await watermark in eventNotifications {
                    guard !Task.isCancelled else { return }
                    continuation.yield(.eventsAvailable(upTo: watermark))
                }
            }
            continuation.onTermination = { @Sendable _ in
                responseTask.cancel()
                eventTask.cancel()
            }
        }
    }

    private func setSendFailure(_ failure: ChatSendFailure?, on message: Message) {
        guard messages.contains(where: { $0.uuid == message.uuid }) else { return }
        message.sendFailure = failure
    }

    private func removeActiveSend(id: UUID, conversationID: UUID) {
        activeSends[conversationID]?.removeValue(forKey: id)
        if activeSends[conversationID]?.isEmpty == true {
            activeSends.removeValue(forKey: conversationID)
        }
    }

    func systemMessage() -> String {
        let store = ChatConversationSettingsStore()
        let settings = store.load()
        var prompt = settings.systemPrompt

        // Append memory fields if set
        let fields = settings.memoryFields.filter { !$0.label.isEmpty && !$0.value.isEmpty }
        if !fields.isEmpty {
            prompt += "\n\n## User Context\n"
            for field in fields {
                prompt += "- \(field.label): \(field.value)\n"
            }
        }

        prompt += "\n\nWhen agent tools return results, those results are displayed visually to the user as content cards. Do not repeat or summarize information already shown in the cards. You may add a brief natural-language acknowledgment but should not list out details the user can already see. Answer follow-up questions about the content if asked. If an agent tool returns an error, explain the error to the user."
        return prompt
    }

    public func deleteMessage(id: UUID) {
        let generatedIDs = failedAttemptGeneratedMessageIDs.removeValue(forKey: id) ?? []
        messages.removeAll { $0.uuid == id || generatedIDs.contains($0.uuid) }
    }

    public func clearMessages() {
        let previousConversationID = conversationID
        let sends = activeSends.removeValue(forKey: previousConversationID) ?? [:]
        let sendsToDrain = Array(sends.values)
        sends.keys.forEach { eventBuffer.remove($0) }
        conversationID = UUID()
        failedAttemptGeneratedMessageIDs.removeAll()
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

    nonisolated func enqueueAgentEvent(_ event: AgentEvent, for sendID: UUID) {
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
        var generatedMessageIDs: Set<UUID> = []
        drainEvents(
            for: compatibilitySendID,
            responseToMessageID: nil,
            anchorMessageID: &anchorMessageID,
            toolBreakOccurred: &toolBreakOccurred,
            generatedMessageIDs: &generatedMessageIDs,
            keepsToolCallsInHistory: ToolSettings.shared.keepsToolCallsInHistory,
            replayService: UserDefaults.model.apiService
        )
    }

    private func drainEvents(
        for sendID: UUID,
        upTo watermark: UInt64? = nil,
        responseToMessageID: UUID?,
        anchorMessageID: inout UUID?,
        toolBreakOccurred: inout Bool,
        generatedMessageIDs: inout Set<UUID>,
        keepsToolCallsInHistory: Bool,
        replayService: APIService,
        toolCallTracker: RequestToolCallTracker? = nil
    ) {
        let events = eventBuffer.takeEvents(for: sendID, upTo: watermark)
        guard !events.isEmpty else { return }

        for event in events {
            let updatedMessage: Message?
            switch event {
            case .tool(.toolCalled(let selection)):
                let anchor = eventAnchor(
                    for: &anchorMessageID,
                    responseToMessageID: responseToMessageID,
                    generatedMessageIDs: &generatedMessageIDs
                )
                anchor.applyToolEvent(.toolCalled(selection))
                if let tracker = toolCallTracker {
                    if tracker.isAtLimit {
                        // Cap reached — immediately fail this tool call
                        if let idx = anchor.toolCalls.indices.last {
                            anchor.toolCalls[idx].status = .failure
                            anchor.toolCalls[idx].result = "Tool iteration limit reached."
                        }
                    } else {
                        tracker.incrementCount()
                        tracker.append(
                            selectionID: selection.id,
                            anchorMessageID: anchor.uuid,
                            uiCallID: anchor.toolCalls.last?.id ?? "",
                            name: selection.name,
                            arguments: selection.arguments.isEmpty ? nil : selection.arguments
                        )
                    }
                }
                updatedMessage = anchor

            case .tool(.toolCompleted(let result)):
                if let toolCallTracker {
                    let identity = result.map {
                        toolCallTracker.dequeue(selectionID: $0.tool_selection_id)
                    } ?? toolCallTracker.dequeueEarliest()
                    if let identity,
                       let message = assistantMessage(withID: identity.anchorMessageID),
                       let index = message.toolCalls.firstIndex(where: {
                           $0.id == identity.uiCallID && $0.kind == .tool && $0.status == .pending
                       }) {
                        if let result {
                            let isSuccess = !result.is_error
                            message.toolCalls[index].status = isSuccess ? .success : .failure
                            message.toolCalls[index].result = result.result
                            if isSuccess {
                                applyToolDisplayContent(result: result.result, name: identity.name ?? "", kind: .tool, toCallAt: index, in: message, keepsToolCallsInHistory: keepsToolCallsInHistory, generatedMessageIDs: &generatedMessageIDs)
                            }
                        } else {
                            message.toolCalls[index].status = .failure
                            message.toolCalls[index].result = "Tool call ended without a completion result."
                        }
                        toolBreakOccurred = identity.anchorMessageID == anchorMessageID
                        updatedMessage = message
                    } else if let result {
                        let anchor = orphanToolCompletionAnchor(
                            for: toolCallTracker,
                            currentAnchorMessageID: anchorMessageID,
                            responseToMessageID: responseToMessageID,
                            generatedMessageIDs: &generatedMessageIDs
                        )
                        appendOrphanToolCompletion(result, identity: identity, to: anchor)
                        if !result.is_error, let lastIdx = anchor.toolCalls.indices.last {
                            applyToolDisplayContent(result: result.result, name: identity?.name ?? "tool", kind: .tool, toCallAt: lastIdx, in: anchor, keepsToolCallsInHistory: keepsToolCallsInHistory, generatedMessageIDs: &generatedMessageIDs)
                        }
                        toolCallTracker.recordToolAnchor(anchor.uuid)
                        toolBreakOccurred = anchor.uuid == anchorMessageID
                        updatedMessage = anchor
                    } else {
                        updatedMessage = nil
                    }
                } else {
                    let anchor = eventAnchor(
                        for: &anchorMessageID,
                        responseToMessageID: responseToMessageID,
                        generatedMessageIDs: &generatedMessageIDs
                    )
                    let completedIdx = anchor.applyToolEventReturningCompletedIndex(.toolCompleted(result))
                    if let result, !result.is_error, let idx = completedIdx, anchor.toolCalls.indices.contains(idx) {
                        applyToolDisplayContent(result: result.result, name: anchor.toolCalls[idx].name, kind: .tool, toCallAt: idx, in: anchor, keepsToolCallsInHistory: keepsToolCallsInHistory, generatedMessageIDs: &generatedMessageIDs)
                    }
                    toolBreakOccurred = true
                    updatedMessage = anchor
                }

            case .agent(let agentEvent):
                let anchor = eventAnchor(
                    for: &anchorMessageID,
                    responseToMessageID: responseToMessageID,
                    generatedMessageIDs: &generatedMessageIDs
                )
                applyAgentEvent(
                    agentEvent,
                    to: anchor,
                    toolBreakOccurred: &toolBreakOccurred,
                    generatedMessageIDs: &generatedMessageIDs,
                    keepsToolCallsInHistory: keepsToolCallsInHistory,
                    replayService: replayService
                )
                updatedMessage = anchor
            }

            guard let updatedMessage else { continue }
            if !keepsToolCallsInHistory {
                updatedMessage.providerToolResults = [:]
                updatedMessage.providerToolResultServices = [:]
            }
            notifyMessageUpdated(updatedMessage, keepsToolCallsInHistory: keepsToolCallsInHistory)
        }
    }

    private func eventAnchor(
        for anchorMessageID: inout UUID?,
        responseToMessageID: UUID?,
        generatedMessageIDs: inout Set<UUID>
    ) -> Message {
        if let existing = assistantMessage(withID: anchorMessageID) {
            return existing
        }
        let anchor = Message(
            role: .assistant,
            contentType: .null,
            responseToMessageID: responseToMessageID
        )
        anchorMessageID = anchor.uuid
        generatedMessageIDs.insert(anchor.uuid)
        messages.append(anchor)
        return anchor
    }

    private func orphanToolCompletionAnchor(
        for tracker: RequestToolCallTracker,
        currentAnchorMessageID: UUID?,
        responseToMessageID: UUID?,
        generatedMessageIDs: inout Set<UUID>
    ) -> Message {
        if let anchor = tracker.latestToolAnchor(in: messages) {
            return anchor
        }

        let anchor = Message(
            role: .assistant,
            contentType: .null,
            responseToMessageID: responseToMessageID
        )
        generatedMessageIDs.insert(anchor.uuid)
        if let currentAnchorMessageID,
           let currentIndex = messages.firstIndex(where: { $0.uuid == currentAnchorMessageID }) {
            messages.insert(anchor, at: currentIndex)
        } else {
            messages.append(anchor)
        }
        return anchor
    }

    private func appendOrphanToolCompletion(
        _ result: any LangToolsToolSelectionResult,
        identity: PendingToolCallIdentity?,
        to message: Message
    ) {
        message.toolCalls.append(
            ChatToolCall(
                id: identity?.uiCallID ?? UUID().uuidString,
                name: identity?.name ?? "tool",
                arguments: identity?.arguments,
                status: result.is_error ? .failure : .success,
                result: result.result
            )
        )
    }

    private func requestMessages(keepsToolCallsInHistory: Bool) -> [Message] {
        let failedGeneratedIDs = failedAttemptGeneratedMessageIDs.values.reduce(into: Set<UUID>()) {
            $0.formUnion($1)
        }
        var eligibleMessages = messages.filter {
            $0.sendFailure == nil && !failedGeneratedIDs.contains($0.uuid)
        }

        // Apply context window truncation from conversation settings
        let convSettings = ChatConversationSettingsStore().load()
        if let limit = convSettings.maxContextMessages, limit > 0 {
            // Always keep the most recent user+assistant pair and system message
            let keepCount = min(limit, eligibleMessages.count)
            eligibleMessages = Array(eligibleMessages.suffix(keepCount))
        }

        guard !keepsToolCallsInHistory else { return eligibleMessages }
        return eligibleMessages.compactMap { message in
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
        let copy = Message(
            uuid: message.uuid,
            role: message.role,
            contentType: message.contentType,
            imageDetail: message.imageDetail,
            createdAt: message.createdAt,
            responseToMessageID: message.responseToMessageID
        )
        copy.wasResponseStopped = message.wasResponseStopped
        return copy
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

    /// Applies `resultContentParser` output to a completed tool call.
    private func applyToolDisplayContent(
        result: String, name: String, kind: ChatToolCall.Kind,
        toCallAt index: Int, in message: Message,
        keepsToolCallsInHistory: Bool, generatedMessageIDs: inout Set<UUID>
    ) {
        guard let displayContent = resultContentParser?(result, name, kind) else { return }
        guard message.toolCalls.indices.contains(index) else { return }
        if keepsToolCallsInHistory {
            message.toolCalls[index].displayContent = displayContent
            message.providerToolResults[message.toolCalls[index].id] = result
            message.providerToolResultServices[message.toolCalls[index].id] = UserDefaults.model.apiService
        } else {
            let cardMessage = Message.contentCards(ContentCardsContent(
                cardType: displayContent.type, message: displayContent.summary,
                cardsJSON: displayContent.json, cardCount: displayContent.itemCount))
            cardMessage.responseToMessageID = message.responseToMessageID
            generatedMessageIDs.insert(cardMessage.uuid)
            messages.append(cardMessage)
        }
    }

    /// Marks every pending tool call owned by this send as failed so cards do
    /// not spin forever when the stream fails or ends without a completion
    /// result. Completed calls are left untouched.
    private func failPendingToolCalls(
        in assistantMessageIDs: Set<UUID>,
        reason: String,
        keepsToolCallsInHistory: Bool
    ) {
        for message in messages where assistantMessageIDs.contains(message.uuid) {
            guard message.failPendingToolCalls(reason: reason) else { continue }
            notifyMessageUpdated(message, keepsToolCallsInHistory: keepsToolCallsInHistory)
        }
    }
    @MainActor
    private func applyAgentEvent(
        _ event: AgentEvent,
        to last: Message,
        toolBreakOccurred: inout Bool,
        generatedMessageIDs: inout Set<UUID>,
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
            var calls = last.toolCalls
            let resolvedResult = result ?? ""
            let completedIdentity = Self.completePendingChild(ofAgent: agent, result: resolvedResult, status: .success, in: &calls)
            if let identity = completedIdentity,
               let displayContent = resultContentParser?(resolvedResult, identity.name, .tool) {
                if keepsToolCallsInHistory {
                    Self.attachDisplayContentToCompletedChild(ofAgent: agent, childID: identity.id, displayContent: displayContent, in: &calls)
                } else {
                    let cardMessage = Message.contentCards(ContentCardsContent(cardType: displayContent.type, message: displayContent.summary, cardsJSON: displayContent.json, cardCount: displayContent.itemCount))
                    cardMessage.responseToMessageID = last.responseToMessageID
                    generatedMessageIDs.insert(cardMessage.uuid)
                    messages.append(cardMessage)
                }
            }
            last.toolCalls = calls

        case .completed(let agent, let result, let is_error):
            var calls = last.toolCalls
            let status: ChatToolCall.Status = is_error ? .failure : .success
            let displayContent = (!is_error) ? resultContentParser?(result, agent, .agent) : nil
            if let displayContent {
                if keepsToolCallsInHistory {
                    if let callID = Self.setAgentStatus(agent, status: .success, result: result, in: &calls, displayContent: displayContent) {
                        last.providerToolResults[callID] = result
                        last.providerToolResultServices[callID] = replayService
                    }
                } else {
                    _ = Self.setAgentStatus(agent, status: .success, result: result, in: &calls)
                    let cardMessage = Message.contentCards(ContentCardsContent(cardType: displayContent.type, message: displayContent.summary, cardsJSON: displayContent.json, cardCount: displayContent.itemCount))
                    cardMessage.responseToMessageID = last.responseToMessageID
                    generatedMessageIDs.insert(cardMessage.uuid)
                    messages.append(cardMessage)
                }
                last.toolCalls = calls
                toolBreakOccurred = true
            } else if !is_error, let cardMessage = agentResultParser?(result, agent) {
                if let callID = Self.setAgentStatus(agent, status: .success, result: nil, in: &calls),
                   keepsToolCallsInHistory {
                    last.providerToolResults[callID] = result
                    last.providerToolResultServices[callID] = replayService
                }
                last.toolCalls = calls
                toolBreakOccurred = true
                cardMessage.responseToMessageID = last.responseToMessageID
                generatedMessageIDs.insert(cardMessage.uuid)
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
    /// invocation. Returns the completed child's `(id, name)` for precise
    /// downstream matching, or `nil` when no pending tool child was found.
    @MainActor @discardableResult
    static func completePendingChild(ofAgent agent: String, result: String, status: ChatToolCall.Status, in calls: inout [ChatToolCall]) -> (id: String, name: String)? {
        var identity: (id: String, name: String)?
        _ = updateMostRecentPendingAgent(agent, in: &calls) { call in
            guard let index = call.children.firstIndex(where: { $0.kind == .tool && $0.status == .pending }) else { return }
            call.children[index].status = status
            call.children[index].result = result
            identity = (call.children[index].id, call.children[index].name)
        }
        return identity
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
    @MainActor @discardableResult
    static func setAgentStatus(_ agent: String, status: ChatToolCall.Status, result: String?, in calls: inout [ChatToolCall], displayContent: ChatToolCall.DisplayContent? = nil) -> String? {
        var updatedCallID: String?
        _ = updateMostRecentPendingAgent(agent, in: &calls) { call in
            updatedCallID = call.id
            call.status = status
            if let result { call.result = result }
            call.displayContent = displayContent
            reconcilePendingDescendants(in: &call.children, status: status)
        }
        return updatedCallID
    }

    /// Attaches `displayContent` to the completed tool child identified by `childID`.
    @MainActor
    static func attachDisplayContentToCompletedChild(ofAgent agent: String, childID: String, displayContent: ChatToolCall.DisplayContent, in calls: inout [ChatToolCall]) {
        _ = updateMostRecentPendingAgent(agent, in: &calls) { call in
            guard let index = call.children.firstIndex(where: { $0.id == childID && $0.kind == .tool }) else { return }
            call.children[index].displayContent = displayContent
        }
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
