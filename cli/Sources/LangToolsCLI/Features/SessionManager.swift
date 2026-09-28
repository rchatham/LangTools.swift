//
//  SessionManager.swift
//  CLI
//
//  Manages conversation session persistence
//

import Foundation

/// A saved conversation session
struct SavedSession: Codable, Identifiable {
    let id: UUID
    let name: String
    let createdAt: Date
    var updatedAt: Date
    var messages: [SavedMessage]
    var metadata: SessionMetadata

    struct SessionMetadata: Codable {
        var workingDirectory: String
        var model: String
        var totalTokens: Int
        var messageCount: Int
    }
}

/// A saved message
struct SavedMessage: Codable, Identifiable {
    let id: UUID
    let role: MessageRole
    let content: String
    let timestamp: Date
    var toolCalls: [SavedToolCall]?

    enum MessageRole: String, Codable {
        case user
        case assistant
        case tool
        case system
    }
}

/// A saved tool call
struct SavedToolCall: Codable {
    let id: String
    let name: String
    let arguments: String
    let result: String?
}

/// Manages session persistence
final class SessionManager {
    /// Shared singleton instance
    static let shared = SessionManager()

    /// Sessions directory
    private let sessionsDirectory: URL

    /// Current session ID
    var currentSessionId: UUID?

    /// Retained so a failed initialization can be surfaced by the next
    /// throwing persistence operation instead of being silently ignored.
    private var directoryPreparationError: Error?

    /// Auto-save interval in seconds
    var autoSaveInterval: TimeInterval = 30

    init(sessionsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude")
        .appendingPathComponent("sessions")) {
        self.sessionsDirectory = sessionsDirectory

        do {
            try prepareSessionsDirectory()
        } catch {
            directoryPreparationError = error
        }
    }

    // MARK: - Session Operations

    /// Create a new session
    func createSession(name: String? = nil, workingDirectory: String, model: String) throws -> SavedSession {
        let session = SavedSession(
            id: UUID(),
            name: name ?? generateSessionName(),
            createdAt: Date(),
            updatedAt: Date(),
            messages: [],
            metadata: .init(
                workingDirectory: workingDirectory,
                model: model,
                totalTokens: 0,
                messageCount: 0
            )
        )

        // Do not activate the session until its initial snapshot is durable.
        try saveSession(session)
        currentSessionId = session.id
        return session
    }

