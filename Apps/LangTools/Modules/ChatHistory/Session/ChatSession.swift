//
//  ChatSession.swift
//  ChatHistory
//
//  One live conversation: a `MessageService` plus the pipeline that makes its
//  transcript durable. Ported from Botsworth's `PersistentMessageService`,
//  narrowed from "every conversation in a window" to exactly one conversation
//  shared by every window and by headless runs.
//

import Combine
import Foundation
import Chat
import ChatUI

/// Ordered pending upserts for one conversation, keyed by message ID so a
/// streaming message is written once per flush.
struct PendingSaveBatch {
    private(set) var order: [UUID] = []
    private(set) var messages: [UUID: Message] = [:]

    var orderedMessages: [Message] { order.compactMap { messages[$0] } }
    var isEmpty: Bool { order.isEmpty }

    /// Returns true when the ID was not already queued.
    @discardableResult
    mutating func enqueue(_ message: Message) -> Bool {
        let isNew = messages[message.id] == nil
        if isNew { order.append(message.id) }
        messages[message.id] = message
        return isNew
    }

    mutating func remove(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        order.removeAll { ids.contains($0) }
        for id in ids { messages.removeValue(forKey: id) }
    }
}

/// A `ChatMessageService` for one stored conversation.
///
/// Get sessions from `ChatSessionManager`, which guarantees one live session
/// per conversation. Streaming updates are saved with a debounce; when a send
/// finishes, its terminal state is reconciled and saved immediately, and a
/// failed save is retried without repeating the network request.
@MainActor
public final class ChatSession: ObservableObject, ChatMessageService {
    public typealias ChatMessage = Message

    public let conversationID: UUID
    /// The underlying service. Hosts may read it; writes should go through
    /// the session so they are persisted.
    public let messageService: MessageService
    /// False for a draft that has not been saved yet. A draft is created in
    /// storage right before its first request.
    public private(set) var isMaterialized: Bool
    /// True after `close()`; a closed session no longer persists anything.
    public private(set) var isClosed = false

    private var draft: ConversationDraft?
    private let storage: any ChatHistoryStorage
    private let hooks: ChatSessionHooks
    private let timing: ChatPersistenceTiming
    var onMaterialized: ((ChatSession) -> Void)?
    var onActivityChanged: ((ChatSession) -> Void)?

    private var pending = PendingSaveBatch()
    private var pendingDeletionIDs = Set<UUID>()
    /// Top-level message IDs known to be stored or queued. Anything in this
    /// set that disappears from memory by the end of a send is deleted.
    private var knownMessageIDs = Set<UUID>()
    private var debounceTask: Task<Void, Never>?
    private var maximumLatencyTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var automaticFailureCount = 0
    /// Incremented by `close()` so cancelled sends do not reconcile an
    /// emptied transcript into durable deletions.
    private var generation: UInt = 0
    private var loadedContextRevision: UInt64 = 0
    public private(set) var activeSendCount = 0

    public var chatMessages: [Message] { messageService.messages }

    /// True when stored messages older than the loaded ones exist.
    @Published public private(set) var canLoadEarlierMessages = false
    private let paging: ChatSessionPaging
    /// Messages added by `loadEarlierMessages()`; sends never re-save them.
    private var pagedInMessageIDs = Set<UUID>()

    /// True while a send is in flight or saves are queued.
    public var hasActivity: Bool { activeSendCount > 0 || hasPendingPersistence }
    public var hasPendingPersistence: Bool { !pending.isEmpty || !pendingDeletionIDs.isEmpty }

