import Foundation
import OpenAI
import ToolKit
import XCTest
@testable import Chat

@MainActor
final class FixturePreferenceSnapshotTests: XCTestCase {
    func testAmbientSnapshotRestoresFalseAndPreservesUnrelatedWrites() throws {
        try withDefaults { defaults, _ in
            defaults.set(false, forKey: "keepsToolCallsInHistory")
            defaults.set(false, forKey: "richContentEnabled")
            defaults.set("before", forKey: "unrelated-existing")
            let settings = ToolSettings(defaults: defaults)
            let snapshot = ToolSettingsAmbientSnapshot(defaults: defaults, settings: { settings })
            settings.keepsToolCallsInHistory = true
            defaults.set("after", forKey: "unrelated-existing")
            defaults.set("new", forKey: "unrelated-new")
            snapshot.restore()
            XCTAssertFalse(settings.keepsToolCallsInHistory)
            XCTAssertEqual(defaults.object(forKey: "keepsToolCallsInHistory") as? Bool, false)
            XCTAssertEqual(defaults.object(forKey: "richContentEnabled") as? Bool, false)
            XCTAssertEqual(defaults.string(forKey: "unrelated-existing"), "after")
            XCTAssertEqual(defaults.string(forKey: "unrelated-new"), "new")
        }
    }

    func testAmbientSnapshotRestoresAbsentKeysMaterializedByRealSetters() throws {
        try withDefaults { defaults, _ in
            var initializedSettings: ToolSettings?
            let snapshot = ToolSettingsAmbientSnapshot(defaults: defaults, settings: {
                let settings = ToolSettings(defaults: defaults)
                initializedSettings = settings
                return settings
            })
            let settings = try XCTUnwrap(initializedSettings)
            settings.keepsToolCallsInHistory = false
            let manager = ToolManager(defaults: defaults)
            manager.toolsEnabled = false
            defaults.set("openai/gpt-4o", forKey: "model")
            XCTAssertNotNil(defaults.object(forKey: "voiceInputEnabled"))
            XCTAssertNotNil(defaults.object(forKey: "ToolKit.toolSettingsInitialized"))
            snapshot.restore()
            XCTAssertTrue(settings.keepsToolCallsInHistory)
            for key in FixturePreferenceKeys.ambient {
                XCTAssertNil(defaults.object(forKey: key), "Originally absent: \(key)")
            }
        }
    }

    func testSettingsSnapshotRestoresOwnedValuesAndAbsenceWithoutOtherStoreWrites() throws {
        try withDefaults { defaults, _ in
            defaults.set(false, forKey: "keepsToolCallsInHistory")
            defaults.set("old-model", forKey: "model")
            defaults.set("old prompt", forKey: "systemMessage")
            defaults.set("before", forKey: "chat_generation_settings")
            let snapshot = MR21PreferenceSnapshot(defaults: defaults)
            let settings = ToolSettings(defaults: defaults)
            settings.keepsToolCallsInHistory = true
            let manager = ToolManager(defaults: defaults)
            manager.toolsEnabled = false
            defaults.set("new-model", forKey: "model")
            defaults.set("fixture prompt", forKey: "systemMessage")
            // These belong to other producers, not the injected memory stores.
            defaults.set("after", forKey: "chat_generation_settings")
            defaults.set("new", forKey: "unrelated-new")
            snapshot.restore()
            XCTAssertEqual(defaults.object(forKey: "keepsToolCallsInHistory") as? Bool, false)
            XCTAssertEqual(defaults.string(forKey: "model"), "old-model")
            XCTAssertEqual(defaults.string(forKey: "systemMessage"), "old prompt")
            for key in FixturePreferenceKeys.settingsView where !["keepsToolCallsInHistory", "model", "systemMessage"].contains(key) {
                XCTAssertNil(defaults.object(forKey: key), "Originally absent: \(key)")
            }
            XCTAssertEqual(defaults.string(forKey: "chat_generation_settings"), "after")
            XCTAssertEqual(defaults.string(forKey: "unrelated-new"), "new")
        }
    }

    func testAuditedKeysMatchRealToolSettingsAndManagerWrites() throws {
        try withDefaults { defaults, suite in
            let settings = ToolSettings(defaults: defaults)
            settings.maxToolIterations = 3
            settings.toolTimeoutSeconds = 12
            settings.agentModelOverride = .openAI(.gpt4o)
            XCTAssertEqual(Set(defaults.persistentDomain(forName: suite)?.keys.map { $0 } ?? []), Set(FixturePreferenceKeys.toolSettings))
            defaults.removePersistentDomain(forName: suite)
            let manager = ToolManager(defaults: defaults)
            manager.toolsEnabled = false
            XCTAssertEqual(Set(defaults.persistentDomain(forName: suite)?.keys.map { $0 } ?? []), Set(FixturePreferenceKeys.toolManager))
        }
    }

    private func withDefaults(_ body: (UserDefaults, String) throws -> Void) throws {
        let suite = "FixturePreferenceSnapshotTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults, suite)
    }
}
