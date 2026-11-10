//
//  SwiftDataChatHistoryStorage.swift
//  ChatHistory
//

import Combine
import Foundation
import SwiftData
import Chat
import ChatContext

/// The default `ChatHistoryStorage`: one SwiftData container at an explicit
/// file URL (never the process-wide `default.store`), using the main context
/// with autosave off so every mutation is one explicit save.
///
/// Create one instance per store file per process and share it. Opening the
/// same file from several containers in one process is unsupported.
@MainActor
public final class SwiftDataChatHistoryStorage: ChatHistoryStorage {
    public let location: ChatHistoryStoreLocation
    private let container: ModelContainer
    private let context: ModelContext
    private let titleGenerator: any ConversationTitleGenerating
    private let now: () -> Date
    private let subject = PassthroughSubject<ChatHistoryChange, Never>()
    private var contextRevisions: [UUID: UInt64] = [:]

    public func contextRevision(conversationID: UUID) -> UInt64 {
        contextRevisions[conversationID, default: 0]
    }


    /// Test seam: runs before every save; throwing simulates a failed save.
    var saveHook: (() throws -> Void)?

    public var changes: AnyPublisher<ChatHistoryChange, Never> { subject.eraseToAnyPublisher() }

    public init(
        location: ChatHistoryStoreLocation,
        titleGenerator: any ConversationTitleGenerating = PrefixConversationTitleGenerator(),
        now: @escaping () -> Date = Date.init
    ) throws {
        self.location = location
        self.titleGenerator = titleGenerator
        self.now = now

        let schema = Schema(versionedSchema: ChatHistorySchemaV2.self)
        let configuration: ModelConfiguration
        switch location {
        case .inMemory:
            // A unique name isolates each in-memory store.
            configuration = ModelConfiguration(
                "ChatHistory-\(UUID().uuidString)",
                schema: schema,
                isStoredInMemoryOnly: true,
                allowsSave: true,
                groupContainer: .none,
                cloudKitDatabase: .none
            )
        case .file(let url):
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // CloudKit stays off explicitly: `.automatic` would start syncing
            // in any host app that has an iCloud container entitlement.
            configuration = ModelConfiguration(
                "ChatHistory",
                schema: schema,
                url: url,
                allowsSave: true,
                cloudKitDatabase: .none
            )
        }
        container = try ModelContainer(
            for: schema,
            migrationPlan: ChatHistoryMigrationPlan.self,
            configurations: [configuration]
        )
        context = container.mainContext
        context.autosaveEnabled = false
    }

    // MARK: Conversations

    public func conversations(matching query: ConversationQuery) throws -> [ConversationRecord] {
        let records = try context.fetch(FetchDescriptor<ChatHistoryConversation>()).map(\.record)
        var textMatches = Set<UUID>()
        if let text = query.normalizedText {
            var descriptor = FetchDescriptor<ChatHistoryMessage>(
                predicate: #Predicate { $0.plainText.localizedStandardContains(text) }
            )
            descriptor.propertiesToFetch = [\.conversationID]
            textMatches = Set(try context.fetch(descriptor).map(\.conversationID))
        }
        return ConversationRecordRules.filter(records, query: query, messageTextMatches: textMatches)
    }

    public func conversation(id: UUID) throws -> ConversationRecord? {
        try fetchConversation(id)?.record
    }

    @discardableResult
    public func createConversation(_ draft: ConversationDraft) throws -> ConversationRecord {
        guard try fetchConversation(draft.id) == nil else {
            throw ChatHistoryError.conversationAlreadyExists(draft.id)
        }
        let record = ConversationRecordRules.record(from: draft, now: now())
        let model = ChatHistoryConversation(id: record.id)
        model.apply(record)
        context.insert(model)
        try save()
        subject.send(.conversationUpserted(record.id))
        return record
    }

