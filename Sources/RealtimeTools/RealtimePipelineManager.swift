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

    public let configuration: RealtimePipelineConfiguration
    public var eventHandler: RealtimeEventHandler?

    // Mutable state is written from caller methods, the interruption
    // detector's callback, and background tasks — guarded by `lock`.
    private let lock = NSLock()
    private var _state: RealtimePipelineState = .idle
    private var _isProcessing: Bool = false
    private var sttProviderInstance: (any STTProvider)?
    private var ttsProviderInstance: (any TTSProvider)?
    private var vadInstance: (any VoiceActivityDetector)?
    private var interruptionDetector: InterruptionDetector?
    private var processingTask: Task<Void, Never>?

    public var state: RealtimePipelineState {
        lock.lock(); defer { lock.unlock() }
        return _state
    }

    private var isProcessing: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _isProcessing }
        set { lock.lock(); _isProcessing = newValue; lock.unlock() }
    }

    /// The LLM step for `.modular` mode: receives the user's text (or final
    /// transcription) and returns the response text to synthesize. Wire this
    /// to any LangTools provider, e.g.:
    /// ```swift
    /// pipeline.textProcessor = { text in
    ///     let request = try openAI.chatRequest(model: OpenAIModel.gpt4o, messages: [...])
    ///     return try await openAI.perform(request: request).message?.content.text ?? ""
    /// }
    /// ```
    public var textProcessor: (@Sendable (String) async throws -> String)?

    /// Called whenever the pipeline's own state changes. `RealtimeEventHandler
    /// .onStateChanged` is typed for `RealtimeSessionState` (the WebSocket
    /// session enum from the `LangTools` module) and can't carry
    /// `RealtimePipelineState` (defined in this module, one layer up) without
    /// a circular module dependency — this is the pipeline-specific
    /// equivalent.
    public var onPipelineStateChanged: (@Sendable (RealtimePipelineState) -> Void)?

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
        let current = state
        guard current == .idle || current == .stopped else { return }

        setState(.starting)

        // Initialize providers based on configuration
        try await initializeProviders()

        setState(.running)
    }

    public func stop() async {
        let current = state
        guard current == .running || current == .processing else { return }

        setState(.stopping)

        lock.lock()
        let task = processingTask
        processingTask = nil
        lock.unlock()
        task?.cancel()

        // Stop STT if running
        try? await sttProviderInstance?.stopTranscription()

        // Cancel TTS if synthesizing
        try? await ttsProviderInstance?.cancel()

        setState(.stopped)
    }

    private func setState(_ newState: RealtimePipelineState) {
        lock.lock()
        _state = newState
        lock.unlock()
        onPipelineStateChanged?(newState)
    }

    // MARK: - Audio Input

    public func sendAudio(_ data: Data) async throws {
        let current = state
        guard current == .running || current == .processing else {
            throw RealtimePipelineError.notRunning
        }

        // Native speech-to-speech (e.g. OpenAI Realtime) is not proxied by
        // this manager yet — use the provider session directly
        // (`OpenAI.createRealtimeSession`) for that mode.
        guard configuration.mode != .speechToSpeech else {
            throw RealtimePipelineError.notImplemented("speechToSpeech mode is handled natively by the provider session (e.g. OpenAI.createRealtimeSession); RealtimePipelineManager does not proxy it yet")
        }

        // Run on-device VAD and interruption detection when configured.
        // Speech start/stop and barge-in events are surfaced via the
        // interruption detector's event handler set up in initializeProviders.
        lock.lock()
        let detector = interruptionDetector
        let vad = vadInstance
        lock.unlock()

        if let detector {
            await detector.process(audio: data)
        } else if let vad {
            let result = await vad.process(audio: data)

            if result.isSpeech && !isProcessing {
                eventHandler?.onSpeechStarted?()
                isProcessing = true
                setState(.processing)
            } else if !result.isSpeech && isProcessing {
                eventHandler?.onSpeechStopped?()
                isProcessing = false
                setState(.running)
            }
        }

        // Forward to STT provider
        try await sttProviderInstance?.transcribe(audio: data)
    }

    // MARK: - Text Input

    public func sendText(_ text: String) async throws {
        let current = state
        guard current == .running || current == .processing else {
            throw RealtimePipelineError.notRunning
        }

        switch configuration.mode {
        case .speechOnly:
            // Direct to TTS
            try await synthesizeAndStream(text)

        case .modular:
            // Run the LLM step, then synthesize the response. Throw rather
            // than silently degrading to TTS-only when no LLM step is wired.
            guard let textProcessor else {
                throw RealtimePipelineError.providerNotConfigured("LLM (set `textProcessor` to wire an LLM into the modular pipeline)")
            }
            let response = try await textProcessor(text)
            eventHandler?.onTextReceived?(response)
            try await synthesizeAndStream(response)

        case .speechToSpeech:
            throw RealtimePipelineError.notImplemented("speechToSpeech mode is handled natively by the provider session (e.g. OpenAI.createRealtimeSession); RealtimePipelineManager does not proxy it yet")

        case .transcriptionOnly:
            throw RealtimePipelineError.invalidModeForOperation
        }
    }

    // MARK: - Interruption

    public func interrupt() async throws {
        guard interruptionConfig.enabled else { return }
        guard state == .processing else { return }

        setState(.interrupted)
        eventHandler?.onInterruption?()

        // Cancel TTS and mark playback stopped so the detector re-arms cleanly
        try? await ttsProviderInstance?.cancel()
        interruptionDetector?.playbackStopped()

        // Reset state
        setState(.running)
        isProcessing = false
    }

    // MARK: - Private Methods

    private func initializeProviders() async throws {
        // Initialize on-device VAD + interruption detection if configured.
        // Server VAD modes (e.g. OpenAI Realtime) handle this remotely, so we
        // only build the local detector for onDevice/automatic/manual modes.
        if let vadConfig = configuration.audioSettings.vadConfig, vadConfig.mode != .server {
            lock.lock()
            let vad = vadInstance ?? EnergyVAD(
                configuration: vadConfig,
                sampleRate: configuration.audioSettings.inputSampleRate
            )
            vadInstance = vad
            lock.unlock()

            let detector = InterruptionDetector(vad: vad, configuration: interruptionConfig)
            detector.onEvent = { [weak self] event in
                guard let self else { return }
                switch event {
                case .speechStarted:
                    self.isProcessing = true
                    self.setState(.processing)
                    self.eventHandler?.onSpeechStarted?()
                case .speechEnded:
                    self.eventHandler?.onSpeechStopped?()
                    self.isProcessing = false
                    self.setState(.running)
                case .interruptionDetected:
                    Task { try? await self.interrupt() }
                }
            }
            lock.lock()
            interruptionDetector = detector
            lock.unlock()
        }

        // Consume STT transcriptions: surface every result via
        // onTranscriptReceived, and in .modular mode drive the LLM/TTS steps
        // once a final transcription arrives. Stored in `processingTask` so
        // `stop()` cancels it alongside the rest of the pipeline. Requires
        // setProviders(stt:) to have been called before start() — an STT
        // provider attached afterward won't be picked up until the next
        // start() (matching the existing vadInstance/interruptionDetector
        // setup-time-only pattern above).
        lock.lock()
        let stt = sttProviderInstance
        lock.unlock()

        if let stt {
            let mode = configuration.mode
            let task = Task { [weak self] in
                guard let self else { return }
                do {
                    for try await result in stt.transcriptions {
                        guard !Task.isCancelled else { return }
                        self.eventHandler?.onTranscriptReceived?(result.text, result.isFinal)
                        if mode == .modular, result.isFinal, !result.text.isEmpty {
                            try? await self.sendText(result.text)
                        }
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    self.eventHandler?.onError?(error)
                }
            }
            lock.lock()
            processingTask = task
            lock.unlock()
        }
    }

    /// Inject concrete provider implementations. An externally created VAD
    /// (e.g. TEN VAD or Silero VAD wrapped in `VoiceActivityDetector`) can be
    /// supplied here before calling `start()` to replace the built-in EnergyVAD.
    public func setProviders(
        stt: (any STTProvider)? = nil,
        tts: (any TTSProvider)? = nil,
        vad: (any VoiceActivityDetector)? = nil
    ) {
        lock.lock()
        if let stt { sttProviderInstance = stt }
        if let tts { ttsProviderInstance = tts }
        if let vad { vadInstance = vad }
        lock.unlock()
    }

    /// Notify the pipeline that assistant audio playback started, enabling
    /// barge-in detection for subsequent user speech.
    public func notifyPlaybackStarted(at timestamp: TimeInterval? = nil) {
        interruptionDetector?.playbackStarted(at: timestamp)
    }

    /// Notify the pipeline that assistant audio playback finished or was stopped.
    public func notifyPlaybackStopped() {
        interruptionDetector?.playbackStopped()
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
    case notImplemented(String)

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
        case .notImplemented(let detail):
            return "Not implemented: \(detail)"
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
