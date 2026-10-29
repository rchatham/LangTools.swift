import Foundation

public protocol ChatConversationSettingsStoring {
    func load() -> ChatConversationSettings
    func save(_ settings: ChatConversationSettings)
    func reset()
}

public final class ChatConversationSettingsStore: ChatConversationSettingsStoring {
    private static let storageKey = "chat_conversation_settings"

    private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    public func load() -> ChatConversationSettings {
        guard let data = userDefaults.data(forKey: Self.storageKey),
              let settings = try? JSONDecoder().decode(ChatConversationSettings.self, from: data) else {
            return loadLegacy()
        }
        return settings
    }

    /// Migrate from legacy UserDefaults keys on first load.
    private func loadLegacy() -> ChatConversationSettings {
        let prompt = userDefaults.string(forKey: "systemMessage")
            ?? ChatConversationSettings.defaultSystemPrompt
        return ChatConversationSettings(systemPrompt: prompt)
    }

    public func save(_ settings: ChatConversationSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        userDefaults.set(data, forKey: Self.storageKey)
        // Keep legacy key in sync for consumers that read it directly
        userDefaults.set(settings.systemPrompt, forKey: "systemMessage")
    }

    public func reset() {
        let defaults = ChatConversationSettings.default
        save(defaults)
    }
}