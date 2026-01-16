//
//  RealtimePipelineManager.swift
//  RealtimeTools
//
//  Created by Reid Chatham on 1/16/26.
//

import Foundation
import LangTools

// MARK: - Realtime Pipeline Manager

/// Manages a configurable realtime audio pipeline with TTS/STT/LLM providers
public final class RealtimePipelineManager: RealtimePipeline, @unchecked Sendable {
    // MARK: - Properties

    public private(set) var state: RealtimePipelineState = .idle
    public let configuration: RealtimePipelineConfiguration
    public var eventHandler: RealtimeEventHandler?

    private var sttProviderInstance: (any STTProvider)?
    private var ttsProviderInstance: (any TTSProvider)?
    private var vadInstance: (any VoiceActivityDetector)?

    private var processingTask: Task<Void, Never>?
    private var isProcessing: Bool = false

    // Interruption handling
    public var interruptionConfig: InterruptionConfiguration

    // MARK: - Initialization

    public init(
        configuration: RealtimePipelineConfiguration,
        interruptionConfig: InterruptionConfiguration = InterruptionConfiguration()
    ) {
        self.configuration = configuration
        self.interruptionConfig = interruptionConfig
    }

    // MARK: - Lifecycle

    public func start() async throws {
        guard state == .idle || state == .stopped else { return }

        state = .starting
        eventHandler?.onStateChanged?(state)

        // Initialize providers based on configuration
        try await initializeProviders()

        state = .running
        eventHandler?.onStateChanged?(state)
    }

    public func stop() async {
        guard state == .running || state == .processing else { return }

        state = .stopping
        eventHandler?.onStateChanged?(state)

        processingTask?.cancel()

        // Stop STT if running
        try? await sttProviderInstance?.stopTranscription()

        // Cancel TTS if synthesizing
        try? await ttsProviderInstance?.cancel()

        state = .stopped
        eventHandler?.onStateChanged?(state)
    }

    // MARK: - Audio Input

    public func sendAudio(_ data: Data) async throws {
        guard state == .running || state == .processing else {
            throw RealtimePipelineError.notRunning
        }

        // Process through VAD if enabled
        if let vad = vadInstance {
            let result = await vad.process(audio: data)

            if result.isSpeech && !isProcessing {
                eventHandler?.onSpeechStarted?()
                isProcessing = true
                state = .processing
                eventHandler?.onStateChanged?(state)
            } else if !result.isSpeech && isProcessing {
                eventHandler?.onSpeechStopped?()
            }
        }

        // Forward to STT provider
        try await sttProviderInstance?.transcribe(audio: data)
    }

    // MARK: - Text Input

    public func sendText(_ text: String) async throws {
        guard state == .running || state == .processing else {
            throw RealtimePipelineError.notRunning
        }

        switch configuration.mode {
        case .speechOnly:
            // Direct to TTS
            try await synthesizeAndStream(text)

        case .modular:
            // Process through LLM first, then TTS
            // For now, just send to TTS directly
            // In a full implementation, this would go through the LLM
            try await synthesizeAndStream(text)

        default:
            throw RealtimePipelineError.invalidModeForOperation
        }
    }

    // MARK: - Interruption

    public func interrupt() async throws {
        guard interruptionConfig.enabled else { return }
        guard state == .processing else { return }

        state = .interrupted
        eventHandler?.onStateChanged?(state)
        eventHandler?.onInterruption?()

        // Cancel TTS
        try? await ttsProviderInstance?.cancel()

        // Reset state
        state = .running
        eventHandler?.onStateChanged?(state)
        isProcessing = false
    }

    // MARK: - Private Methods

    private func initializeProviders() async throws {
        // Initialize VAD if configured
        if let vadConfig = configuration.audioSettings.vadConfig {
            // VAD implementation would be injected here
            // vadInstance = createVADInstance(config: vadConfig)
        }

        // Note: Actual provider instances would be injected or created
        // based on the configuration. This is a simplified implementation.
    }

