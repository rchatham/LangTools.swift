//
//  AppleSpeechRecognizer.swift
//  RealtimeTools
//
//  Created by Reid Chatham on 1/16/26.
//

#if canImport(Speech)
import Foundation
import Speech
import AVFoundation
import LangTools

// MARK: - Apple Speech Recognizer

/// On-device speech recognizer using Apple's Speech framework
@available(macOS 14.0, iOS 17.0, *)
public final class AppleSpeechRecognizer: STTProvider, @unchecked Sendable {
    // MARK: - Properties

    private let speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    private var transcriptionContinuation: AsyncThrowingStream<TranscriptionResult, Error>.Continuation?

    public private(set) var isRecognizing: Bool = false
    private let requiresOnDevice: Bool
    private let language: Locale

    // MARK: - Configuration

    public struct Configuration {
        public var language: Locale
        public var requiresOnDevice: Bool
        public var shouldReportPartialResults: Bool
        public var contextualStrings: [String]?
        public var taskHint: SFSpeechRecognitionTaskHint

        public init(
            language: Locale = .current,
            requiresOnDevice: Bool = true,
            shouldReportPartialResults: Bool = true,
            contextualStrings: [String]? = nil,
            taskHint: SFSpeechRecognitionTaskHint = .dictation
        ) {
            self.language = language
            self.requiresOnDevice = requiresOnDevice
            self.shouldReportPartialResults = shouldReportPartialResults
            self.contextualStrings = contextualStrings
            self.taskHint = taskHint
        }
    }

    private let config: Configuration

    // MARK: - Transcription Stream

    public var transcriptions: AsyncThrowingStream<TranscriptionResult, Error> {
        AsyncThrowingStream { continuation in
            self.transcriptionContinuation = continuation
        }
    }

    // MARK: - Initialization

    public init(configuration: Configuration = Configuration()) {
        self.config = configuration
        self.language = configuration.language
        self.requiresOnDevice = configuration.requiresOnDevice
        self.speechRecognizer = SFSpeechRecognizer(locale: configuration.language)
    }

    // MARK: - Authorization

    /// Request authorization for speech recognition
    public static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    /// Check current authorization status
    public static var authorizationStatus: SFSpeechRecognizerAuthorizationStatus {
        SFSpeechRecognizer.authorizationStatus()
    }

    // MARK: - STTProvider Protocol

    public func startTranscription() async throws {
        guard !isRecognizing else { return }

        guard let speechRecognizer = speechRecognizer else {
            throw AppleSpeechError.recognizerNotAvailable
        }

        guard speechRecognizer.isAvailable else {
            throw AppleSpeechError.recognizerNotAvailable
        }

        // Check authorization
        let status = Self.authorizationStatus
        guard status == .authorized else {
            throw AppleSpeechError.notAuthorized(status)
        }

        // Create recognition request
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()

        guard let recognitionRequest = recognitionRequest else {
            throw AppleSpeechError.requestCreationFailed
        }

        // Configure request
        recognitionRequest.shouldReportPartialResults = config.shouldReportPartialResults
        recognitionRequest.requiresOnDeviceRecognition = requiresOnDevice
        recognitionRequest.taskHint = config.taskHint

        if let contextualStrings = config.contextualStrings {
            recognitionRequest.contextualStrings = contextualStrings
        }

        // Start recognition task
        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            self?.handleRecognitionResult(result, error: error)
        }

