//
//  MessageRowCodec.swift
//  ChatHistory
//
//  Converts between `Message` trees and flat storage rows. Every backend
//  shares this codec so trees, ordering and fallbacks behave identically.
//

import Foundation
import Chat
import OpenAI

/// A backend-neutral image of one stored message.
///
/// Rows are flat: agent-event children point at their parent through
/// `parentID`. `payload` holds the full `Message` JSON (without children or
/// parent pointers), so fields added to `Message` later survive a round trip
/// without a schema migration. `plainText` and `role` are denormalized for
/// search, previews and decode fallbacks.
/// What chronological ordering needs from a row.
protocol MessageRowOrdering {
    var id: UUID { get }
    var createdAt: Date { get }
    var sortOrder: Int64 { get }
}

struct MessageRow: Equatable, MessageRowOrdering {
    var id: UUID
    var parentID: UUID?
    var sortOrder: Int64
    var createdAt: Date
    var role: String
    var contentKind: String
    var plainText: String
    var payload: Data
    var payloadVersion: Int
}

enum MessageRowCodec {
    static let payloadVersion = 1
    static let agentEventKind = "agentEvent"
    static let previewLength = 200

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    // MARK: Message → rows

    /// The message and its agent-event descendants, parents before children.
    /// `sortOrder` is left at 0; the change planner assigns it.
    static func rows(for message: Message, parentID: UUID?) throws -> [MessageRow] {
        var result = [try row(for: message, parentID: parentID)]
        for child in message.childMessages {
            result += try rows(for: child, parentID: message.uuid)
        }
        return result
    }

    static func row(for message: Message, parentID: UUID?) throws -> MessageRow {
        MessageRow(
            id: message.uuid,
            parentID: parentID,
            sortOrder: 0,
            createdAt: message.createdAt,
            role: message.role.rawValue,
            contentKind: contentKind(of: message.contentType),
            plainText: message.text ?? "",
            payload: try encoder.encode(detachedCopy(of: message)),
            payloadVersion: payloadVersion
        )
    }

    static func contentKind(of contentType: ContentType) -> String {
        switch contentType {
        case .null: return "null"
        case .string: return "string"
        case .array: return "array"
        case .agentEvent: return agentEventKind
        case .contentCards: return "contentCards"
        }
    }

    /// A copy without agent-event children or parent pointers.
    ///
    /// `AgentEventContent` synthesizes `Codable` for its weak `parent`, so
    /// encoding a child whose parent is set would recurse forever. Children
    /// are stored as their own rows instead.
    static func detachedCopy(of message: Message) -> Message {
        let contentType: ContentType
        if case .agentEvent(let content) = message.contentType {
            contentType = .agentEvent(
                AgentEventContent(type: content.type, agentName: content.agentName, details: content.details)
            )
        } else {
            contentType = message.contentType
        }
        let copy = Message(
            uuid: message.uuid,
            role: message.role,
            contentType: contentType,
            imageDetail: message.imageDetail,
            createdAt: message.createdAt,
            toolCalls: message.toolCalls,
            providerToolResults: message.providerToolResults,
            providerToolResultServices: message.providerToolResultServices,
            responseToMessageID: message.responseToMessageID
        )
        copy.wasResponseStopped = message.wasResponseStopped
        return copy
    }

    // MARK: Rows → messages

    /// Decodes one row. A payload that fails to decode falls back to a plain
    /// text message built from the denormalized columns, so a corrupt row
    /// degrades instead of hiding the conversation.
    static func decodeNode(_ row: MessageRow) -> Message {
        if let message = try? JSONDecoder().decode(Message.self, from: row.payload) {
            return message
        }
        return Message(
            uuid: row.id,
            role: Role(rawValue: row.role) ?? .user,
            contentType: .string(row.plainText),
            createdAt: row.createdAt
        )
    }

    /// Rebuilds top-level messages with their agent-event children, in order.
    ///
    /// A row becomes a child only when its parent exists, decoded as an agent
    /// event, and is not part of a parent cycle. Anything else is shown at the
    /// top level so no stored message is lost.
    static func messages(from rows: [MessageRow]) -> [Message] {
        let ordered = rows.sorted(by: isOrdered)
        var decoded: [UUID: Message] = [:]
        for row in ordered { decoded[row.id] = decodeNode(row) }
        let parents = Dictionary(ordered.map { ($0.id, $0.parentID) }, uniquingKeysWith: { first, _ in first })

        func attachesToParent(_ row: MessageRow) -> Bool {
            guard let parentID = row.parentID,
                  let parent = decoded[parentID], parent.isAgentEvent else { return false }
            // Walk up the chain; a repeat means a cycle, which is shown flat.
            var seen: Set<UUID> = [row.id]
            var current: UUID? = parentID
            while let id = current {
                guard seen.insert(id).inserted else { return false }
                current = parents[id] ?? nil
            }
            return true
        }

        var roots: [MessageRow] = []
        var childrenByParent: [UUID: [MessageRow]] = [:]
        for row in ordered {
            if attachesToParent(row), let parentID = row.parentID {
                childrenByParent[parentID, default: []].append(row)
            } else {
                roots.append(row)
            }
        }

        func build(_ row: MessageRow) -> Message {
            let message = decoded[row.id] ?? decodeNode(row)
            guard case .agentEvent(let content) = message.contentType,
                  let childRows = childrenByParent[row.id], !childRows.isEmpty else { return message }
            message.contentType = .agentEvent(
                AgentEventContent(
                    type: content.type,
                    agentName: content.agentName,
                    details: content.details,
                    children: childRows.map(build)
                )
            )
            return message
        }
        return roots.map(build)
    }

    /// Chronological order with deterministic tie-breaks. Kept identical to
    /// Botsworth's legacy store so imported conversations keep their order.
    static func isOrdered<Row: MessageRowOrdering>(_ lhs: Row, _ rhs: Row) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    /// Top-level rows: those without a parent present in `rows`.
    static func topLevel(_ rows: [MessageRow]) -> [MessageRow] {
        let ids = Set(rows.map(\.id))
        return rows.filter { row in row.parentID.map { !ids.contains($0) } ?? true }
    }

    static func preview(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count > previewLength ? String(trimmed.prefix(previewLength)) + "…" : trimmed
    }
}
