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
/// through the property itself (which persists it), then persisted keys that
/// the pin's `saveSettings()` write materialized — including keys that were
/// originally absent — are restored from the snapshot. Only changed keys are
/// touched, so untouched global-domain values are never copied into the app
/// domain.
@MainActor
struct ToolSettingsAmbientSnapshot {
    private let original = UserDefaults.standard.dictionaryRepresentation()
    private let keepsToolCallsInHistory: Bool

    init() {
        keepsToolCallsInHistory = ToolSettings.shared.keepsToolCallsInHistory
    }

    func restore() {
        ToolSettings.shared.keepsToolCallsInHistory = keepsToolCallsInHistory
        let defaults = UserDefaults.standard
        let current = defaults.dictionaryRepresentation()
        for key in Set(original.keys).union(current.keys) {
            let before = original[key] as? NSObject
            let after = current[key] as? NSObject
            guard before != after else { continue }
            if let value = original[key] {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }
}