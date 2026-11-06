//
//  InMemoryChatHistoryStorage.swift
//  ChatHistory
//

import Combine
import Foundation
import Chat
import ChatContext

/// A non-persistent `ChatHistoryStorage` for previews, tests and as a startup
/// fallback when the durable store cannot be opened. It shares the row codec
/// and change planner with the SwiftData store, so both behave the same.
@MainActor
public final class InMemoryChatHistoryStorage: ChatHistoryStorage {
    private var records: [UUID: ConversationRecord] = [:]
    private var rowsByConversation: [UUID: [UUID: MessageRow]] = [:]
    private var nextSortOrders: [UUID: Int64] = [:]
    private var checkpointsByConversation: [UUID: [ContextCheckpoint]] = [:]
    private let titleGenerator: any ConversationTitleGenerating
    private let now: () -> Date
    private let subject = PassthroughSubject<ChatHistoryChange, Never>()

    /// Test seam: runs before every commit; throwing leaves state unchanged.
    public var saveHook: (() throws -> Void)?

    public var changes: AnyPublisher<ChatHistoryChange, Never> { subject.eraseToAnyPublisher() }

    public init(
        titleGenerator: any ConversationTitleGenerating = PrefixConversationTitleGenerator(),
        now: @escaping () -> Date = Date.init
    ) {
        self.titleGenerator = titleGenerator
        self.now = now
    }

    public func conversations(matching query: ConversationQuery) throws -> [ConversationRecord] {
        var textMatches = Set<UUID>()
        if let text = query.normalizedText {
            for (conversationID, rows) in rowsByConversation
            where rows.values.contains(where: { $0.plainText.localizedStandardContains(text) }) {
                textMatches.insert(conversationID)
            }
        }
        return ConversationRecordRules.filter(Array(records.values), query: query, messageTextMatches: textMatches)
    }

    public func conversation(id: UUID) throws -> ConversationRecord? {
        records[id]
    }

    @discardableResult
    public func createConversation(_ draft: ConversationDraft) throws -> ConversationRecord {
        guard records[draft.id] == nil else { throw ChatHistoryError.conversationAlreadyExists(draft.id) }
        let record = ConversationRecordRules.record(from: draft, now: now())
        try saveHook?()
        records[record.id] = record
        rowsByConversation[record.id] = [:]
        nextSortOrders[record.id] = 0
        subject.send(.conversationUpserted(record.id))
        return record
    }

    @discardableResult
    public func updateConversation(id: UUID, _ patch: ConversationPatch) throws -> ConversationRecord {
        guard var record = records[id] else { throw ChatHistoryError.conversationNotFound(id) }
        ConversationRecordRules.apply(patch, to: &record, now: now())
        try saveHook?()
        records[id] = record
        subject.send(.conversationUpserted(id))
        return record
    }

    public func deleteConversations(ids: Set<UUID>) throws {
        let deleted = ids.intersection(records.keys)
        guard !deleted.isEmpty else { return }
        try saveHook?()
        for id in deleted {
            records.removeValue(forKey: id)
            rowsByConversation.removeValue(forKey: id)
            nextSortOrders.removeValue(forKey: id)
            checkpointsByConversation.removeValue(forKey: id)
        }
        subject.send(.conversationsDeleted(deleted))
    }

    public func loadMessages(conversationID: UUID, window: MessageWindow) throws -> [Message] {
        guard records[conversationID] != nil else { throw ChatHistoryError.conversationNotFound(conversationID) }
        let rows = Array((rowsByConversation[conversationID] ?? [:]).values)
        guard let selected = MessageWindowPlanner.selectedIDs(for: window, keys: rows.map(MessageRowKey.init)) else {
            return MessageRowCodec.messages(from: rows)
        }
        return MessageRowCodec.messages(from: rows.filter { selected.contains($0.id) })
    }

    public func applyMessageChanges(_ changes: MessageChangeSet, conversationID: UUID) throws {
        guard var record = records[conversationID] else {
            throw ChatHistoryError.conversationNotFound(conversationID)
        }
        guard !changes.isEmpty else { return }
        var rows = rowsByConversation[conversationID] ?? [:]
        let plan = try MessageChangePlanner.plan(
            changes,
            existing: rows,
            nextSortOrder: nextSortOrders[conversationID] ?? 0
        )
        guard !plan.isNoOp else { return }
        var checkpoints = checkpointsByConversation[conversationID] ?? []
        if !plan.deletedIDs.isEmpty {
            let (updated, removed) = CheckpointRules.adjustments(
                for: checkpoints,
                deletedIDs: plan.deletedIDs,
                previousKeys: rows.values.map(MessageRowKey.init),
                remainingKeys: plan.remainingKeys
            )
            let updatedByID = Dictionary(updated.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            checkpoints = checkpoints.compactMap { removed.contains($0.id) ? nil : (updatedByID[$0.id] ?? $0) }
        }
        for id in plan.deletedIDs { rows.removeValue(forKey: id) }
        for row in plan.writes { rows[row.id] = row }
        ConversationRecordRules.apply(plan.summary, titleGenerator: titleGenerator, to: &record, updatedAt: now())

        try saveHook?()
        rowsByConversation[conversationID] = rows
        checkpointsByConversation[conversationID] = checkpoints
        nextSortOrders[conversationID] = plan.nextSortOrder
        records[conversationID] = record
        subject.send(.messagesChanged(conversationID))
        subject.send(.conversationUpserted(conversationID))
    }

    // MARK: Checkpoints

    public func checkpoints(conversationID: UUID) throws -> [ContextCheckpoint] {
        guard records[conversationID] != nil else { throw ChatHistoryError.conversationNotFound(conversationID) }
        return (checkpointsByConversation[conversationID] ?? []).sorted { ContextCheckpoint.isNewer($1, than: $0) }
    }

    public func latestCheckpoint(conversationID: UUID) throws -> ContextCheckpoint? {
        guard records[conversationID] != nil else { throw ChatHistoryError.conversationNotFound(conversationID) }
        return checkpointsByConversation[conversationID]?.min(by: ContextCheckpoint.isNewer)
    }

    public func saveCheckpoint(_ checkpoint: ContextCheckpoint) throws {
        let conversationID = checkpoint.conversationID
        guard records[conversationID] != nil else { throw ChatHistoryError.conversationNotFound(conversationID) }
        let rows = (rowsByConversation[conversationID] ?? [:]).values
        try CheckpointRules.validate(checkpoint, keys: rows.map(MessageRowKey.init))
        try saveHook?()
        var checkpoints = checkpointsByConversation[conversationID] ?? []
        checkpoints.removeAll { $0.id == checkpoint.id }
        checkpoints.append(checkpoint)
        checkpointsByConversation[conversationID] = checkpoints
    }

    @discardableResult
    public func importConversation(_ draft: ConversationDraft, messages: [Message]) throws -> ConversationRecord {
        guard records[draft.id] == nil else { throw ChatHistoryError.conversationAlreadyExists(draft.id) }
        var record = ConversationRecordRules.record(from: draft, now: now())
        let (rows, nextSortOrder) = try ConversationRecordRules.importRows(
            for: messages,
            draft: draft,
            record: &record,
            titleGenerator: titleGenerator
        )
        try saveHook?()
        records[record.id] = record
        rowsByConversation[record.id] = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        nextSortOrders[record.id] = nextSortOrder
        subject.send(.conversationUpserted(record.id))
        subject.send(.messagesChanged(record.id))
        return record
    }
}
