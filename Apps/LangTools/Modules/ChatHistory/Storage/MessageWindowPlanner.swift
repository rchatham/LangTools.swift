//
//  MessageWindowPlanner.swift
//  ChatHistory
//
//  Pure planning for windowed loads and for keeping checkpoints valid.
//  Stores fetch only the columns in `MessageRowKey`, ask the planner which
//  rows a window selects, then decode just those payloads. Both backends use
//  this code, so windows and checkpoints behave identically.
//

import Foundation
import ChatContext

/// The columns that order rows and shape their tree, without the payload.
struct MessageRowKey: Equatable, MessageRowOrdering {
    var id: UUID
    var parentID: UUID?
    var sortOrder: Int64
    var createdAt: Date
    var contentKind: String

    init(id: UUID, parentID: UUID?, sortOrder: Int64, createdAt: Date, contentKind: String) {
        self.id = id
        self.parentID = parentID
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.contentKind = contentKind
    }

    init(_ row: MessageRow) {
        self.init(id: row.id, parentID: row.parentID, sortOrder: row.sortOrder, createdAt: row.createdAt, contentKind: row.contentKind)
    }
}

/// The message tree of one conversation, resolved from row keys with the
/// same rules as `MessageRowCodec.messages(from:)`: a row is a child only
/// when its parent exists, is an agent event and is not part of a cycle.
struct MessageRowTree {
    let ordered: [MessageRowKey]
    /// Top-level row IDs in display order.
    let topLevel: [UUID]
    private let rootByID: [UUID: UUID]

    init(_ keys: [MessageRowKey]) {
        let ordered = keys.sorted(by: MessageRowCodec.isOrdered)
        let byID = Dictionary(ordered.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        func attachesToParent(_ key: MessageRowKey) -> Bool {
            guard let parentID = key.parentID, let parent = byID[parentID],
                  parent.contentKind == MessageRowCodec.agentEventKind else { return false }
            var seen: Set<UUID> = [key.id]
            var current: UUID? = parentID
            while let id = current {
                guard seen.insert(id).inserted else { return false }
                current = byID[id]?.parentID
            }
            return true
        }

        var rootByID: [UUID: UUID] = [:]
        var topLevel: [UUID] = []
        for key in ordered where !attachesToParent(key) {
            topLevel.append(key.id)
            rootByID[key.id] = key.id
        }
        // Attached rows resolve to their parent's root; parents may sort
        // after children when timestamps tie, so iterate until settled.
        var unresolved = ordered.filter { rootByID[$0.id] == nil }
        while !unresolved.isEmpty {
            let before = unresolved.count
            unresolved = unresolved.filter { key in
                guard let parentID = key.parentID, let root = rootByID[parentID] else { return true }
                rootByID[key.id] = root
                return false
            }
            if unresolved.count == before { break }
        }
        self.ordered = ordered
        self.topLevel = topLevel
        self.rootByID = rootByID
    }

    func root(of id: UUID) -> UUID? { rootByID[id] }

    /// IDs of the rows whose top-level ancestor is in `roots`.
    func rows(under roots: some Sequence<UUID>) -> Set<UUID> {
        let roots = Set(roots)
        return Set(ordered.compactMap { key in rootByID[key.id].flatMap { roots.contains($0) ? key.id : nil } })
    }
}

enum MessageWindowPlanner {
    /// The rows `window` selects, or `nil` when it selects every row.
    static func selectedIDs(for window: MessageWindow, keys: [MessageRowKey]) -> Set<UUID>? {
        if case .all = window { return nil }
        let tree = MessageRowTree(keys)
        let topLevel = tree.topLevel
        let roots: ArraySlice<UUID>
        switch window {
        case .all:
            return nil
        case .latest(let count):
            roots = topLevel.suffix(max(0, count))
        case .since(let messageID, let minimumCount):
            guard let index = topLevel.firstIndex(of: messageID) else { return nil }
            roots = topLevel[min(index, max(0, topLevel.count - max(0, minimumCount)))...]
        case .before(let messageID, let limit):
            guard let index = topLevel.firstIndex(of: messageID) else { return [] }
            roots = topLevel[max(0, index - max(0, limit))..<index]
        }
        if roots.count == topLevel.count { return nil }
        return tree.rows(under: roots)
    }
}

// MARK: - Checkpoints

enum CheckpointRules {
    /// A checkpoint must cover a stored top-level message.
    static func validate(_ checkpoint: ContextCheckpoint, keys: [MessageRowKey]) throws {
        guard MessageRowTree(keys).topLevel.contains(checkpoint.coversThroughMessageID) else {
            throw ChatHistoryError.messageNotFound(checkpoint.coversThroughMessageID)
        }
    }

    /// A summary cannot be edited reliably to remove deleted content. Drop
    /// every checkpoint that covers a deleted message (including children),
    /// preserving only summaries strictly before the earliest deletion.
    static func adjustments(
        for checkpoints: [ContextCheckpoint],
        deletedIDs: Set<UUID>,
        previousKeys: [MessageRowKey],
        remainingKeys: [MessageRowKey]
    ) -> (updated: [ContextCheckpoint], removed: Set<UUID>) {
        let tree = MessageRowTree(previousKeys)
        let positions = Dictionary(uniqueKeysWithValues: tree.topLevel.enumerated().map { ($0.element, $0.offset) })
        let deletedPositions = deletedIDs.compactMap { tree.root(of: $0).flatMap { positions[$0] } }
        guard let earliest = deletedPositions.min() else { return ([], []) }
        let removed = checkpoints.filter {
            guard let boundary = positions[$0.coversThroughMessageID] else { return true }
            return boundary >= earliest
        }
        return ([], Set(removed.map(\.id)))
    }
}
