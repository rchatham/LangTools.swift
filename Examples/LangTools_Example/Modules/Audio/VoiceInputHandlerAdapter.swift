//
//  VoiceInputHandlerAdapter.swift
//  App
//
//  Adapter to bridge STTService to ChatUI's VoiceInputHandler protocol
//

import Foundation
import SwiftUI
import Combine
import ChatUI
import OpenAI

/// Adapter to bridge STTService to ChatUI's VoiceInputHandler protocol
@MainActor
public class VoiceInputHandlerAdapter: ObservableObject, VoiceInputHandler {
    private let sttService: STTService
    private let settings: any VoiceInputSettingsProviding
    private var cancellables = Set<AnyCancellable>()

    /// Unified audio level monitor for UI visualization (separate from transcription)
    private let audioLevelMonitor = AudioLevelMonitor()

    /// Partial transcription text for streaming display
    @Published public private(set) var partialText: String = ""

    /// Pending transcribed text that survives view recreation
    @Published public var pendingTranscribedText: String?

    /// WhisperKit loading state for UI feedback
    @Published public private(set) var whisperKitLoadingState: WhisperKitLoadingState = .idle

    public convenience init(settings: any VoiceInputSettingsProviding) {
        self.init(sttService: .shared, settings: settings)
    }

    public init(sttService: STTService, settings: any VoiceInputSettingsProviding) {
        self.sttService = sttService
        self.settings = settings

        sttService.configure(
            STTServiceConfiguration(
                languageIdentifierProvider: { [weak settings] in settings?.sttLanguageIdentifier },
                isOpenAISimulatedStreamingEnabled: { [weak settings] in settings?.enableOpenAISimulatedStreaming ?? false },
                openAIStreamingChunkInterval: { [weak settings] in settings?.openAIStreamingChunkInterval ?? 3.0 }
            )
        )

        // Setup providers
        setupProviders()

        // Request permissions on initialization
        Task {
            do {
                let granted = try await sttService.requestPermissions()
                if !granted {
                    print("[VoiceInputHandlerAdapter] Speech recognition permissions not granted")
                }
            } catch {
                print("[VoiceInputHandlerAdapter] Failed to request permissions: \(error)")
            }
        }

        // Forward settings changes to trigger view updates and provider switching
        settings.settingsDidChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateProviderFromSettings()
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        // Observe partial transcription updates from STTService
        sttService.$partialTranscription
            .receive(on: RunLoop.main)
            .sink { [weak self] text in
                self?.partialText = text
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        // Forward audio level changes from monitor to trigger view updates
        audioLevelMonitor.$audioLevel
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    // MARK: - Provider Setup

    /// Register all available STT providers
    private func setupProviders() {
        print("[VoiceInputHandlerAdapter] Setting up STT providers...")

        // Register Apple Speech (always available)
        let appleSpeechProvider = AppleSpeechSTTProvider(
            languageIdentifierProvider: { [weak settings] in settings?.sttLanguageIdentifier }
        )
        sttService.registerProvider(appleSpeechProvider, for: .appleSpeech)
        print("[VoiceInputHandlerAdapter] Registered Apple Speech provider")

        // Register OpenAI Whisper
        let openAIProvider = OpenAISTTProvider(
            apiKeyProvider: { [weak settings] in settings?.openAIApiKey },
            languageIdentifierProvider: { [weak settings] in settings?.sttLanguageIdentifier },
            audioInputNormalizer: { audioData in
                (try AudioConverter.convertToWAV(cafData: audioData), OpenAI.AudioTranscriptionRequest.FileType.wav)
            }
        )
        sttService.registerProvider(openAIProvider, for: .openAIWhisper)
        print("[VoiceInputHandlerAdapter] Registered OpenAI Whisper provider")

        // Register WhisperKit (on-device ML)
        if #available(macOS 13, iOS 16, *) {
            let whisperKitProvider = WhisperKitSTTProvider(
                modelVariantProvider: { [weak settings] in settings?.whisperKitModelVariant ?? "base" },
                languageIdentifierProvider: { [weak settings] in settings?.sttLanguageIdentifier }
            )
            sttService.registerProvider(whisperKitProvider, for: .whisperKit)
            print("[VoiceInputHandlerAdapter] Registered WhisperKit provider")

            // Observe WhisperKit loading state
            whisperKitProvider.$loadingState
                .receive(on: RunLoop.main)
                .sink { [weak self] state in
                    self?.whisperKitLoadingState = state
                    self?.objectWillChange.send()
                }
                .store(in: &cancellables)
        }

        // Set the current provider from settings
        updateProviderFromSettings()
    }

    /// Update the current provider based on settings
    private func updateProviderFromSettings() {
        let providerType: STTProviderType
        providerType = settings.sttProviderType

        sttService.setProvider(providerType)
        print("[VoiceInputHandlerAdapter] Set STT provider to: \(providerType.rawValue)")

        // If WhisperKit is selected, preload the model
        if providerType == .whisperKit, #available(macOS 13, iOS 16, *) {
            if let whisperKitProvider = sttService.currentProvider as? WhisperKitSTTProvider {
                whisperKitProvider.preload()
            }
        }
    }

    // MARK: - WhisperKit Support

    /// Preload WhisperKit model (for settings UI)
    public func preloadWhisperKit() {
        sttService.preloadWhisperKit()
    }

    // MARK: - VoiceInputHandler Protocol

    public var isRecording: Bool {
        sttService.isRecording
    }

    public var isProcessing: Bool {
        sttService.isProcessing
    }

    public var audioLevel: Float {
        audioLevelMonitor.audioLevel
    }

    public var statusDescription: String {
        sttService.status.description
    }

    public var isEnabled: Bool {
        settings.voiceInputEnabled
    }

    public var replaceSendButton: Bool {
        settings.voiceButtonReplaceSend
    }

    public func toggleRecording() async {
        if sttService.isRecording {
            // Stop recording and transcribe
            if let transcription = await sttService.stopRecording() {
                print("[VoiceInputHandlerAdapter] Transcription complete: '\(transcription)'")
                // Store result for UI consumption (bypasses SwiftUI observation issues with protocol existentials)
                self.pendingTranscribedText = transcription
            }
            // Stop audio level monitoring after transcription completes
            audioLevelMonitor.stop()
        } else {
            // Start audio level monitoring before recording begins
            audioLevelMonitor.start()
            // Start recording
            await sttService.startRecording()
        }
    }

    public func cancelRecording() {
        // Stop audio level monitoring immediately
        audioLevelMonitor.stop()

        // For the simplified service, we don't have a separate cancel method
        // Just clear the state
        Task {
            if sttService.isRecording {
                _ = await sttService.stopRecording()
            }
        }
    }

    public func getTranscribedText() -> String? {
        let text = sttService.transcribedText
        print("[VoiceInputHandlerAdapter] getTranscribedText: '\(text)'")
        return text.isEmpty ? nil : text
    }
}
