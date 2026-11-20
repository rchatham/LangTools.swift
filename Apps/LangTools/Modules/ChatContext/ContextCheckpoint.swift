//
//  ContextCheckpoint.swift
//  ChatContext
//

import Foundation

/// A stable summary of a conversation's older turns.
///
/// Requests replay the summary followed by the messages after
/// `coversThroughMessageID`. A checkpoint never changes once written; when
/// the conversation outgrows it, a new checkpoint folds the old summary and
/// the next turns together. The stored messages themselves are never
/// changed or deleted by compaction.
public struct ContextCheckpoint: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var conversationID: UUID
    /// The last message the summary covers.
    public var coversThroughMessageID: UUID
    public var summary: String
    public var tokenEstimate: Int
    /// The model that wrote the summary (a `Model` raw value), or
    /// `ContextSummary.extractiveModelName`.
    public var model: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        conversationID: UUID,
        coversThroughMessageID: UUID,
        summary: String,
        tokenEstimate: Int,
        model: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.conversationID = conversationID
        self.coversThroughMessageID = coversThroughMessageID
        self.summary = summary
        self.tokenEstimate = tokenEstimate
        self.model = model
        self.createdAt = createdAt
    }

    /// Newest first: by creation time, then by ID for a stable order.
    public static func isNewer(_ lhs: ContextCheckpoint, than rhs: ContextCheckpoint) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        return lhs.id.uuidString > rhs.id.uuidString
    }
}

/// Where a conversation's checkpoints are kept. `ChatHistoryStorage` is one.
@MainActor
public protocol ContextCheckpointStore: AnyObject {
    /// The newest checkpoint of a conversation, if any.
    func latestCheckpoint(conversationID: UUID) throws -> ContextCheckpoint?
    /// Changes when existing transcript content is removed. Preparers use
    /// this process-local revision to discard transient summaries and reject
    /// summaries produced concurrently with deletion.
    func contextRevision(conversationID: UUID) -> UInt64
    /// Saves a new checkpoint. Stores may reject one whose covered message
    /// they do not have.
    func saveCheckpoint(_ checkpoint: ContextCheckpoint) throws
}

public extension ContextCheckpointStore {
    /// Immutable/non-editable hosts need no revision tracking.
    func contextRevision(conversationID: UUID) -> UInt64 { 0 }
}

/// Checkpoints kept in memory, for conversations that are not persisted and
/// for tests.
@MainActor
public final class InMemoryContextCheckpointStore: ContextCheckpointStore {
    public private(set) var checkpoints: [ContextCheckpoint] = []
    /// Test seam: runs before every save; throwing simulates a failed save.
    public var saveHook: (() throws -> Void)?

    public init(checkpoints: [ContextCheckpoint] = []) {
        self.checkpoints = checkpoints
    }

    public func latestCheckpoint(conversationID: UUID) throws -> ContextCheckpoint? {
        checkpoints.filter { $0.conversationID == conversationID }.min(by: ContextCheckpoint.isNewer)
    }

    public func saveCheckpoint(_ checkpoint: ContextCheckpoint) throws {
        try saveHook?()
        checkpoints.append(checkpoint)
    }
}
