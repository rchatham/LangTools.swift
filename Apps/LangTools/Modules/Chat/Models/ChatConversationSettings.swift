import Foundation

/// Conversation-level settings: system prompt, context window, memory fields.
public struct ChatConversationSettings: Codable, Equatable, Sendable {

    public struct MemoryField: Codable, Equatable, Identifiable, Sendable {
        public var id: UUID
        public var label: String
        public var value: String

        public init(id: UUID = UUID(), label: String, value: String) {
            self.id = id
            self.label = label
            self.value = value
        }
    }

    public let systemPrompt: String
    public let maxContextMessages: Int?
    public let contextWindowPercent: Int?
    public let memoryFields: [MemoryField]

    public static let `default` = ChatConversationSettings()

    public static let defaultSystemPrompt = "You are a helpful AI assistant."

    public init(
        systemPrompt: String = defaultSystemPrompt,
        maxContextMessages: Int? = nil,
        contextWindowPercent: Int? = nil,
        memoryFields: [MemoryField] = []
    ) {
        self.systemPrompt = systemPrompt
        self.maxContextMessages = maxContextMessages
        self.contextWindowPercent = contextWindowPercent
        self.memoryFields = memoryFields
    }
}