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

/// Available language options for speech-to-text
public enum STTLanguage: String, CaseIterable, Codable {
    case auto = "auto"
    case english = "en"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case italian = "it"
    case portuguese = "pt"
    case chinese = "zh"
    case japanese = "ja"
    case korean = "ko"
    case arabic = "ar"
    case russian = "ru"
    case hindi = "hi"

    var displayName: String {
        switch self {
        case .auto: return "Auto-detect"
        case .english: return "English"
        case .spanish: return "Spanish"
        case .french: return "French"
        case .german: return "German"
        case .italian: return "Italian"
        case .portuguese: return "Portuguese"
        case .chinese: return "Chinese"
        case .japanese: return "Japanese"
        case .korean: return "Korean"
        case .arabic: return "Arabic"
        case .russian: return "Russian"
        case .hindi: return "Hindi"
        }
    }
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

/// Available silence timeout durations
public enum SilenceTimeout: Double, CaseIterable, Codable {
    case oneSecond = 1.0
    case oneAndHalfSeconds = 1.5
    case twoSeconds = 2.0
    case threeSeconds = 3.0
    case fiveSeconds = 5.0

    var displayName: String {
        switch self {
        case .oneSecond: return "1 second"
        case .oneAndHalfSeconds: return "1.5 seconds"
        case .twoSeconds: return "2 seconds"
        case .threeSeconds: return "3 seconds"
        case .fiveSeconds: return "5 seconds"
        }
    }
}

/// Available streaming chunk intervals
public enum StreamingChunkInterval: Double, CaseIterable, Codable {
    case twoSeconds = 2.0
    case threeSeconds = 3.0
    case fiveSeconds = 5.0

    var displayName: String {
        switch self {
        case .twoSeconds: return "2 seconds"
        case .threeSeconds: return "3 seconds"
        case .fiveSeconds: return "5 seconds"
        }
    }
}

/// Non-tool app settings: rich content, voice input (STT), and streaming.
/// Tool enable/disable state is managed by ToolManager.
public class ToolSettings: ObservableObject {
    public static let shared = ToolSettings()

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

    /// Selected language for STT
    @Published public var sttLanguage: STTLanguage {
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

    /// Duration of silence before auto-stopping recording
    @Published public var silenceTimeout: SilenceTimeout {
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

    /// Chunk interval for OpenAI simulated streaming
    @Published public var streamingChunkInterval: StreamingChunkInterval {
        didSet { saveSettings() }
    }

    private init() {
        self.richContentEnabled = UserDefaults.standard.object(forKey: "richContentEnabled") as? Bool ?? true
        self.voiceInputEnabled = UserDefaults.standard.object(forKey: "voiceInputEnabled") as? Bool ?? true

        if let rawValue = UserDefaults.standard.string(forKey: "sttProviderRawValue"),
           let provider = STTProvider(rawValue: rawValue) {
            self.sttProvider = provider
        } else {
            self.sttProvider = .appleSpeech
        }

        self.voiceButtonReplaceSend = UserDefaults.standard.object(forKey: "voiceButtonReplaceSend") as? Bool ?? false

        if let rawValue = UserDefaults.standard.string(forKey: "sttLanguage"),
           let language = STTLanguage(rawValue: rawValue) {
            self.sttLanguage = language
        } else {
            self.sttLanguage = .auto
        }

        if let rawValue = UserDefaults.standard.string(forKey: "whisperKitModelSize"),
           let modelSize = WhisperKitModelSize(rawValue: rawValue) {
            self.whisperKitModelSize = modelSize
        } else {
            self.whisperKitModelSize = .base
        }

        self.autoStopOnSilence = UserDefaults.standard.object(forKey: "autoStopOnSilence") as? Bool ?? true

        if let rawValue = UserDefaults.standard.object(forKey: "silenceTimeoutSeconds") as? Double,
           let timeout = SilenceTimeout(rawValue: rawValue) {
            self.silenceTimeout = timeout
        } else {
            self.silenceTimeout = .twoSeconds
        }

        self.streamingTranscriptionEnabled = UserDefaults.standard.object(forKey: "streamingTranscriptionEnabled") as? Bool ?? true
        self.enableOpenAISimulatedStreaming = UserDefaults.standard.object(forKey: "enableOpenAISimulatedStreaming") as? Bool ?? true

        if let rawValue = UserDefaults.standard.object(forKey: "streamingChunkIntervalSeconds") as? Double,
           let interval = StreamingChunkInterval(rawValue: rawValue) {
            self.streamingChunkInterval = interval
        } else {
            self.streamingChunkInterval = .threeSeconds
        }
    }

    func saveSettings() {
        UserDefaults.standard.set(richContentEnabled, forKey: "richContentEnabled")
        UserDefaults.standard.set(voiceInputEnabled, forKey: "voiceInputEnabled")
        UserDefaults.standard.set(sttProvider.rawValue, forKey: "sttProviderRawValue")
        UserDefaults.standard.set(voiceButtonReplaceSend, forKey: "voiceButtonReplaceSend")
        UserDefaults.standard.set(sttLanguage.rawValue, forKey: "sttLanguage")
        UserDefaults.standard.set(whisperKitModelSize.rawValue, forKey: "whisperKitModelSize")
        UserDefaults.standard.set(autoStopOnSilence, forKey: "autoStopOnSilence")
        UserDefaults.standard.set(silenceTimeout.rawValue, forKey: "silenceTimeoutSeconds")
        UserDefaults.standard.set(streamingTranscriptionEnabled, forKey: "streamingTranscriptionEnabled")
        UserDefaults.standard.set(enableOpenAISimulatedStreaming, forKey: "enableOpenAISimulatedStreaming")
        UserDefaults.standard.set(streamingChunkInterval.rawValue, forKey: "streamingChunkIntervalSeconds")
    }

    func resetToDefaults() {
        richContentEnabled = true
        voiceInputEnabled = true
        sttProvider = .appleSpeech
        voiceButtonReplaceSend = false
        sttLanguage = .auto
        whisperKitModelSize = .base
        autoStopOnSilence = true
        silenceTimeout = .twoSeconds
        streamingTranscriptionEnabled = true
        enableOpenAISimulatedStreaming = true
        streamingChunkInterval = .threeSeconds
        saveSettings()
    }
}

// Extension to UserDefaults for convenient access
extension UserDefaults {
    static var toolSettings: ToolSettings {
        get { ToolSettings.shared }
    }
}
