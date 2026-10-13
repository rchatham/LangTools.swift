import Foundation

/// Audited write sets, not prefixes or a snapshot of the whole defaults domain.
/// Keep these in sync with ToolSettings.saveSettings(), ToolManager initialization
/// and persistence, and the fixture's model/system-message writes.
enum FixturePreferenceKeys {
    static let toolSettings = [
        "richContentEnabled", "keepsToolCallsInHistory", "crossProviderToolReplay",
        "voiceInputEnabled", "sttProviderRawValue", "voiceButtonReplaceSend",
        "sttLanguage", "whisperKitModelSize", "autoStopOnSilence",
        "silenceTimeoutSeconds", "streamingTranscriptionEnabled",
        "enableOpenAISimulatedStreaming", "streamingChunkIntervalSeconds",
        "maxToolIterations", "toolTimeoutSeconds", "autoRetryFailedTools",
        "agentModelOverride"
    ]
    static let toolManager = [
        "ToolKit.toolsEnabled", "ToolKit.toolEnabledStates",
        "ToolKit.toolSettingsInitialized"
    ]
    static let ambient = toolSettings + toolManager + ["model"]
    // The native fixture injects in-memory generation/conversation stores and a
    // proxy catalog. Only the legacy system-message save still reaches defaults;
    // generation settings, helper URLs/tokens and discovery caches are not owned.
    static let settingsView = ambient + ["systemMessage"]
}

/// Restore only owned, changed keys, retaining original values or absence.
/// Writes by other producers outside this set survive fixture teardown.
struct FixturePreferenceSnapshot {
    private let defaults: UserDefaults
    private let keys: Set<String>
    private let original: [String: NSObject]

    init(defaults: UserDefaults = .standard, keys: [String]) {
        self.defaults = defaults
        self.keys = Set(keys)
        original = self.keys.reduce(into: [:]) { values, key in
            if let value = defaults.object(forKey: key) as? NSObject {
                values[key] = value
            }
        }
    }

    func restore() {
        for key in keys {
            let before = original[key]
            let after = defaults.object(forKey: key) as? NSObject
            guard before != after else { continue }
            if let before { defaults.set(before, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
    }
}
