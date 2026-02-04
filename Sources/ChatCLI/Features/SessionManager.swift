//
//  SessionManager.swift
//  ChatCLI
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
    private(set) var currentSessionId: UUID?

    /// Auto-save interval in seconds
    var autoSaveInterval: TimeInterval = 30

    private init() {
        // Create sessions directory in ~/.claude/sessions/
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        self.sessionsDirectory = homeDir
            .appendingPathComponent(".claude")
            .appendingPathComponent("sessions")

        // Ensure directory exists
        try? FileManager.default.createDirectory(
            at: sessionsDirectory,
            withIntermediateDirectories: true
        )
    }

    // MARK: - Session Operations

    /// Create a new session
    func createSession(name: String? = nil, workingDirectory: String, model: String) -> SavedSession {
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

        currentSessionId = session.id

        // Save immediately
        try? saveSession(session)

        return session
    }

    /// Load a session by ID
    func loadSession(id: UUID) throws -> SavedSession {
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
        let fileURL = sessionsDirectory.appendingPathComponent("\(session.id.uuidString).json")
        var session = session
        session.updatedAt = Date()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(session)
        try data.write(to: fileURL)
    }

    /// Delete a session
    func deleteSession(id: UUID) throws {
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
        case .tool: return .tool
        case .system: return .system
        }
    }

    // MARK: - Helpers

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
    case saveFailed(reason: String)
    case loadFailed(reason: String)

    var errorDescription: String? {
        switch self {
        case .sessionNotFound(let id):
            return "Session not found: \(id.uuidString)"
        case .noActiveSession:
            return "No active session"
        case .saveFailed(let reason):
            return "Failed to save session: \(reason)"
        case .loadFailed(let reason):
            return "Failed to load session: \(reason)"
        }
    }
}
