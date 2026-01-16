//
//  RealtimePipeline.swift
//  RealtimeTools
//
//  Created by Reid Chatham on 1/16/26.
//

import Foundation
import LangTools

// MARK: - Realtime Pipeline Protocol

/// Protocol for realtime audio/text pipelines
public protocol RealtimePipeline: AnyObject, Sendable {
    /// Current state of the pipeline
    var state: RealtimePipelineState { get }

    /// Configuration for the pipeline
    var configuration: RealtimePipelineConfiguration { get }

    /// Event handler for pipeline events
    var eventHandler: RealtimeEventHandler? { get set }

    /// Start the pipeline
    func start() async throws

    /// Stop the pipeline
    func stop() async

    /// Send audio data to the pipeline
    func sendAudio(_ data: Data) async throws

    /// Send text to the pipeline (for TTS or LLM)
    func sendText(_ text: String) async throws

    /// Interrupt the current response
    func interrupt() async throws
}

/// State of the realtime pipeline
public enum RealtimePipelineState: String, Sendable {
    case idle
    case starting
    case running
    case processing
    case interrupted
    case stopping
    case stopped
    case error
}

// MARK: - Pipeline Event

/// Events emitted by the realtime pipeline
public enum RealtimePipelineEvent: Sendable {
    /// Audio received from the pipeline
    case audioOutput(Data)

    /// Text transcription received
    case transcription(String, isFinal: Bool)

    /// LLM response text
    case responseText(String, isFinal: Bool)

    /// Speech started (user speaking)
    case speechStarted

    /// Speech ended (user stopped speaking)
    case speechEnded

    /// Response generation started
    case responseStarted

    /// Response generation completed
    case responseCompleted

    /// Response was interrupted
    case responseInterrupted

    /// State changed
    case stateChanged(RealtimePipelineState)

    /// Error occurred
    case error(Error)
}

// MARK: - Speech-to-Text Provider Protocol

/// Protocol for STT providers
public protocol STTProvider: AnyObject, Sendable {
    /// Start transcription
    func startTranscription() async throws

    /// Stop transcription
    func stopTranscription() async throws

    /// Send audio for transcription
    func transcribe(audio: Data) async throws

    /// Stream of transcription results
    var transcriptions: AsyncThrowingStream<TranscriptionResult, Error> { get }
}

/// Result from speech-to-text transcription
public struct TranscriptionResult: Sendable {
    public var text: String
    public var isFinal: Bool
    public var confidence: Double?
    public var words: [WordTiming]?
    public var language: String?

    public init(
        text: String,
        isFinal: Bool,
        confidence: Double? = nil,
        words: [WordTiming]? = nil,
        language: String? = nil
    ) {
        self.text = text
        self.isFinal = isFinal
        self.confidence = confidence
        self.words = words
        self.language = language
    }

    public struct WordTiming: Sendable {
        public var word: String
        public var start: TimeInterval
        public var end: TimeInterval
        public var confidence: Double?

        public init(word: String, start: TimeInterval, end: TimeInterval, confidence: Double? = nil) {
            self.word = word
            self.start = start
            self.end = end
            self.confidence = confidence
        }
    }
}

// MARK: - Text-to-Speech Provider Protocol

/// Protocol for TTS providers
public protocol TTSProvider: AnyObject, Sendable {
    /// Synthesize text to speech
    func synthesize(text: String) async throws

    /// Stream of audio data
    var audioStream: AsyncThrowingStream<Data, Error> { get }

    /// Cancel current synthesis
    func cancel() async throws

    /// Whether synthesis is in progress
    var isSynthesizing: Bool { get }
}

// MARK: - Voice Activity Detector Protocol

/// Protocol for Voice Activity Detection
public protocol VoiceActivityDetector: AnyObject, Sendable {
    /// Process audio and detect voice activity
    func process(audio: Data) async -> VADResult

    /// Reset the detector state
    func reset() async

    /// Configuration for the detector
    var configuration: VADConfiguration { get set }
}

/// Result from voice activity detection
public struct VADResult: Sendable {
    public var isSpeech: Bool
    public var probability: Double
    public var timestamp: TimeInterval

    public init(isSpeech: Bool, probability: Double, timestamp: TimeInterval) {
        self.isSpeech = isSpeech
        self.probability = probability
        self.timestamp = timestamp
    }
}

// MARK: - Audio Player Protocol

/// Protocol for audio playback
public protocol RealtimeAudioPlayer: AnyObject, Sendable {
    /// Start playback
    func start() async throws

    /// Stop playback
    func stop() async

    /// Enqueue audio data for playback
    func enqueue(audio: Data) async throws

    /// Clear the playback queue
    func clearQueue() async

    /// Whether audio is currently playing
    var isPlaying: Bool { get }

    /// Current playback position
    var currentPosition: TimeInterval { get }
}

// MARK: - Audio Recorder Protocol

/// Protocol for audio recording
public protocol RealtimeAudioRecorder: AnyObject, Sendable {
    /// Start recording
    func start() async throws

    /// Stop recording
    func stop() async

    /// Stream of recorded audio data
    var audioStream: AsyncThrowingStream<Data, Error> { get }

    /// Whether recording is in progress
    var isRecording: Bool { get }

    /// Sample rate of recorded audio
    var sampleRate: Int { get }
}
