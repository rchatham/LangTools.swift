//
//  ToolSettings.swift
//  App
//
//  Created by Reid Chatham on 3/6/25.
//

import Foundation
import SwiftUI

/// Available speech-to-text provider options
public enum STTProvider: String, CaseIterable, Codable {
    case appleSpeech = "Apple Speech"
    case openAIWhisper = "OpenAI Whisper"
    case whisperKit = "WhisperKit"
}

/// Available WhisperKit model sizes
public enum WhisperKitModelSize: String, CaseIterable, Codable {
    case tiny = "tiny"
    case base = "base"
    case small = "small"
    case medium = "medium"
    case largeV3 = "large-v3"
    
    /// Display name with approximate size
    public var displayName: String {
        switch self {
        case .tiny: return "Tiny (~40MB)"
        case .base: return "Base (~75MB)"
        case .small: return "Small (~250MB)"
        case .medium: return "Medium (~750MB)"
        case .largeV3: return "Large-v3 (~1.5GB)"
        }
    }
}

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

    /// Selected STT provider type
    @Published public var sttProvider: STTProvider {
        didSet { saveSettings() }
    }

    /// When true, microphone button replaces send button when text field is empty
    @Published public var voiceButtonReplaceSend: Bool {
        didSet { saveSettings() }
    }

    /// Selected language for STT (ISO-639-1 code or "auto" for auto-detect)
    @Published public var sttLanguage: String {
        didSet { saveSettings() }
    }

    /// Selected WhisperKit model size
    @Published public var whisperKitModelSize: WhisperKitModelSize {
        didSet { saveSettings() }
    }

    /// Enable auto-stop recording on silence
    @Published public var autoStopOnSilence: Bool {
        didSet { saveSettings() }
    }

    /// Duration of silence (in seconds) before auto-stopping recording
    @Published public var silenceTimeoutSeconds: Double {
        didSet { saveSettings() }
    }

    // MARK: - Streaming Settings

    /// Enable streaming transcription (show partial results as you speak)
    @Published public var streamingTranscriptionEnabled: Bool {
        didSet { saveSettings() }
    }

    /// Enable simulated streaming for OpenAI (periodic API calls during recording)
    @Published public var enableOpenAISimulatedStreaming: Bool {
        didSet { saveSettings() }
    }

    /// Chunk interval in seconds for OpenAI simulated streaming
    @Published public var streamingChunkIntervalSeconds: Double {
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
        
        // Load STT provider, converting from raw string if necessary
        if let rawValue = UserDefaults.standard.string(forKey: "sttProviderRawValue"),
           let provider = STTProvider(rawValue: rawValue) {
            self.sttProvider = provider
        } else {
            self.sttProvider = .appleSpeech
        }
        
        self.voiceButtonReplaceSend = UserDefaults.standard.object(forKey: "voiceButtonReplaceSend") as? Bool ?? false
        self.sttLanguage = UserDefaults.standard.string(forKey: "sttLanguage") ?? "auto"
        
        // Load WhisperKit model size, converting from raw string if necessary
        if let rawValue = UserDefaults.standard.string(forKey: "whisperKitModelSize"),
           let modelSize = WhisperKitModelSize(rawValue: rawValue) {
            self.whisperKitModelSize = modelSize
        } else {
            self.whisperKitModelSize = .base
        }
        
        self.autoStopOnSilence = UserDefaults.standard.object(forKey: "autoStopOnSilence") as? Bool ?? true
        self.silenceTimeoutSeconds = UserDefaults.standard.object(forKey: "silenceTimeoutSeconds") as? Double ?? 2.0
        self.streamingTranscriptionEnabled = UserDefaults.standard.object(forKey: "streamingTranscriptionEnabled") as? Bool ?? true
        self.enableOpenAISimulatedStreaming = UserDefaults.standard.object(forKey: "enableOpenAISimulatedStreaming") as? Bool ?? true
        self.streamingChunkIntervalSeconds = UserDefaults.standard.object(forKey: "streamingChunkIntervalSeconds") as? Double ?? 3.0

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
        UserDefaults.standard.set(sttProvider.rawValue, forKey: "sttProviderRawValue")
        UserDefaults.standard.set(voiceButtonReplaceSend, forKey: "voiceButtonReplaceSend")
        UserDefaults.standard.set(sttLanguage, forKey: "sttLanguage")
        UserDefaults.standard.set(whisperKitModelSize.rawValue, forKey: "whisperKitModelSize")
        UserDefaults.standard.set(autoStopOnSilence, forKey: "autoStopOnSilence")
        UserDefaults.standard.set(silenceTimeoutSeconds, forKey: "silenceTimeoutSeconds")
        UserDefaults.standard.set(streamingTranscriptionEnabled, forKey: "streamingTranscriptionEnabled")
        UserDefaults.standard.set(enableOpenAISimulatedStreaming, forKey: "enableOpenAISimulatedStreaming")
        UserDefaults.standard.set(streamingChunkIntervalSeconds, forKey: "streamingChunkIntervalSeconds")
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
        sttProvider = .appleSpeech
        voiceButtonReplaceSend = false
        sttLanguage = "auto"
        whisperKitModelSize = .base
        autoStopOnSilence = true
        silenceTimeoutSeconds = 2.0
        streamingTranscriptionEnabled = true
        enableOpenAISimulatedStreaming = true
        streamingChunkIntervalSeconds = 3.0
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

