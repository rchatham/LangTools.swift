//
//  ToolSettings.swift
//  App
//
//  Created by Reid Chatham on 3/6/25.
//

import Foundation
import SwiftUI

/// Represents settings for all available tools in the app
public class ToolSettings: ObservableObject {
    // Singleton instance
    public static let shared = ToolSettings()

    /// Master switch to enable/disable all tools
    @Published var toolsEnabled: Bool {
        didSet {
            // If tools are disabled, ensure all individual tools are also disabled
            if !toolsEnabled {
                calendarToolEnabled = false
                remindersToolEnabled = false
                researchToolEnabled = false
                mapsToolEnabled = false
                contactsToolEnabled = false
                weatherToolEnabled = false
                filesToolEnabled = false
            }
            saveSettings()
        }
    }

    // Individual tool settings
    @Published var calendarToolEnabled: Bool {
        didSet { saveSettings() }
    }

    @Published var remindersToolEnabled: Bool {
        didSet { saveSettings() }
    }

    @Published var researchToolEnabled: Bool {
        didSet { saveSettings() }
    }

    @Published var mapsToolEnabled: Bool {
        didSet { saveSettings() }
    }

    @Published var contactsToolEnabled: Bool {
        didSet { saveSettings() }
    }

    @Published var weatherToolEnabled: Bool {
        didSet { saveSettings() }
    }

    @Published var filesToolEnabled: Bool {
        didSet { saveSettings() }
    }

    /// Enable/disable rich content cards (weather, contacts, events displayed as visual cards)
    @Published public var richContentEnabled: Bool {
        didSet { saveSettings() }
    }

    // MARK: - Voice Input (STT) Settings

    /// Enable/disable voice input
    @Published public var voiceInputEnabled: Bool {
        didSet { saveSettings() }
    }

    /// Selected STT provider type (stored as raw string value)
    @Published public var sttProviderRawValue: String {
        didSet { saveSettings() }
    }

    private init() {
        // Load settings from UserDefaults, defaulting to true if not set
        self.toolsEnabled = UserDefaults.standard.bool(forKey: "toolsEnabled")
        self.calendarToolEnabled = UserDefaults.standard.bool(forKey: "calendarToolEnabled")
        self.remindersToolEnabled = UserDefaults.standard.bool(forKey: "remindersToolEnabled")
        self.researchToolEnabled = UserDefaults.standard.bool(forKey: "researchToolEnabled")
        self.mapsToolEnabled = UserDefaults.standard.bool(forKey: "mapsToolEnabled")
        self.contactsToolEnabled = UserDefaults.standard.bool(forKey: "contactsToolEnabled")
        self.weatherToolEnabled = UserDefaults.standard.bool(forKey: "weatherToolEnabled")
        self.filesToolEnabled = UserDefaults.standard.bool(forKey: "filesToolEnabled")
        self.richContentEnabled = UserDefaults.standard.object(forKey: "richContentEnabled") as? Bool ?? true
        self.voiceInputEnabled = UserDefaults.standard.object(forKey: "voiceInputEnabled") as? Bool ?? true
        self.sttProviderRawValue = UserDefaults.standard.string(forKey: "sttProviderRawValue") ?? "Apple Speech"

        // If this is first launch, set defaults
        if !UserDefaults.standard.bool(forKey: "toolSettingsInitialized") {
            resetToDefaults()
            UserDefaults.standard.set(true, forKey: "toolSettingsInitialized")
        }
    }

    func saveSettings() {
        UserDefaults.standard.set(toolsEnabled, forKey: "toolsEnabled")
        UserDefaults.standard.set(calendarToolEnabled, forKey: "calendarToolEnabled")
        UserDefaults.standard.set(remindersToolEnabled, forKey: "remindersToolEnabled")
        UserDefaults.standard.set(researchToolEnabled, forKey: "researchToolEnabled")
        UserDefaults.standard.set(mapsToolEnabled, forKey: "mapsToolEnabled")
        UserDefaults.standard.set(contactsToolEnabled, forKey: "contactsToolEnabled")
        UserDefaults.standard.set(weatherToolEnabled, forKey: "weatherToolEnabled")
        UserDefaults.standard.set(filesToolEnabled, forKey: "filesToolEnabled")
        UserDefaults.standard.set(richContentEnabled, forKey: "richContentEnabled")
        UserDefaults.standard.set(voiceInputEnabled, forKey: "voiceInputEnabled")
        UserDefaults.standard.set(sttProviderRawValue, forKey: "sttProviderRawValue")
    }

    func resetToDefaults() {
        toolsEnabled = true
        calendarToolEnabled = true
        remindersToolEnabled = true
        researchToolEnabled = true
        mapsToolEnabled = true
        contactsToolEnabled = true
        weatherToolEnabled = true
        filesToolEnabled = true
        richContentEnabled = true
        voiceInputEnabled = true
        sttProviderRawValue = "Apple Speech"
        saveSettings()
    }

    /// Determine if a specific tool is enabled by name
    func isToolEnabled(name: String) -> Bool {
        guard toolsEnabled else { return false }

        switch name.lowercased() {
        case "manage_calendar":
            return calendarToolEnabled
        case "manage_reminders":
            return remindersToolEnabled
        case "perform_research":
            return researchToolEnabled
        case "manage_maps":
            return mapsToolEnabled
        case "manage_contacts":
            return contactsToolEnabled
        case "get_weather_information":
            return weatherToolEnabled
        case "manage_files":
            return filesToolEnabled
        default:
            // Unknown tools default to enabled if master switch is on
            return true
        }
    }
}

// Extension to UserDefaults for convenient access
extension UserDefaults {
    static var toolSettings: ToolSettings {
        get { ToolSettings.shared }
    }
}

