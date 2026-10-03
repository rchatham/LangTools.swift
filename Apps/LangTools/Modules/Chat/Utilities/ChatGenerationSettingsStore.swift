import CoreFoundation
import Foundation

public protocol ChatGenerationSettingsStoring {
    func load() -> ChatGenerationSettings
    func save(_ settings: ChatGenerationSettings)
    func reset()
}

public final class ChatGenerationSettingsStore: ChatGenerationSettingsStoring {
    private struct StoredSettings: Codable {
        let schemaVersion: Int
        let settings: ChatGenerationSettings
    }

    private enum Keys {
        static let settings = "chat_generation_settings"
        static let migrationVersion = "chat_generation_settings_migration_version"
        static let legacyMaxTokens = "max_tokens"
        static let legacyTemperature = "temperature"
    }

    private static let schemaVersion = 1
    private static let migrationVersion = 1
    private static let synchronizationLock = NSLock()

    private let userDefaults: UserDefaults

    // Test-only coordination point used to deterministically exercise cross-instance writes.
    var willPersist: ((ChatGenerationSettings) -> Void)?

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    public func load() -> ChatGenerationSettings {
        withSynchronizationLock {
            if userDefaults.object(forKey: Keys.settings) != nil {
                guard let payload = userDefaults.data(forKey: Keys.settings),
                      let stored = try? JSONDecoder().decode(StoredSettings.self, from: payload),
                      stored.schemaVersion == Self.schemaVersion else {
                    return .automatic
                }
                markMigrationCompleteIfNeeded()
                return stored.settings
            }

            guard !hasCompletedMigration else {
                return .automatic
            }

            let migrated = migratedLegacySettings()
            if persist(migrated) {
                markMigrationCompleteIfNeeded()
            }
            return migrated
        }
    }

    public func save(_ settings: ChatGenerationSettings) {
        withSynchronizationLock {
            if persist(settings) {
                markMigrationCompleteIfNeeded()
            }
        }
    }

    public func reset() {
        save(.automatic)
    }

    private var hasCompletedMigration: Bool {
        guard let number = numericValue(forKey: Keys.migrationVersion),
              let version = Int(exactly: number.doubleValue) else {
            return false
        }
        return version >= Self.migrationVersion
    }

    private func migratedLegacySettings() -> ChatGenerationSettings {
        let maxOutputTokens: Int? = {
            guard let number = numericValue(forKey: Keys.legacyMaxTokens),
                  let value = Int(exactly: number.doubleValue),
                  ChatGenerationSettings.tokenRange.contains(value) else {
                return nil
            }
            return value
        }()

        let temperature: Double? = {
            guard let value = numericValue(forKey: Keys.legacyTemperature)?.doubleValue,
                  value > 0,
                  value.isFinite,
                  ChatGenerationSettings.temperatureRange.contains(value) else {
                return nil
            }
            return value
        }()

        return (try? ChatGenerationSettings(
            maxOutputTokens: maxOutputTokens,
            temperature: temperature
        )) ?? .automatic
    }

    private func numericValue(forKey key: String) -> NSNumber? {
        guard let number = userDefaults.object(forKey: key) as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        return number
    }

    @discardableResult
    private func persist(_ settings: ChatGenerationSettings) -> Bool {
        willPersist?(settings)
        do {
            let payload = try JSONEncoder().encode(StoredSettings(
                schemaVersion: Self.schemaVersion,
                settings: settings
            ))
            userDefaults.set(payload, forKey: Keys.settings)
            return true
        } catch {
            assertionFailure("Unable to encode chat generation settings: \(error)")
            return false
        }
    }

    private func markMigrationCompleteIfNeeded() {
        guard !hasCompletedMigration else { return }
        userDefaults.set(Self.migrationVersion, forKey: Keys.migrationVersion)
    }

    private func withSynchronizationLock<T>(_ operation: () -> T) -> T {
        Self.synchronizationLock.lock()
        defer { Self.synchronizationLock.unlock() }
        return operation()
    }
}
