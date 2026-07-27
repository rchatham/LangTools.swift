//
//  InterruptionDetector.swift
//  RealtimeTools
//
//  Created by Reid Chatham on 1/16/26.
//

import Foundation
import LangTools

// MARK: - Interruption Events

/// Events emitted by the interruption detector
public enum InterruptionEvent: Sendable {
    /// User speech has started (after passing the debounce threshold)
    case speechStarted(timestamp: TimeInterval)

    /// User speech has ended (after the configured silence timeout)
    case speechEnded(timestamp: TimeInterval, duration: TimeInterval)

    /// User spoke while assistant playback was active — a barge-in
    case interruptionDetected(timestamp: TimeInterval)
}

// MARK: - Interruption Detector

/// Turn-taking and barge-in state machine built on top of any `VoiceActivityDetector`.
///
/// Feed it microphone audio frames (10-30ms of PCM16 recommended) and tell it
/// when assistant playback starts and stops. It applies the debounce and
/// duration thresholds from `InterruptionConfiguration` so that short noises,
/// coughs, or echo residue don't cancel a response, and emits
/// `interruptionDetected` only for genuine barge-ins.
///
/// ```
///            audio frames                 playback state
///                 │                             │
///                 ▼                             ▼
///        ┌────────────────┐          ┌────────────────────┐
///        │      VAD       │────────▶│ InterruptionDetector│──▶ events
///        └────────────────┘          └────────────────────┘
/// ```
public final class InterruptionDetector: @unchecked Sendable {
    // MARK: - State

    private enum SpeechState {
        case silence
        /// Speech frames observed, but not yet past the debounce/min-duration gate
        case candidateSpeech(since: TimeInterval)
        case speaking(since: TimeInterval)
        /// Speaking, but silence frames observed; waiting out the silence timeout
        case trailingSilence(speechSince: TimeInterval, silenceSince: TimeInterval)
    }

    private let lock = NSLock()
    private var state: SpeechState = .silence

    // Playback tracking for barge-in decisions
    private var playbackActive = false
    private var playbackStartedAt: TimeInterval?
    private var interruptionFiredForCurrentUtterance = false

    // MARK: - Configuration

    public let vad: any VoiceActivityDetector
    public var configuration: InterruptionConfiguration

    /// Handler for interruption events
    public var onEvent: (@Sendable (InterruptionEvent) -> Void)?

    // MARK: - Initialization

    public init(
        vad: any VoiceActivityDetector,
        configuration: InterruptionConfiguration = InterruptionConfiguration(),
        onEvent: (@Sendable (InterruptionEvent) -> Void)? = nil
    ) {
        self.vad = vad
        self.configuration = configuration
        self.onEvent = onEvent
    }

    // MARK: - Playback State

    /// Tell the detector that assistant audio playback started.
    /// While playback is active, detected speech is treated as a barge-in.
    public func playbackStarted(at timestamp: TimeInterval? = nil) {
        lock.lock()
        defer { lock.unlock() }
        playbackActive = true
        playbackStartedAt = timestamp
        interruptionFiredForCurrentUtterance = false
    }

    /// Tell the detector that assistant audio playback stopped or completed.
    public func playbackStopped() {
        lock.lock()
        defer { lock.unlock() }
        playbackActive = false
        playbackStartedAt = nil
    }

    /// Whether assistant playback is currently considered active
    public var isPlaybackActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return playbackActive
    }

    // MARK: - Audio Processing

    /// Process a frame of microphone audio. Runs the VAD and advances the
    /// turn-taking state machine, emitting events through `onEvent`.
    /// - Returns: The underlying VAD result for callers that want raw frame data.
    @discardableResult
    public func process(audio: Data) async -> VADResult {
        let result = await vad.process(audio: audio)
        handle(result: result)
        return result
    }

    /// Advance the state machine with an externally computed VAD result.
    /// Use this when the VAD runs elsewhere (e.g. server-side VAD events).
    public func handle(result: VADResult) {
        lock.lock()

        var events: [InterruptionEvent] = []
        let now = result.timestamp

        switch (state, result.isSpeech) {
        case (.silence, true):
            state = .candidateSpeech(since: now)

        case (.candidateSpeech(let since), true):
            // Require both the debounce window and the minimum speech duration
            // before committing to a speech turn.
            let required = max(configuration.speechDetectionDebounce, vad.configuration.minSpeechDuration)
            if now - since >= required {
                state = .speaking(since: since)
                events.append(.speechStarted(timestamp: since))
                if let interruption = interruptionEventIfNeeded(at: now) {
                    events.append(interruption)
                }
            }

        case (.candidateSpeech, false):
            // Noise blip shorter than the debounce window — discard
            state = .silence

        case (.speaking(let since), false):
            state = .trailingSilence(speechSince: since, silenceSince: now)

        case (.trailingSilence(let speechSince, _), true):
            // Speech resumed within the silence timeout — same utterance
            state = .speaking(since: speechSince)

        case (.trailingSilence(let speechSince, let silenceSince), false):
            if now - silenceSince >= vad.configuration.silenceTimeout {
                state = .silence
                interruptionFiredForCurrentUtterance = false
                events.append(.speechEnded(timestamp: now, duration: silenceSince - speechSince))
            }

        case (.speaking, true), (.silence, false):
            break
        }

        let handler = onEvent
        lock.unlock()

        for event in events {
            handler?(event)
        }
    }

    /// Reset the detector and underlying VAD state.
    public func reset() async {
        lock.lock()
        state = .silence
        playbackActive = false
        playbackStartedAt = nil
        interruptionFiredForCurrentUtterance = false
        lock.unlock()
        await vad.reset()
    }

    // MARK: - Private

    /// Must be called with the lock held.
    private func interruptionEventIfNeeded(at timestamp: TimeInterval) -> InterruptionEvent? {
        guard configuration.enabled, playbackActive, !interruptionFiredForCurrentUtterance else { return nil }

        // Respect the minimum playback grace period so the very start of a
        // response can't be cancelled by echo or the tail of the user's turn.
        if let startedAt = playbackStartedAt, timestamp - startedAt < configuration.minPlaybackBeforeInterrupt {
            return nil
        }

        interruptionFiredForCurrentUtterance = true
        return .interruptionDetected(timestamp: timestamp)
    }
}