    private func synthesizeAndStream(_ text: String) async throws {
        guard let tts = ttsProviderInstance else {
            throw RealtimePipelineError.providerNotConfigured("TTS")
        }

        eventHandler?.onResponseStarted?()

        try await tts.synthesize(text: text)

        for try await audioData in tts.audioStream {
            eventHandler?.onAudioReceived?(audioData)
        }

        eventHandler?.onResponseCompleted?()
    }
}

// MARK: - Pipeline Errors

public enum RealtimePipelineError: Error, LocalizedError {
    case notRunning
    case alreadyRunning
    case providerNotConfigured(String)
    case invalidModeForOperation
    case initializationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notRunning:
            return "Pipeline is not running"
        case .alreadyRunning:
            return "Pipeline is already running"
        case .providerNotConfigured(let provider):
            return "\(provider) provider is not configured"
        case .invalidModeForOperation:
            return "Operation not supported in current pipeline mode"
        case .initializationFailed(let reason):
            return "Failed to initialize pipeline: \(reason)"
        }
    }
}

// MARK: - Pipeline Builder

/// Builder for creating configured pipeline instances
public final class RealtimePipelineBuilder: @unchecked Sendable {
    private var sttConfig: STTProviderConfiguration?
    private var ttsConfig: TTSProviderConfiguration?
    private var llmConfig: LLMProviderConfiguration?
    private var audioSettings: AudioProcessingSettings = .default
    private var mode: RealtimePipelineConfiguration.PipelineMode = .speechToSpeech
    private var interruptionConfig: InterruptionConfiguration = InterruptionConfiguration()

    public init() {}

    @discardableResult
    public func withSTT(_ config: STTProviderConfiguration) -> Self {
        self.sttConfig = config
        return self
    }

    @discardableResult
    public func withTTS(_ config: TTSProviderConfiguration) -> Self {
        self.ttsConfig = config
        return self
    }

    @discardableResult
    public func withLLM(_ config: LLMProviderConfiguration) -> Self {
        self.llmConfig = config
        return self
    }

    @discardableResult
    public func withAudioSettings(_ settings: AudioProcessingSettings) -> Self {
        self.audioSettings = settings
        return self
    }

    @discardableResult
    public func withMode(_ mode: RealtimePipelineConfiguration.PipelineMode) -> Self {
        self.mode = mode
        return self
    }

    @discardableResult
    public func withInterruption(_ config: InterruptionConfiguration) -> Self {
        self.interruptionConfig = config
        return self
    }

    public func build() -> RealtimePipelineManager {
        let config = RealtimePipelineConfiguration(
            sttProvider: sttConfig,
            ttsProvider: ttsConfig,
            llmProvider: llmConfig,
            mode: mode,
            audioSettings: audioSettings
        )

        return RealtimePipelineManager(
            configuration: config,
            interruptionConfig: interruptionConfig
        )
    }
}

// MARK: - Preset Configurations

extension RealtimePipelineBuilder {
    /// Configure for OpenAI Realtime (native speech-to-speech)
    public static func openAIRealtime() -> RealtimePipelineBuilder {
        RealtimePipelineBuilder()
            .withMode(.speechToSpeech)
            .withAudioSettings(.openAIRealtime)
            .withInterruption(InterruptionConfiguration(enabled: true, mode: .immediate))
    }

    /// Configure for modular pipeline with ElevenLabs TTS
    public static func modularWithElevenLabs(voice: String, llmModel: String = "gpt-4o") -> RealtimePipelineBuilder {
        RealtimePipelineBuilder()
            .withMode(.modular)
            .withSTT(STTProviderConfiguration(provider: .appleOnDevice))
            .withTTS(TTSProviderConfiguration(provider: .elevenLabs, voice: voice))
            .withLLM(LLMProviderConfiguration(provider: .openAI, model: llmModel))
            .withAudioSettings(.elevenLabs)
    }

    /// Configure for transcription only
    public static func transcriptionOnly(provider: STTProviderConfiguration.STTProvider = .appleOnDevice) -> RealtimePipelineBuilder {
        RealtimePipelineBuilder()
            .withMode(.transcriptionOnly)
            .withSTT(STTProviderConfiguration(provider: provider))
    }
}
