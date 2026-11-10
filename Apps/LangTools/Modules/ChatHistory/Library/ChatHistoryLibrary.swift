//
//  ChatHistoryLibrary.swift
//  ChatHistory
//

import Combine
import Foundation
import Chat

/// The app-facing facade over one store: list operations, export and
/// retention. Create one per process, next to its `ChatSessionManager`.
@MainActor
public final class ChatHistoryLibrary: ObservableObject {
    public let storage: any ChatHistoryStorage
    public let sessions: ChatSessionManager
    public let exporter: ChatHistoryExporter
    private let retentionSettings: ChatRetentionSettingsStore
    private let now: () -> Date

    @Published public private(set) var retentionPolicy: ChatRetentionPolicy
    @Published public private(set) var lastRetentionReport: ChatRetentionReport?
    @Published public private(set) var lastError: String?

    public var changes: AnyPublisher<ChatHistoryChange, Never> { storage.changes }

    public init(
        sessions: ChatSessionManager,
        exporter: ChatHistoryExporter,
        retentionSettings: ChatRetentionSettingsStore = ChatRetentionSettingsStore(),
        now: @escaping () -> Date = Date.init
    ) {
        self.storage = sessions.storage
        self.sessions = sessions
        self.exporter = exporter
        self.retentionSettings = retentionSettings
        self.now = now
        self.retentionPolicy = retentionSettings.load()
    }

    // MARK: Conversations

    public func conversations(matching query: ConversationQuery) throws -> [ConversationRecord] {
        try storage.conversations(matching: query)
    }

    public func conversation(id: UUID) -> ConversationRecord? {
        try? storage.conversation(id: id)
    }

    @discardableResult
    public func createConversation(_ draft: ConversationDraft) throws -> ConversationRecord {
        try record { try storage.createConversation(draft) }
    }

    public func rename(_ id: UUID, to title: String) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try record { try storage.updateConversation(id: id, .rename(trimmed)) }
    }

    public func setPinned(_ id: UUID, _ isPinned: Bool) throws {
        try record { try storage.updateConversation(id: id, .pin(isPinned)) }
    }

    public func setArchived(_ id: UUID, _ isArchived: Bool) throws {
        try record { try storage.updateConversation(id: id, .archive(at: isArchived ? now() : nil)) }
    }

    /// Closes live sessions first so a streaming reply cannot recreate rows
    /// of a deleted conversation.
    public func deleteConversations(_ ids: Set<UUID>) throws {
        for id in ids { sessions.closeSession(id: id) }
        try record { try storage.deleteConversations(ids: ids) }
    }

    // MARK: Export

    public func export(_ id: UUID, format: ChatExportFormat) throws -> String {
        // Fail rather than deliver an apparently complete export that omits
        // unsaved streaming content. Read metadata after the flush as well.
        try sessions.liveSession(for: id)?.flush()
        guard let conversation = try storage.conversation(id: id) else {
            throw ChatHistoryError.conversationNotFound(id)
        }
        let messages = try storage.loadMessages(conversationID: id)
        return exporter.export(conversation, messages: messages, format: format)
    }

    /// Recreates an exported conversation. Fails if its ID already exists.
    @discardableResult
    public func importDocument(_ document: ConversationExportDocument) throws -> ConversationRecord {
        try record { try storage.importConversation(document.draft, messages: document.messageTrees()) }
    }

    // MARK: Retention

    /// Saves a new policy and applies it immediately.
    @discardableResult
    public func setRetentionPolicy(_ policy: ChatRetentionPolicy) throws -> ChatRetentionReport {
        retentionSettings.save(policy)
        retentionPolicy = policy
        return try applyRetention()
    }

    /// Conversations the given policy would delete right now.
    public func retentionPreview(for policy: ChatRetentionPolicy) throws -> [ConversationRecord] {
        try ChatRetentionPruner(storage: storage)
            .candidates(policy: policy, protecting: sessions.liveConversationIDs, now: now())
    }

    /// Runs the current policy, sparing conversations with a live session.
    @discardableResult
    public func applyRetention() throws -> ChatRetentionReport {
        let report = try record {
            try ChatRetentionPruner(storage: storage)
                .prune(policy: retentionPolicy, protecting: sessions.liveConversationIDs, now: now())
        }
        lastRetentionReport = report
        return report
    }

    /// Applies retention now and then every `interval` while the returned
    /// task is alive. Cancel it to stop.
    public func scheduleRetention(every interval: TimeInterval = 24 * 60 * 60) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            while !Task.isCancelled {
                _ = try? self?.applyRetention()
                do { try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000)) } catch { return }
            }
        }
    }

    // MARK: Errors

    private func record<T>(_ operation: () throws -> T) throws -> T {
        do {
            let value = try operation()
            lastError = nil
            return value
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }
}

/// A live, filtered list of conversations for one view.
@MainActor
public final class ConversationListModel: ObservableObject {
    public let library: ChatHistoryLibrary
    @Published public var query: ConversationQuery { didSet { reload() } }
    @Published public var searchText: String = "" { didSet { reload() } }
    @Published public private(set) var conversations: [ConversationRecord] = []
    @Published public private(set) var errorMessage: String?

    private var changeSubscription: AnyCancellable?
    private var reloadScheduled = false

    public init(library: ChatHistoryLibrary, query: ConversationQuery = .all) {
        self.library = library
        self.query = query
        changeSubscription = library.changes.sink { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleReload() }
        }
        reload()
    }

    public var pinned: [ConversationRecord] { conversations.filter(\.isPinned) }
    public var unpinned: [ConversationRecord] { conversations.filter { !$0.isPinned } }

    public func reload() {
        reloadScheduled = false
        var effective = query
        let text = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { effective.text = text }
        do {
            conversations = try library.conversations(matching: effective)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Store changes can arrive during a view update; coalesce them into one
    /// reload on the next main-actor turn.
    private func scheduleReload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        Task { @MainActor [weak self] in
            guard let self, self.reloadScheduled else { return }
            self.reload()
        }
    }
}
