//
//  ToolSettingsAmbientSnapshot.swift
//  ChatTests
//
//  Restores ambient ToolSettings/UserDefaults state after fixture mutations.
//

import Chat
import Foundation

/// Captures ambient `ToolSettings` state before a fixture pins known values
/// and restores it afterward. The in-memory singleton value is restored
/// through the property itself (which persists it), then only audited fixture
/// keys are restored, including keys originally absent. Unrelated producer
/// writes are not part of this snapshot and survive teardown.
@MainActor
struct ToolSettingsAmbientSnapshot {
    private let preferences: FixturePreferenceSnapshot
    private let settings: ToolSettings
    private let keepsToolCallsInHistory: Bool

    init(defaults: UserDefaults = .standard, settings: () -> ToolSettings = { .shared }) {
        // Capture backing keys before the first singleton access/initialization.
        preferences = FixturePreferenceSnapshot(defaults: defaults, keys: FixturePreferenceKeys.ambient)
        self.settings = settings()
        keepsToolCallsInHistory = self.settings.keepsToolCallsInHistory
    }

    func restore() {
        settings.keepsToolCallsInHistory = keepsToolCallsInHistory
        preferences.restore()
    }
}