    init(
        record: ConversationRecord?,
        draft: ConversationDraft?,
        storage: any ChatHistoryStorage,
        hooks: ChatSessionHooks,
        timing: ChatPersistenceTiming,
        paging: ChatSessionPaging = .standard
    ) throws {
        precondition(record != nil || draft != nil, "A session needs a stored record or a draft")
        let conversationID = record?.id ?? draft!.id
        self.conversationID = conversationID
        self.isMaterialized = record != nil
        self.draft = record == nil ? draft : nil
        self.storage = storage
        self.hooks = hooks
        self.timing = timing
        self.paging = paging

        let provisional = draft.map { ConversationRecordRules.record(from: $0, now: Date()) }
        let context = ChatSessionContext(conversationID: conversationID, checkpoints: storage) { [weak storage] in
            (try? storage?.conversation(id: conversationID)) ?? provisional
        }
        let service = hooks.makeMessageService(context)
        service.agentResultParser = hooks.agentResultParser
        service.requestPreparer = hooks.makeRequestPreparer?(context)
        self.messageService = service
        loadedContextRevision = storage.contextRevision(conversationID: conversationID)

        if let record {
            // Load before installing the callback so opening a conversation
            // does not write (and reorder) it.
            // A checkpoint only replaces history when a preparer actually
            // injects its summary. Without one, load the complete transcript.
            let window: MessageWindow = service.requestPreparer == nil ? .all
                : Self.initialWindow(conversationID: conversationID, storage: storage, paging: paging)
            let loaded = try storage.loadMessages(conversationID: conversationID, window: window)
            service.messages = loaded
            knownMessageIDs = Set(loaded.map(\.uuid))
            canLoadEarlierMessages = window != .all && loaded.count < record.messageCount
        }

        service.messageUpdatedCallback = { [weak self] message in
            MainActor.assumeIsolated {
                self?.queueStreamingUpdate(message)
            }
        }
    }

    // MARK: - ChatMessageService

    public func send(message: String, stream: Bool = true) async throws {
        let operation = sendOperation(message: message, stream: stream)
        try await withTaskCancellationHandler {
            try await operation.waitForCompletion()
        } onCancel: {
            operation.cancel()
        }
    }

    public func sendOperation(message: String, stream: Bool) -> ChatSendOperation {
        do {
            try materializeIfNeeded()
            try refreshAfterDeletion()
        } catch {
            return Self.failedOperation(hooks.mapSendError(error))
        }
        let inner = messageService.sendOperation(message: message, stream: stream)
        return track(inner)
    }

    public func retryOperation(messageID: UUID, stream: Bool) throws -> ChatSendOperation {
        try materializeIfNeeded()
        try refreshAfterDeletion()
        let inner = try messageService.retryOperation(messageID: messageID, stream: stream)
        return track(inner)
    }

    public func markResponseStopped(messageID: UUID) {
        // MessageService reports the stopped prompt through the update callback.
        messageService.markResponseStopped(messageID: messageID)
    }

    /// Removes a message (and any generated output of its failed attempt)
    /// from memory and from storage.
    public func deleteMessage(id: UUID) {
        let before = Set(messageService.messages.map(\.uuid))
        messageService.deleteMessage(id: id)
        let removed = before.subtracting(messageService.messages.map(\.uuid))
        queueDeletions(removed)
    }

    public func handleError(error: Error) -> ChatAlertInfo? {
        hooks.alert(error)
    }

    // MARK: - Paging

    /// Everything from the latest checkpoint's covered message on, with at
    /// least `initialMessageCount` messages; everything without a checkpoint.
    static func initialWindow(
        conversationID: UUID,
        storage: any ChatHistoryStorage,
        paging: ChatSessionPaging
    ) -> MessageWindow {
        guard let minimumCount = paging.initialMessageCount,
              let checkpoint = (try? storage.latestCheckpoint(conversationID: conversationID)) ?? nil else {
            return .all
        }
        return .since(checkpoint.coversThroughMessageID, minimumCount: minimumCount)
    }

