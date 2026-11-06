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

    /// Pipeline event callbacks. They run on whatever thread produced the
    /// event — the caller of `sendAudio`/`sendText`, or the task consuming
    /// the STT stream — not on the main thread. Hop to the main actor
    /// yourself before touching UI. The same applies to
    /// `onPipelineStateChanged`.
    ///
    /// Assign `eventHandler`, `onPipelineStateChanged` and `textProcessor`
    /// before `start()`. They're read from those background tasks without a
    /// lock, so reassigning them while the pipeline runs is a data race.
    public var eventHandler: RealtimeEventHandler?

    // Mutable state is written from caller methods, the interruption
    // detector's callback, and background tasks — guarded by `lock`.
    private let lock = NSLock()
    private var _state: RealtimePipelineState = .idle
    private var _interruptGeneration = 0
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

    deinit {
        // Can't await stop() here; cancelling the STT consumer at least ends
        // its session stream. Call stop() before releasing a running pipeline
        // to also stop the STT and TTS providers.
        processingTask?.cancel()
    }

    // MARK: - Lifecycle

    public func start() async throws {
        // Check-and-set atomically so two concurrent start() calls can't
        // both initialize providers.
        guard transition(from: .idle, to: .starting) || transition(from: .stopped, to: .starting) else { return }

        // Initialize providers based on configuration
        do {
            try await initializeProviders()
        } catch {
            // Release whatever was set up before the failure (detector, VAD
            // state, a started STT session), then return to .idle so start()
            // can be retried, unless a stop() already moved the state on.
            await releaseProviders()
            _ = transition(from: .starting, to: .idle)
            throw error
        }

        // A stop() can arrive while providers initialize. Only go to .running
        // if nothing moved the state on; otherwise release what
        // initializeProviders() just started.
        if !transition(from: .starting, to: .running) {
            await releaseProviders()
        }
    }

    public func stop() async {
        // .interrupted is a live state: interrupt() sits in it while TTS
        // cancels, and a stop() issued then must not be lost. interrupt()
        // only returns to .running if nothing moved the state on meanwhile.
        // .starting too: start() checks for a stop when its setup finishes.
        // Check-and-set in one step so concurrent stop() calls don't both
        // run, and nothing moves the state between the check and the set.
        guard transition(fromAnyOf: [.running, .processing, .interrupted, .starting], to: .stopping) else { return }
        await releaseProviders()
        setState(.stopped)
    }

    /// Stops what start() set up. Safe to run twice: stop() and a start()
    /// that a stop() overtook can both call it.
    private func releaseProviders() async {
        lock.lock()
        let task = processingTask
        processingTask = nil
        // start() builds a fresh detector; reset the reused VAD too, so a
        // restart doesn't inherit the previous session's timestamps and
        // adapted noise floor.
        interruptionDetector = nil
        let vad = vadInstance
        lock.unlock()
        task?.cancel()
        await vad?.reset()

        // Stop STT if running
        try? await currentSTT?.stopTranscription()

        // Cancel TTS if synthesizing
        try? await currentTTS?.cancel()

        // Don't let a restart begin mid-utterance as far as the VAD path knows.
        isProcessing = false
    }

    private func setState(_ newState: RealtimePipelineState) {
        lock.lock()
        _state = newState
        lock.unlock()
        onPipelineStateChanged?(newState)
    }

    // Locked reads of the provider instances, which setProviders() writes
    // under the same lock.
    private var currentSTT: (any STTProvider)? {
        lock.lock(); defer { lock.unlock() }
        return sttProviderInstance
    }

    private var currentTTS: (any TTSProvider)? {
        lock.lock(); defer { lock.unlock() }
        return ttsProviderInstance
    }

    private var currentDetector: InterruptionDetector? {
        lock.lock(); defer { lock.unlock() }
        return interruptionDetector
    }

    /// Moves to `newState` only if the current state is `expected`, as one
    /// locked step. Returns whether the transition happened.
    private func transition(fromAnyOf expected: Set<RealtimePipelineState>, to newState: RealtimePipelineState) -> Bool {
        lock.lock()
        guard expected.contains(_state) else {
            lock.unlock()
            return false
        }
        _state = newState
        lock.unlock()
        onPipelineStateChanged?(newState)
        return true
    }

    private func transition(from expected: RealtimePipelineState, to newState: RealtimePipelineState) -> Bool {
        lock.lock()
        guard _state == expected else {
            lock.unlock()
            return false
        }
        _state = newState
        lock.unlock()
        onPipelineStateChanged?(newState)
        return true
    }

    // MARK: - Audio Input

    public func sendAudio(_ data: Data) async throws {
        let current = state
        // Accept audio during a barge-in (.interrupted): it's the user's
        // speech that caused the interruption.
        guard current == .running || current == .processing || current == .interrupted else {
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

        // .manual is push-to-talk and .server leaves turn detection to the
        // provider: in both, an injected VAD must not drive turn state.
        let vadMode = configuration.audioSettings.vadConfig?.mode
        let localTurnDetection = vadMode != .manual && vadMode != .server

        if let detector {
            await detector.process(audio: data)
        } else if localTurnDetection, let vad {
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
        try await currentSTT?.transcribe(audio: data)
    }

    // MARK: - Text Input

    public func sendText(_ text: String) async throws {
        let current = state
        guard current == .running || current == .processing || current == .interrupted else {
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

    /// Stops the current reply. Works while the user is speaking
    /// (`.processing`, a barge-in) and while the pipeline is `.running`, which
    /// is its state while a reply plays, so an "interrupt" button can stop
    /// the assistant mid-sentence.
    public func interrupt() async throws {
        guard interruptionConfig.enabled else { return }
        // Check-and-set atomically: the interruption detector can move state
        // from another thread (e.g. .speechEnded → .running) between a
        // separate read and write.
        guard transition(from: .processing, to: .interrupted)
                || transition(from: .running, to: .interrupted) else { return }
        await finishInterrupt()
    }

    /// The work after the `.processing → .interrupted` transition has been
    /// claimed. Split out so the detector can claim the transition
    /// synchronously, before a following `.speechEnded` could move state on
    /// and make the barge-in's TTS cancel be skipped.
    private func finishInterrupt() async {
        // Mark replies in flight as interrupted before cancelling, so the
        // stream error the cancel causes isn't reported through onError.
        bumpInterruptGeneration()
        eventHandler?.onInterruption?()

        // Cancel TTS and mark playback stopped so the detector re-arms cleanly
        try? await currentTTS?.cancel()
        currentDetector?.playbackStopped()

        // Reset state, unless something else (stop(), new speech) moved it on;
        // in that case leave isProcessing to whatever moved it.
        if transition(from: .interrupted, to: .running) {
            isProcessing = false
        }
    }

    // MARK: - Private Methods

    private func initializeProviders() async throws {
        // Initialize on-device VAD + interruption detection if configured.
        // Server VAD modes (e.g. OpenAI Realtime) handle this remotely, so we
        // only build the local detector for onDevice and automatic modes.
        // .manual is push-to-talk: the caller decides turns, so no automatic
        // turn-taking or barge-in either.
        if let vadConfig = configuration.audioSettings.vadConfig, vadConfig.mode != .server, vadConfig.mode != .manual {
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
                    // Don't clobber .interrupted: a barge-in in progress
                    // resets state itself when its cancel completes.
                    if self.transition(from: .processing, to: .running) {
                        self.isProcessing = false
                    }
                case .interruptionDetected:
                    guard self.interruptionConfig.enabled,
                          self.transition(from: .processing, to: .interrupted) else { return }
                    Task { [weak self] in await self?.finishInterrupt() }
                }
            }
            lock.lock()
            interruptionDetector = detector
            lock.unlock()
        }

        // Start an STT session and consume it: surface every result via
        // onTranscriptReceived, and in .modular mode drive the LLM/TTS steps
        // once a final transcription arrives. Stored in `processingTask` so
        // `stop()` cancels it alongside the rest of the pipeline; each
        // start() gets a fresh session stream. Requires setProviders(stt:)
        // to have been called before start() — an STT provider attached
        // afterward won't be picked up until the next start() (matching the
        // existing vadInstance/interruptionDetector setup-time-only pattern
        // above).
        lock.lock()
        let stt = sttProviderInstance
        lock.unlock()

        if let stt {
            let transcriptions = try await stt.startTranscription()
            let mode = configuration.mode
            let task = Task { [weak self] in
                guard let self else { return }
                do {
                    for try await result in transcriptions {
                        guard !Task.isCancelled else { return }
                        self.eventHandler?.onTranscriptReceived?(result.text, result.isFinal)
                        if mode == .modular, result.isFinal, !result.text.isEmpty {
                            // No caller here to throw to, so report LLM/TTS
                            // failures through onError rather than dropping them.
                            do {
                                try await self.sendText(result.text)
                            } catch {
                                // stop() cancels this task; the resulting
                                // cancellation isn't a failure to report.
                                guard !Task.isCancelled, !(error is CancellationError) else { return }
                                self.eventHandler?.onError?(error)
                            }
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
    /// barge-in detection for subsequent user speech. Call this from your
    /// audio player: the pipeline only hands audio to `onAudioReceived` and
    /// can't tell when it's actually heard, so barge-in never fires unless
    /// the player reports playback here and through `notifyPlaybackStopped()`.
    public func notifyPlaybackStarted(at timestamp: TimeInterval? = nil) {
        currentDetector?.playbackStarted(at: timestamp)
    }

    /// Notify the pipeline that assistant audio playback finished or was stopped.
    public func notifyPlaybackStopped() {
        currentDetector?.playbackStopped()
    }

    private func synthesizeAndStream(_ text: String) async throws {
        guard let tts = currentTTS else {
            throw RealtimePipelineError.providerNotConfigured("TTS")
        }

        let generation = interruptGeneration
        eventHandler?.onResponseStarted?()

        do {
            for try await audioData in try await tts.synthesize(text: text) {
                // interrupt() cut this reply: drop audio the provider still
                // delivers rather than playing it after the barge-in.
                guard interruptGeneration == generation else { break }
                eventHandler?.onAudioReceived?(audioData)
            }
        } catch {
            // A reply cut off by interrupt() ends with whatever error the
            // provider's cancel produces; that's expected, not a failure.
            if interruptGeneration != generation { return }
            throw error
        }

        // A provider's cancel may finish the stream instead of failing it.
        // Either way an interrupted reply ends with onInterruption, not
        // onResponseCompleted.
        guard interruptGeneration == generation else { return }
        eventHandler?.onResponseCompleted?()
    }

    private var interruptGeneration: Int {
        lock.lock(); defer { lock.unlock() }
        return _interruptGeneration
    }

    private func bumpInterruptGeneration() {
        lock.lock(); _interruptGeneration += 1; lock.unlock()
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
public final class RealtimePipelineBuilder {
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