    @discardableResult
    public func updateConversation(id: UUID, _ patch: ConversationPatch) throws -> ConversationRecord {
        guard let model = try fetchConversation(id) else {
            throw ChatHistoryError.conversationNotFound(id)
        }
        var record = model.record
        ConversationRecordRules.apply(patch, to: &record, now: now())
        model.apply(record)
        try save()
        subject.send(.conversationUpserted(id))
        return record
    }

    public func deleteConversations(ids: Set<UUID>) throws {
        var deleted = Set<UUID>()
        for id in ids {
            guard let model = try fetchConversation(id) else { continue }
            for row in try fetchRows(conversationID: id) { context.delete(row) }
            for checkpoint in try fetchCheckpoints(conversationID: id) { context.delete(checkpoint) }
            context.delete(model)
            deleted.insert(id)
        }
        guard !deleted.isEmpty else { return }
        try save()
        subject.send(.conversationsDeleted(deleted))
    }

    // MARK: Messages

    public func loadMessages(conversationID: UUID, window: MessageWindow) throws -> [Message] {
        guard try fetchConversation(conversationID) != nil else {
            throw ChatHistoryError.conversationNotFound(conversationID)
        }
        if case .all = window {
            return MessageRowCodec.messages(from: try fetchRows(conversationID: conversationID).map(\.row))
        }
        // Order and shape the tree from key columns, then read payloads only
        // for the rows the window selects.
        let keys = try fetchRowKeys(conversationID: conversationID)
        guard let selected = MessageWindowPlanner.selectedIDs(for: window, keys: keys) else {
            return MessageRowCodec.messages(from: try fetchRows(conversationID: conversationID).map(\.row))
        }
        guard !selected.isEmpty else { return [] }
        let ids = Array(selected)
        let rows = try context.fetch(FetchDescriptor<ChatHistoryMessage>(
            predicate: #Predicate { $0.conversationID == conversationID && ids.contains($0.id) }
        ))
        return MessageRowCodec.messages(from: rows.map(\.row))
    }