        isRecognizing = true
    }

    public func stopTranscription() async throws {
        guard isRecognizing else { return }

        recognitionRequest?.endAudio()
        recognitionTask?.cancel()

        recognitionRequest = nil
        recognitionTask = nil
        isRecognizing = false
    }

    public func transcribe(audio: Data) async throws {
        guard isRecognizing else {
            throw AppleSpeechError.notRecognizing
        }

        guard let recognitionRequest = recognitionRequest else {
            throw AppleSpeechError.requestNotInitialized
        }

        // Convert Data to AVAudioPCMBuffer
        guard let buffer = createAudioBuffer(from: audio) else {
            throw AppleSpeechError.audioConversionFailed
        }

        recognitionRequest.append(buffer)
    }

    // MARK: - Private Methods

    private func handleRecognitionResult(_ result: SFSpeechRecognitionResult?, error: Error?) {
        if let error = error {
            transcriptionContinuation?.finish(throwing: AppleSpeechError.recognitionFailed(error))
            return
        }

        guard let result = result else { return }

        let transcription = TranscriptionResult(
            text: result.bestTranscription.formattedString,
            isFinal: result.isFinal,
            confidence: Double(result.bestTranscription.segments.map { $0.confidence }.reduce(0, +)) / Double(max(result.bestTranscription.segments.count, 1)),
            words: result.bestTranscription.segments.map { segment in
                TranscriptionResult.WordTiming(
                    word: segment.substring,
                    start: segment.timestamp,
                    end: segment.timestamp + segment.duration,
                    confidence: Double(segment.confidence)
                )
            },
            language: language.identifier
        )

        transcriptionContinuation?.yield(transcription)

        if result.isFinal {
            transcriptionContinuation?.finish()
        }
    }

    private func createAudioBuffer(from data: Data) -> AVAudioPCMBuffer? {
        // Assuming PCM 16-bit mono at 16kHz (common for speech recognition)
        let sampleRate: Double = 16000
        let channels: AVAudioChannelCount = 1

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: true
        ) else { return nil }

        let frameCount = AVAudioFrameCount(data.count / 2) // 2 bytes per sample for Int16

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }

        buffer.frameLength = frameCount

        data.withUnsafeBytes { rawBufferPointer in
            guard let baseAddress = rawBufferPointer.baseAddress else { return }
            if let int16ChannelData = buffer.int16ChannelData {
                memcpy(int16ChannelData[0], baseAddress, data.count)
            }
        }

        return buffer
    }
}

// MARK: - Audio Session Manager

@available(macOS 14.0, iOS 17.0, *)
public final class AppleAudioSessionManager: @unchecked Sendable {
    public static let shared = AppleAudioSessionManager()

    private init() {}

    #if os(iOS)
    /// Configure audio session for speech recognition
    public func configureForSpeechRecognition() throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
    }

    /// Configure audio session for playback
    public func configureForPlayback() throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playback, mode: .default)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
    }

    /// Configure audio session for full duplex (simultaneous record and playback)
    public func configureForFullDuplex() throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
    }

    /// Deactivate audio session
    public func deactivate() throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
    }
    #endif
}

// MARK: - Errors

public enum AppleSpeechError: Error, LocalizedError {
    case recognizerNotAvailable
    case notAuthorized(SFSpeechRecognizerAuthorizationStatus)
    case requestCreationFailed
    case requestNotInitialized
    case notRecognizing
    case audioConversionFailed
    case recognitionFailed(Error)

    public var errorDescription: String? {
        switch self {
        case .recognizerNotAvailable:
            return "Speech recognizer is not available"
        case .notAuthorized(let status):
            return "Speech recognition not authorized: \(status)"
        case .requestCreationFailed:
            return "Failed to create recognition request"
        case .requestNotInitialized:
            return "Recognition request not initialized"
        case .notRecognizing:
            return "Not currently recognizing speech"
        case .audioConversionFailed:
            return "Failed to convert audio data"
        case .recognitionFailed(let error):
            return "Recognition failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Interruption Handling

@available(macOS 14.0, iOS 17.0, *)
extension AppleSpeechRecognizer {
    /// Handle audio session interruption (e.g., phone call)
    public func handleInterruption(type: AVAudioSession.InterruptionType) async {
        switch type {
        case .began:
            // Pause recognition
            try? await stopTranscription()

        case .ended:
            // Resume recognition if needed
            // The caller should decide whether to restart
            break

        @unknown default:
            break
        }
    }
}

#endif
