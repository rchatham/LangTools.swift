//
//  ChatHistoryExporter.swift
//  ChatHistory
//
//  Ported from Botsworth's MessageExportService. Markdown and plain text are
//  for reading; JSON is a versioned document that can be imported again.
//

import Foundation
import Chat

public enum ChatExportFormat: String, CaseIterable, Identifiable, Sendable {
    case markdown = "Markdown"
    case json = "JSON"
    case plainText = "Plain Text"

    public var id: String { rawValue }

    public var fileExtension: String {
        switch self {
        case .markdown: return "md"
        case .json: return "json"
        case .plainText: return "txt"
        }
    }

    public var mimeType: String {
        switch self {
        case .markdown: return "text/markdown"
        case .json: return "application/json"
        case .plainText: return "text/plain"
        }
    }
}

/// A lossless JSON export of one conversation.
///
/// Messages are a flat list in display order, with agent-event children
/// pointing at their parent, the same shape the store uses.
public struct ConversationExportDocument: Codable {
    public static let currentFormatVersion = 1

    public struct ConversationInfo: Codable, Equatable {
        public var id: UUID
        public var title: String
        public var createdAt: Date
        public var updatedAt: Date
        public var owner: ConversationOwner?
        public var threadKind: String?
        public var settings: ConversationSettingsOverrides
        public var metadata: [String: String]
    }

    public struct Entry: Codable {
        public var parentID: UUID?
        /// Readable copies for tools that do not decode `message`.
        public var role: String
        public var text: String
        public var message: Message
    }

    public var formatVersion: Int
    public var exportedAt: Date
    public var exportedBy: String?
    public var conversation: ConversationInfo
    public var messages: [Entry]

    /// The messages as trees, ready for `ChatHistoryStorage.importConversation`.
    public func messageTrees() -> [Message] {
        let rows = messages.enumerated().compactMap { index, entry -> MessageRow? in
            guard var row = try? MessageRowCodec.row(for: entry.message, parentID: entry.parentID) else { return nil }
            row.sortOrder = Int64(index)
            return row
        }
        return MessageRowCodec.messages(from: rows)
    }

    /// A draft that recreates the conversation with its original identity.
    public var draft: ConversationDraft {
        ConversationDraft(
            id: conversation.id,
            title: conversation.title,
            owner: conversation.owner,
            threadKind: conversation.threadKind,
            settings: conversation.settings,
            metadata: conversation.metadata,
            createdAt: conversation.createdAt,
            updatedAt: conversation.updatedAt
        )
    }
}

public struct ChatHistoryExporter {
    /// Shown in export footers, for example "Botsworth".
    public var appName: String
    public var now: () -> Date

    public init(appName: String, now: @escaping () -> Date = Date.init) {
        self.appName = appName
        self.now = now
    }

    public func export(_ record: ConversationRecord, messages: [Message], format: ChatExportFormat) -> String {
        switch format {
        case .markdown: return markdown(record, messages: messages)
        case .json: return json(record, messages: messages)
        case .plainText: return plainText(record, messages: messages)
        }
    }

    public func document(_ record: ConversationRecord, messages: [Message]) -> ConversationExportDocument {
        ConversationExportDocument(
            formatVersion: ConversationExportDocument.currentFormatVersion,
            exportedAt: now(),
            exportedBy: appName,
            conversation: .init(
                id: record.id,
                title: record.title,
                createdAt: record.createdAt,
                updatedAt: record.updatedAt,
                owner: record.owner,
                threadKind: record.threadKind,
                settings: record.settings,
                metadata: record.metadata
            ),
            messages: Self.flatten(messages).map { message, parentID in
                .init(
                    parentID: parentID,
                    role: message.role.rawValue,
                    text: message.text ?? "",
                    message: MessageRowCodec.detachedCopy(of: message)
                )
            }
        )
    }

    public static func decodeDocument(from data: Data) throws -> ConversationExportDocument {
        try makeDecoder().decode(ConversationExportDocument.self, from: data)
    }

    public static func filename(for record: ConversationRecord, format: ChatExportFormat, date: Date = Date()) -> String {
        let sanitized = record.title
            .replacingOccurrences(of: "[^a-zA-Z0-9 ]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
            .prefix(50)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let base = sanitized.isEmpty ? "Conversation" : String(sanitized)
        return "\(base)_\(formatter.string(from: date)).\(format.fileExtension)"
    }

    // MARK: Formats

    private func markdown(_ record: ConversationRecord, messages: [Message]) -> String {
        var output = "# \(record.title)\n\n"
        output += "**Created:** \(Self.formatDate(record.createdAt))\n"
        if let model = record.settings.modelIdentifier {
            output += "**Model:** \(model)\n"
        }
        output += "\n---\n\n"
        for (message, _) in Self.flatten(messages) {
            output += "### \(Self.formatRole(message.role.rawValue)) (\(Self.formatTime(message.createdAt)))\n\n"
            let text = message.text ?? ""
            output += message.isAgentEvent ? "> \(text)\n\n" : "\(text)\n\n"
        }
        output += "---\n\n"
        output += "*Exported from \(appName) on \(Self.formatDate(now()))*\n"
        return output
    }

    private func plainText(_ record: ConversationRecord, messages: [Message]) -> String {
        var output = "\(record.title)\n"
        output += String(repeating: "=", count: record.title.count) + "\n\n"
        output += "Created: \(Self.formatDate(record.createdAt))\n"
        if let model = record.settings.modelIdentifier {
            output += "Model: \(model)\n"
        }
        output += "\n" + String(repeating: "-", count: 40) + "\n\n"
        for (message, _) in Self.flatten(messages) {
            output += "[\(Self.formatRole(message.role.rawValue).uppercased())] (\(Self.formatTime(message.createdAt)))\n"
            output += "\(message.text ?? "")\n\n"
        }
        output += String(repeating: "-", count: 40) + "\n"
        output += "Exported on \(Self.formatDate(now()))\n"
        return output
    }

    private func json(_ record: ConversationRecord, messages: [Message]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Self.isoFormatter.string(from: date))
        }
        guard let data = try? encoder.encode(document(record, messages: messages)),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }

    // MARK: Helpers

    /// Depth-first: each message, then its agent-event children.
    static func flatten(_ messages: [Message], parentID: UUID? = nil) -> [(Message, UUID?)] {
        messages.flatMap { message in
            [(message, parentID)] + flatten(message.childMessages, parentID: message.uuid)
        }
    }

    /// Fractional seconds keep imported messages in their original order.
    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = isoFormatter.date(from: string) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date \(string)")
            }
            return date
        }
        return decoder
    }

    private static func formatRole(_ role: String) -> String {
        switch role.lowercased() {
        case "user": return "You"
        case "assistant": return "Assistant"
        case "system": return "System"
        default: return role.capitalized
        }
    }

    private static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private static func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