    /// Load a session by ID
    func loadSession(id: UUID) throws -> SavedSession {
        try prepareSessionsDirectory()
        let fileURL = sessionsDirectory.appendingPathComponent("\(id.uuidString).json")

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw SessionError.sessionNotFound(id: id)
        }

        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SavedSession.self, from: data)
    }

    /// Save a session
    func saveSession(_ session: SavedSession) throws {
        try prepareSessionsDirectory()
        let fileURL = sessionsDirectory.appendingPathComponent("\(session.id.uuidString).json")
        var session = session
        session.updatedAt = Date()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(session)
        try data.write(to: fileURL, options: .atomic)
        // Atomic writes may replace the inode, so enforce the mode after every
        // write rather than only when the session is first created.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    /// Delete a session
    func deleteSession(id: UUID) throws {
        try prepareSessionsDirectory()
        let fileURL = sessionsDirectory.appendingPathComponent("\(id.uuidString).json")

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw SessionError.sessionNotFound(id: id)
        }

        try FileManager.default.removeItem(at: fileURL)

        if currentSessionId == id {
            currentSessionId = nil
        }
    }

    /// List all saved sessions
    func listSessions() throws -> [SavedSession] {
        try prepareSessionsDirectory()
        let files = try FileManager.default.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        )

        let jsonFiles = files.filter { $0.pathExtension == "json" }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return jsonFiles.compactMap { fileURL -> SavedSession? in
            guard let data = try? Data(contentsOf: fileURL),
                  let session = try? decoder.decode(SavedSession.self, from: data) else {
                return nil
            }
            return session
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// List only sessions created in this working directory.
    func listSessions(in workingDirectory: String) throws -> [SavedSession] {
        let directory = URL(fileURLWithPath: workingDirectory).resolvingSymlinksInPath().standardizedFileURL.path
        return try listSessions().filter {
            URL(fileURLWithPath: $0.metadata.workingDirectory).resolvingSymlinksInPath().standardizedFileURL.path == directory
        }
    }

    /// Resolve an unambiguous ID prefix in the current working directory.
    func session(matching prefix: String, in workingDirectory: String) throws -> SavedSession? {
        let matches = try listSessions(in: workingDirectory).filter {
            $0.id.uuidString.lowercased().hasPrefix(prefix.lowercased())
        }
        guard matches.count <= 1 else { throw SessionError.ambiguousSessionPrefix }
        return matches.first
    }

    /// Restore conversational roles and stable IDs for subsequent snapshots.
    func restoredMessages(from session: SavedSession) -> [Message] {
        session.messages.compactMap { saved in
            let role: Role
            switch saved.role {
            case .user: role = .user
            case .assistant: role = .assistant
            case .tool, .system: return nil
            }
            return Message(uuid: saved.id, text: saved.content, role: role)
        }
    }

    /// Persist the full current conversation atomically after each turn or clear.
    func replaceMessages(_ messages: [Message]) throws {
        guard let id = currentSessionId else { return }
        var session = try loadSession(id: id)
        let previousMessages = Dictionary(uniqueKeysWithValues: session.messages.map { ($0.id, $0) })
        session.messages = messages.compactMap { message in
            let role: SavedMessage.MessageRole
            switch message.role {
            case .user: role = .user
            case .assistant: role = .assistant
            default: return nil
            }
            let previous = previousMessages[message.uuid]
            return SavedMessage(id: message.uuid, role: role, content: message.text ?? "",
                                timestamp: previous?.timestamp ?? Date(), toolCalls: previous?.toolCalls)
        }
        session.metadata.messageCount = session.messages.count
        session.metadata.model = UserDefaults.model.rawValue
        try saveSession(session)
    }

    /// Get recent sessions (last 10)
    func recentSessions() throws -> [SavedSession] {
        let sessions = try listSessions()
        return Array(sessions.prefix(10))
    }

    // MARK: - Message Operations

    /// Add a message to the current session
    func addMessage(role: SavedMessage.MessageRole, content: String, toolCalls: [SavedToolCall]? = nil) throws {
        guard let id = currentSessionId else {
            throw SessionError.noActiveSession
        }

        var session = try loadSession(id: id)

        let message = SavedMessage(
            id: UUID(),
            role: role,
            content: content,
            timestamp: Date(),
            toolCalls: toolCalls
        )

        session.messages.append(message)
        session.metadata.messageCount = session.messages.count

        try saveSession(session)
    }

    /// Convert ChatMessage to SavedMessage
    func toSavedMessage(_ message: ChatMessage) -> SavedMessage {
        SavedMessage(
            id: message.id,
            role: messageRole(from: message.role),
            content: message.content,
            timestamp: message.timestamp,
            toolCalls: nil
        )
    }

    private func messageRole(from role: ChatMessage.Role) -> SavedMessage.MessageRole {
        switch role {
        case .user: return .user
        case .assistant: return .assistant
        case .toolCall, .toolResult: return .tool
        case .system: return .system
        }
    }

    // MARK: - Helpers

    private func prepareSessionsDirectory() throws {
        do {
            try FileManager.default.createDirectory(
                at: sessionsDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            // createDirectory leaves an existing directory's mode unchanged.
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: sessionsDirectory.path
            )
            directoryPreparationError = nil
        } catch {
            directoryPreparationError = error
            throw error
        }
    }

    private func generateSessionName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "session-\(formatter.string(from: Date()))"
    }
}

// MARK: - Errors

enum SessionError: LocalizedError {
    case sessionNotFound(id: UUID)
    case noActiveSession
    case ambiguousSessionPrefix
    case saveFailed(reason: String)
    case loadFailed(reason: String)

    var errorDescription: String? {
        switch self {
        case .sessionNotFound(let id):
            return "Session not found: \(id.uuidString)"
        case .noActiveSession:
            return "No active session"
        case .ambiguousSessionPrefix:
            return "Session ID prefix is ambiguous; enter more characters"
        case .saveFailed(let reason):
            return "Failed to save session: \(reason)"
        case .loadFailed(let reason):
            return "Failed to load session: \(reason)"
        }
    }
}
