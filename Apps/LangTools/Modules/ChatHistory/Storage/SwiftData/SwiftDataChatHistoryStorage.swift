//
//  SwiftDataChatHistoryStorage.swift
//  ChatHistory
//

import Combine
import Foundation
import SwiftData
import Chat

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

        let schema = Schema(versionedSchema: ChatHistorySchemaV1.self)
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
        let rows = try fetchRows(conversationID: conversationID).map(\.row)
        return ConversationRecordRules.window(MessageRowCodec.messages(from: rows), window)
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