    /// Loads the page of stored messages before the oldest loaded one and
    /// returns how many top-level messages were added. Loading never writes.
    @discardableResult
    public func loadEarlierMessages() throws -> Int {
        guard canLoadEarlierMessages, !isClosed, let oldest = messageService.messages.first else {
            canLoadEarlierMessages = false
            return 0
        }
        let limit = paging.earlierPageSize
        let earlier = try storage.loadMessages(conversationID: conversationID, window: .before(oldest.uuid, limit: limit))
        let loadedIDs = Set(messageService.messages.map(\.uuid))
        let added = earlier.filter { !loadedIDs.contains($0.uuid) }
        if !added.isEmpty {
            let callback = messageService.messageUpdatedCallback
            messageService.messageUpdatedCallback = nil
            messageService.messages.insert(contentsOf: added, at: 0)
            messageService.messageUpdatedCallback = callback
            knownMessageIDs.formUnion(added.map(\.uuid))
            pagedInMessageIDs.formUnion(added.map(\.uuid))
        }
        canLoadEarlierMessages = earlier.count >= limit
        return added.count
    }

    // MARK: - Lifecycle

    /// Saves queued changes now. On failure the batch stays queued and an
    /// automatic retry is scheduled.
    public func flush() throws {
        cancelScheduledFlushes()
        automaticFailureCount = 0
        do {
            try flushPendingSaves()
        } catch {
            automaticFailureCount = 1
            scheduleAutomaticRetry(failureCount: 1)
            throw error
        }
    }

    /// Cancels in-flight sends and drops queued saves. Used when the
    /// conversation is deleted.
    public func close() {
        guard !isClosed else { return }
        isClosed = true
        generation &+= 1
        cancelScheduledFlushes()
        pending = PendingSaveBatch()
        pendingDeletionIDs.removeAll()
        messageService.messageUpdatedCallback = nil
        messageService.clearMessages()
    }

    // MARK: - Send tracking

    private func track(_ inner: ChatSendOperation) -> ChatSendOperation {
        let knownBefore = knownMessageIDs
        let generationBefore = generation
        let promptID = inner.messageID
        activeSendCount += 1
        onActivityChanged?(self)

        let completion = Task { @MainActor [weak self] in
            var sendError: Error?
            do {
                try await inner.waitForCompletion()
            } catch {
                sendError = error
            }
            guard let self else {
                if let sendError { throw sendError }
                return
            }
            defer {
                self.activeSendCount -= 1
                self.onActivityChanged?(self)
            }
            try self.finishSend(
                error: sendError,
                knownBefore: knownBefore,
                generationBefore: generationBefore,
                promptID: promptID
            )
        }
        let hooks = self.hooks
        let establishment = Task { @MainActor in
            do {
                try await inner.waitUntilEstablished()
            } catch {
                throw hooks.mapSendError(error)
            }
        }
        // Cancelling stops the request; `completion` still runs so the
        // terminal state (including a partial response) is saved.
        return ChatSendOperation(
            id: inner.id,
            messageID: inner.messageID,
            establishment: establishment,
            completion: completion,
            cancel: { inner.cancel() }
        )
    }

    /// Persists a finished send's authoritative state. A network error stays
    /// the primary error; a save failure is reported only when the request
    /// itself succeeded, and the batch is retried without a new request.
    private func finishSend(
        error: Error?,
        knownBefore: Set<UUID>,
        generationBefore: UInt,
        promptID: UUID?
    ) throws {
        let mappedError = error.map(hooks.mapSendError)
        if let error, hooks.removesFailedPromptWithoutOutput {
            removeFailedPromptIfItHasNoOutput(promptID: promptID, knownBefore: knownBefore, error: error)
        }

        guard !isClosed, generation == generationBefore else {
            // The session was closed mid-send; an intentional cancellation
            // completes quietly, anything else is still reported.
            if let mappedError, !(mappedError is CancellationError) { throw mappedError }
            return
        }

        reconcileTerminalState(knownBefore: knownBefore, promptID: promptID)
        do {
            try persistTerminalState()
        } catch {
            if mappedError == nil { throw error }
        }
        if let mappedError { throw mappedError }
    }

