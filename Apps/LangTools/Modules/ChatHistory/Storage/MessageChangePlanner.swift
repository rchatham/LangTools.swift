//
//  MessageChangePlanner.swift
//  ChatHistory
//
//  Pure planning for `ChatHistoryStorage.applyMessageChanges`. Stores fetch
//  the conversation's rows, ask the planner what to write, then persist the
//  plan in one transaction. Keeping this logic out of the backends means the
//  SwiftData and in-memory stores cannot drift apart.
//

import Foundation

struct ConversationSummary: Equatable {
    var messageCount: Int
    var lastMessageAt: Date?
    var lastMessagePreview: String?
    var firstUserText: String?
}

struct MessageChangePlan {
    /// Rows to remove (requested deletions plus their descendants).
    var deletedIDs: Set<UUID>
    /// Final values of every inserted or updated row, in write order.
    var writes: [MessageRow]
    var nextSortOrder: Int64
    var summary: ConversationSummary
    /// Every row after the batch, without payloads, for checkpoint upkeep.
    var remainingKeys: [MessageRowKey]
    /// True when the batch would not change any stored row. Stores skip the
    /// save so re-saving identical messages does not reorder conversations.
    var isNoOp: Bool
}

enum MessageChangePlanner {
    /// Plans one batch against the conversation's current rows.
    ///
    /// Semantics match Botsworth's legacy `persistMessages(_:removingMessageIDs:to:)`:
    /// - deletions run first and remove descendants too;
    /// - upserts keep an existing row's `sortOrder`, new rows take the next one;
    /// - a top-level upsert whose `parent` is unavailable keeps the stored
    ///   parent, so a child never becomes top-level because a weak pointer is nil;
    /// - a child saved before its parent is kept and attaches once the parent exists.
    static func plan(
        _ changes: MessageChangeSet,
        existing: [UUID: MessageRow],
        nextSortOrder: Int64
    ) throws -> MessageChangePlan {
        var rows = existing
        var next = nextSortOrder

        var deleted = Set<UUID>()
        if !changes.deletions.isEmpty {
            var childrenByParent: [UUID: [UUID]] = [:]
            for row in rows.values {
                if let parentID = row.parentID { childrenByParent[parentID, default: []].append(row.id) }
            }
            var stack = Array(changes.deletions)
            while let id = stack.popLast() {
                guard deleted.insert(id).inserted else { continue }
                stack += childrenByParent[id] ?? []
            }
            for id in deleted { rows.removeValue(forKey: id) }
        }

        var writes: [UUID: MessageRow] = [:]
        var writeOrder: [UUID] = []
        for message in changes.upserts {
            let explicitParentID = message.parent?.uuid
            for var row in try MessageRowCodec.rows(for: message, parentID: explicitParentID) {
                if let stored = rows[row.id] {
                    row.sortOrder = stored.sortOrder
                    if row.id == message.uuid && explicitParentID == nil {
                        row.parentID = stored.parentID
                    }
                } else {
                    row.sortOrder = next
                    next += 1
                }
                rows[row.id] = row
                if writes[row.id] == nil { writeOrder.append(row.id) }
                writes[row.id] = row
            }
        }

        let deletedIDs = deleted.subtracting(writes.keys).intersection(existing.keys)
        let orderedWrites = writeOrder.compactMap { writes[$0] }
        return MessageChangePlan(
            deletedIDs: deletedIDs,
            writes: orderedWrites,
            nextSortOrder: next,
            summary: summary(of: Array(rows.values)),
            remainingKeys: rows.values.map(MessageRowKey.init),
            isNoOp: deletedIDs.isEmpty && orderedWrites.allSatisfy { existing[$0.id] == $0 }
        )
    }

    static func summary(of rows: [MessageRow]) -> ConversationSummary {
        let ordered = rows.sorted(by: MessageRowCodec.isOrdered)
        let topLevel = MessageRowCodec.topLevel(ordered)
        return ConversationSummary(
            messageCount: topLevel.count,
            lastMessageAt: ordered.last?.createdAt,
            lastMessagePreview: topLevel.last.flatMap { MessageRowCodec.preview($0.plainText) },
            firstUserText: topLevel.first { $0.role == "user" }?.plainText
        )
    }
}

// MARK: - Titles

/// Produces automatic conversation titles.
public protocol ConversationTitleGenerating: Sendable {
    /// A title for a conversation whose first user message is `text`, or
    /// `nil` to keep the current title.
    func title(forFirstUserMessage text: String) -> String?
}

/// The first line of the first user message, up to `maxLength` characters,
/// with "..." when truncated. Ported from Botsworth's `Conversation.generateTitle`.
public struct PrefixConversationTitleGenerator: ConversationTitleGenerating {
    public var maxLength: Int

    public init(maxLength: Int = 50) {
        self.maxLength = maxLength
    }

    public func title(forFirstUserMessage text: String) -> String? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var title: String
        if let newlineIndex = text.firstIndex(of: "\n") {
            let distance = text.distance(from: text.startIndex, to: newlineIndex)
            title = String(text.prefix(min(distance, maxLength)))
        } else {
            title = String(text.prefix(maxLength))
        }
        if text.count > title.count {
            title += "..."
        }
        return title
    }
}