    public func applyMessageChanges(_ changes: MessageChangeSet, conversationID: UUID) throws {
        guard let model = try fetchConversation(conversationID) else {
            throw ChatHistoryError.conversationNotFound(conversationID)
        }
        guard !changes.isEmpty else { return }

        var storedByID: [UUID: ChatHistoryMessage] = [:]
        for stored in try fetchRows(conversationID: conversationID) where storedByID[stored.id] == nil {
            storedByID[stored.id] = stored
        }
        let plan = try MessageChangePlanner.plan(
            changes,
            existing: storedByID.mapValues(\.row),
            nextSortOrder: model.nextSortOrder
        )
        guard !plan.isNoOp else { return }

        if !plan.deletedIDs.isEmpty {
            let stored = try fetchCheckpoints(conversationID: conversationID)
            let (updated, removed) = CheckpointRules.adjustments(
                for: stored.map(\.checkpoint),
                deletedIDs: plan.deletedIDs,
                previousKeys: storedByID.values.map(\.key),
                remainingKeys: plan.remainingKeys
            )
            let updatedByID = Dictionary(updated.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            for checkpoint in stored {
                if removed.contains(checkpoint.id) {
                    context.delete(checkpoint)
                } else if let moved = updatedByID[checkpoint.id] {
                    checkpoint.apply(moved)
                }
            }
        }
        for id in plan.deletedIDs {
            if let stored = storedByID[id] { context.delete(stored) }
        }
        for row in plan.writes {
            if let stored = storedByID[row.id] {
                stored.apply(row)
            } else {
                let stored = ChatHistoryMessage(id: row.id, conversationID: conversationID)
                stored.apply(row)
                context.insert(stored)
            }
        }
        var record = model.record
        ConversationRecordRules.apply(plan.summary, titleGenerator: titleGenerator, to: &record, updatedAt: now())
        model.apply(record)
        model.nextSortOrder = plan.nextSortOrder

        try save()
        if !plan.deletedIDs.isEmpty { contextRevisions[conversationID, default: 0] &+= 1 }
        subject.send(.messagesChanged(conversationID))
        subject.send(.conversationUpserted(conversationID))
    }

    @discardableResult
    public func importConversation(_ draft: ConversationDraft, messages: [Message]) throws -> ConversationRecord {
        guard try fetchConversation(draft.id) == nil else {
            throw ChatHistoryError.conversationAlreadyExists(draft.id)
        }
        var record = ConversationRecordRules.record(from: draft, now: now())
        let (rows, nextSortOrder) = try ConversationRecordRules.importRows(
            for: messages,
            draft: draft,
            record: &record,
            titleGenerator: titleGenerator
        )
        let model = ChatHistoryConversation(id: record.id)
        model.apply(record)
        model.nextSortOrder = nextSortOrder
        context.insert(model)
        for row in rows {
            let stored = ChatHistoryMessage(id: row.id, conversationID: record.id)
            stored.apply(row)
            context.insert(stored)
        }
        try save()
        subject.send(.conversationUpserted(record.id))
        subject.send(.messagesChanged(record.id))
        return record
    }

    // MARK: Checkpoints

    public func checkpoints(conversationID: UUID) throws -> [ContextCheckpoint] {
        guard try fetchConversation(conversationID) != nil else {
            throw ChatHistoryError.conversationNotFound(conversationID)
        }
        return try fetchCheckpoints(conversationID: conversationID).map(\.checkpoint)
            .sorted { ContextCheckpoint.isNewer($1, than: $0) }
    }

    public func latestCheckpoint(conversationID: UUID) throws -> ContextCheckpoint? {
        guard try fetchConversation(conversationID) != nil else {
            throw ChatHistoryError.conversationNotFound(conversationID)
        }
        return try fetchCheckpoints(conversationID: conversationID).map(\.checkpoint).min(by: ContextCheckpoint.isNewer)
    }

    public func saveCheckpoint(_ checkpoint: ContextCheckpoint) throws {
        let conversationID = checkpoint.conversationID
        guard try fetchConversation(conversationID) != nil else {
            throw ChatHistoryError.conversationNotFound(conversationID)
        }
        try CheckpointRules.validate(checkpoint, keys: try fetchRowKeys(conversationID: conversationID))
        let model = try fetchCheckpoints(conversationID: conversationID).first { $0.id == checkpoint.id } ?? {
            let created = ChatHistoryCheckpoint(id: checkpoint.id, conversationID: conversationID)
            context.insert(created)
            return created
        }()
        model.apply(checkpoint)
        try save()
    }

    // MARK: Helpers

    private func fetchConversation(_ id: UUID) throws -> ChatHistoryConversation? {
        var descriptor = FetchDescriptor<ChatHistoryConversation>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func fetchRows(conversationID: UUID) throws -> [ChatHistoryMessage] {
        try context.fetch(
            FetchDescriptor<ChatHistoryMessage>(predicate: #Predicate { $0.conversationID == conversationID })
        )
    }

    /// Every row's ordering and tree columns, without decoding payloads.
    private func fetchRowKeys(conversationID: UUID) throws -> [MessageRowKey] {
        var descriptor = FetchDescriptor<ChatHistoryMessage>(predicate: #Predicate { $0.conversationID == conversationID })
        descriptor.propertiesToFetch = [\.id, \.parentID, \.sortOrder, \.createdAt, \.contentKind]
        return try context.fetch(descriptor).map(\.key)
    }

    private func fetchCheckpoints(conversationID: UUID) throws -> [ChatHistoryCheckpoint] {
        try context.fetch(
            FetchDescriptor<ChatHistoryCheckpoint>(predicate: #Predicate { $0.conversationID == conversationID })
        )
    }

    private func save() throws {
        do {
            try saveHook?()
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }
}