    /// A prompt that failed before producing anything is removed so ChatUI
    /// restores it to the composer. Partial output is kept.
    private func removeFailedPromptIfItHasNoOutput(promptID: UUID?, knownBefore: Set<UUID>, error: Error) {
        guard !(error is CancellationError), let promptID,
              messageService.messages.contains(where: { $0.uuid == promptID && $0.isUser }) else { return }
        let generated = messageService.messages.filter { !knownBefore.contains($0.uuid) && $0.uuid != promptID }
        guard generated.isEmpty else { return }
        messageService.deleteMessage(id: promptID)
    }

    /// Queues deletions for known messages that are no longer in memory
    /// (retries and history cleanup remove messages without a callback) and
    /// re-queues this send's messages, because MessageService finalizes tool
    /// failures after its last streaming callback.
    private func reconcileTerminalState(knownBefore: Set<UUID>, promptID: UUID?) {
        let final = messageService.messages
        let finalIDs = Set(final.map(\.uuid))
        let removed = knownMessageIDs.subtracting(finalIDs)
        if !removed.isEmpty {
            pending.remove(ids: removed)
            pendingDeletionIDs.formUnion(removed)
        }
        for message in final where (!knownBefore.contains(message.uuid) && !pagedInMessageIDs.contains(message.uuid))
            || message.uuid == promptID {
            enqueue(message)
        }
    }

    private func persistTerminalState() throws {
        cancelScheduledFlushes()
        var lastError: Error?
        for _ in 0..<2 {
            do {
                try flushPendingSaves()
                return
            } catch {
                lastError = error
            }
        }
        // The batch is final, so retry on the backoff schedule rather than
        // waiting for a streaming debounce that will never come.
        scheduleAutomaticRetry(failureCount: 1)
        throw ChatSessionError.persistenceFailed(lastError?.localizedDescription ?? "Unknown persistence error")
    }

    // MARK: - Queueing

    private func queueStreamingUpdate(_ message: Message) {
        guard !isClosed else { return }
        enqueue(message)
        scheduleFlushes()
    }

    private func queueDeletions(_ ids: Set<UUID>) {
        guard !isClosed, !ids.isEmpty else { return }
        pending.remove(ids: ids)
        let isNew = !ids.isSubset(of: pendingDeletionIDs)
        pendingDeletionIDs.formUnion(ids)
        if isNew { rearmAutomaticPersistenceIfExhausted() }
        scheduleFlushes()
    }

    private func enqueue(_ message: Message) {
        let isNew = pending.enqueue(message)
        pendingDeletionIDs.remove(message.uuid)
        knownMessageIDs.insert(message.uuid)
        if isNew { rearmAutomaticPersistenceIfExhausted() }
    }

    /// New content gets a fresh set of automatic attempts after earlier ones
    /// were exhausted.
    private func rearmAutomaticPersistenceIfExhausted() {
        if automaticFailureCount >= timing.maximumAutomaticAttempts {
            automaticFailureCount = 0
        }
    }

    // MARK: - Flushing

    private func scheduleFlushes() {
        guard automaticFailureCount < timing.maximumAutomaticAttempts else { return }
        debounceTask?.cancel()
        debounceTask = scheduleAutomaticFlush(after: timing.debounce)
        if maximumLatencyTask == nil {
            maximumLatencyTask = scheduleAutomaticFlush(after: timing.maximumLatency)
        }
    }

    private func scheduleAutomaticFlush(after delay: TimeInterval) -> Task<Void, Never> {
        let sleep = timing.sleep
        return Task { @MainActor [weak self] in
            do { try await sleep(delay) } catch { return }
            guard !Task.isCancelled else { return }
            self?.performAutomaticFlush()
        }
    }

