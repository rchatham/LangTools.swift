//
//  STTProvider.swift
//  Audio
//
//  Protocol for speech-to-text providers
//

import Foundation
import LangTools

/// Error types for speech-to-text operations
public enum STTError: Error, LocalizedError {
    case notAvailable
    case permissionDenied
    case recordingFailed(String)
    case transcriptionFailed(String)
    case noAudioData
    case providerNotConfigured

    public var errorDescription: String? {
        switch self {
        case .notAvailable:
            return "Speech recognition is not available on this device"
        case .permissionDenied:
            return "Microphone or speech recognition permission was denied"
        case .recordingFailed(let message):
            return "Recording failed: \(message)"
        case .transcriptionFailed(let message):
            return "Transcription failed: \(message)"
        case .noAudioData:
            return "No audio data was recorded"
        case .providerNotConfigured:
            return "Speech recognition provider is not properly configured"
        }
    }
}

/// Example-app speech recognition provider that demonstrates LangTools' provider-neutral
/// live recognition contract plus the example app's file/data transcription flow.
@MainActor
public protocol SpeechRecognitionProvider: SpeechRecognitionProviding {
    /// Example UI provider bucket.
    var providerType: STTProviderType { get }

    /// Whether this provider is available on the current device/configuration.
    var isAvailable: Bool { get }

    /// Request permission for speech recognition (if needed).
    func requestPermission() async throws -> Bool

    /// Transcribe audio data to provider-neutral text.
    /// - Parameter audioData: Audio data in a supported format (typically WAV or M4A).
    /// - Returns: A LangTools transcription response. `String` responses use LangTools' built-in conformance.
    func transcribe(audioData: Data) async throws -> any LangToolsTranscriptionResponse
}

public extension SpeechRecognitionProvider {
    var name: String { displayName }

    func requestPermission() async throws -> Bool {
        await requestAuthorization() == .authorized
    }

    func prepareAssetsIfNeeded() {}

    func startDualLanguageRecognition(otherLanguageIdentifier: String) throws {
        throw STTError.notAvailable
    }
}

/// Types of STT providers available - matches ToolSettings.STTProvider
public enum STTProviderType: String, CaseIterable, Identifiable, Codable {
    case appleSpeech = "Apple Speech"
    case openAIWhisper = "OpenAI Whisper"
    case whisperKit = "WhisperKit"

    public var id: String { rawValue }

    public var description: String {
        switch self {
        case .appleSpeech:
            return "On-device, private, no API key needed"
        case .openAIWhisper:
            return "Cloud-based, high accuracy, requires API key"
        case .whisperKit:
            return "On-device ML, high accuracy, requires model download"
        }
    }

    public var iconName: String {
        switch self {
        case .appleSpeech:
            return "apple.logo"
        case .openAIWhisper:
            return "cloud"
        case .whisperKit:
            return "waveform"
        }
    }
}