    private func performAutomaticFlush() {
        cancelScheduledFlushes()
        do {
            try flushPendingSaves()
            automaticFailureCount = 0
        } catch {
            automaticFailureCount += 1
            guard automaticFailureCount < timing.maximumAutomaticAttempts else { return }
            scheduleAutomaticRetry(failureCount: automaticFailureCount)
        }
    }

    private func scheduleAutomaticRetry(failureCount: Int) {
        let delay = timing.initialRetryDelay * pow(2, Double(failureCount - 1))
        retryTask = scheduleAutomaticFlush(after: delay)
    }

    private func cancelScheduledFlushes() {
        debounceTask?.cancel()
        debounceTask = nil
        maximumLatencyTask?.cancel()
        maximumLatencyTask = nil
        retryTask?.cancel()
        retryTask = nil
    }

    /// Writes all queued state in one transaction; the queue is cleared only
    /// after the store confirms the save. If the conversation was deleted,
    /// the queue is discarded.
    private func flushPendingSaves() throws {
        guard !isClosed, hasPendingPersistence, isMaterialized else { return }
        let deletions = pendingDeletionIDs
        do {
            try storage.applyMessageChanges(
                MessageChangeSet(upserts: pending.orderedMessages, deletions: deletions),
                conversationID: conversationID
            )
        } catch let error as ChatHistoryError where error == .conversationNotFound(conversationID) {
            discardPendingPersistence()
            return
        }
        pending = PendingSaveBatch()
        pendingDeletionIDs.removeAll()
        knownMessageIDs.subtract(deletions)
        automaticFailureCount = 0
        onActivityChanged?(self)
    }

    private func discardPendingPersistence() {
        cancelScheduledFlushes()
        pending = PendingSaveBatch()
        pendingDeletionIDs.removeAll()
        automaticFailureCount = 0
    }

    /// Commit pending deletions before another request and restore messages
    /// hidden by an invalidated checkpoint. A failed save/load blocks the send.
    private func refreshAfterDeletion() throws {
        if !pendingDeletionIDs.isEmpty { try flush() }
        let revision = storage.contextRevision(conversationID: conversationID)
        guard revision != loadedContextRevision else { return }
        try flush()
        let loaded = try storage.loadMessages(conversationID: conversationID)
        let callback = messageService.messageUpdatedCallback
        messageService.messageUpdatedCallback = nil
        messageService.messages = loaded
        messageService.messageUpdatedCallback = callback
        knownMessageIDs = Set(loaded.map(\.uuid))
        canLoadEarlierMessages = false
        loadedContextRevision = revision
    }

    // MARK: - Drafts

    private func materializeIfNeeded() throws {
        guard !isClosed else {
            throw ChatSessionError.persistenceFailed("The conversation is no longer available.")
        }
        guard !isMaterialized else { return }
        guard let draft else {
            throw ChatSessionError.persistenceFailed("The conversation is no longer available.")
        }
        do {
            if try storage.conversation(id: draft.id) == nil {
                try storage.createConversation(draft)
            }
        } catch {
            throw ChatSessionError.persistenceFailed(error.localizedDescription)
        }
        isMaterialized = true
        self.draft = nil
        onMaterialized?(self)
    }

    private static func failedOperation(_ error: Error) -> ChatSendOperation {
        let establishment = Task<Void, any Error> { throw error }
        let completion = Task<Void, any Error> { throw error }
        return ChatSendOperation(establishment: establishment, completion: completion, cancel: {})
    }

    // MARK: - Testing

    #if DEBUG
    var pendingUpsertCountForTesting: Int { pending.order.count }
    var pendingDeletionCountForTesting: Int { pendingDeletionIDs.count }
    var automaticFailureCountForTesting: Int { automaticFailureCount }
    var hasScheduledFlushForTesting: Bool {
        debounceTask != nil || maximumLatencyTask != nil || retryTask != nil
    }
    func performAutomaticFlushForTesting() { performAutomaticFlush() }
    #endif
}
