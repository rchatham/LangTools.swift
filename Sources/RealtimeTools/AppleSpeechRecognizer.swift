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

    // The session state below is written from caller-invoked methods
    // (startTranscription/stopTranscription/transcribe) and read from the
    // Speech framework's recognition callback queue — guarded by `lock`.
    private let lock = NSLock()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    /// The current session's stream. Each recognition callback captures the
    /// continuation of the session it belongs to, so the cancellation error
    /// a task delivers after stopTranscription() lands on that session's
    /// already-finished stream and is dropped.
    private var continuation: AsyncThrowingStream<TranscriptionResult, Error>.Continuation?
    private var _isRecognizing: Bool = false

    public var isRecognizing: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isRecognizing
    }


    private let requiresOnDevice: Bool
    private let language: Locale

    // MARK: - Configuration

    public struct Configuration {
        public var language: Locale
        public var requiresOnDevice: Bool
        public var shouldReportPartialResults: Bool
        public var contextualStrings: [String]?
        public var taskHint: SFSpeechRecognitionTaskHint
        /// Sample rate of the PCM16 mono audio passed to `transcribe(audio:)`.
        /// Must match whatever produces the audio (e.g. a pipeline's
        /// `AudioProcessingSettings.inputSampleRate`) — mismatched rates are
        /// interpreted at the wrong speed rather than failing loudly.
        public var sampleRate: Double

        public init(
            language: Locale = .current,
            requiresOnDevice: Bool = true,
            shouldReportPartialResults: Bool = true,
            contextualStrings: [String]? = nil,
            taskHint: SFSpeechRecognitionTaskHint = .dictation,
            sampleRate: Double = 16000
        ) {
            self.language = language
            self.requiresOnDevice = requiresOnDevice
            self.shouldReportPartialResults = shouldReportPartialResults
            self.contextualStrings = contextualStrings
            self.taskHint = taskHint
            self.sampleRate = sampleRate
        }
    }

    private let config: Configuration

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

    public func startTranscription() async throws -> AsyncThrowingStream<TranscriptionResult, Error> {
        if isRecognizing {
            throw AppleSpeechError.alreadyRecognizing
        }

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
        let recognitionRequest = SFSpeechAudioBufferRecognitionRequest()

        // Configure request
        recognitionRequest.shouldReportPartialResults = config.shouldReportPartialResults
        recognitionRequest.requiresOnDeviceRecognition = requiresOnDevice
        recognitionRequest.taskHint = config.taskHint

        if let contextualStrings = config.contextualStrings {
            recognitionRequest.contextualStrings = contextualStrings
        }

        // Start recognition task
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: TranscriptionResult.self)
        let recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            self?.handleRecognitionResult(result, error: error, continuation: continuation)
        }

        lock.lock()
        self.recognitionRequest = recognitionRequest
        self.recognitionTask = recognitionTask
        self.continuation = continuation
        _isRecognizing = true
        lock.unlock()

        return stream
    }

    public func stopTranscription() async throws {
        lock.lock()
        guard _isRecognizing else { lock.unlock(); return }
        let request = recognitionRequest
        let task = recognitionTask
        let continuation = self.continuation
        recognitionRequest = nil
        recognitionTask = nil
        self.continuation = nil
        _isRecognizing = false
        lock.unlock()

        continuation?.finish()
        request?.endAudio()
        task?.cancel()
    }

    public func transcribe(audio: Data) async throws {
        lock.lock()
        let recognizing = _isRecognizing
        let request = recognitionRequest
        lock.unlock()

        guard recognizing else {
            throw AppleSpeechError.notRecognizing
        }

        guard let request else {
            throw AppleSpeechError.requestNotInitialized
        }

        // Convert Data to AVAudioPCMBuffer
        guard let buffer = createAudioBuffer(from: audio) else {
            throw AppleSpeechError.audioConversionFailed
        }

        request.append(buffer)
    }

    // MARK: - Private Methods

    private func handleRecognitionResult(
        _ result: SFSpeechRecognitionResult?,
        error: Error?,
        continuation: AsyncThrowingStream<TranscriptionResult, Error>.Continuation
    ) {
        if let error = error {
            continuation.finish(throwing: AppleSpeechError.recognitionFailed(error))
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

        continuation.yield(transcription)

        // Intentionally do not finish the stream on `result.isFinal` — a final
        // result ends the current utterance, not the session.
        // `TranscriptionResult.isFinal` signals end-of-utterance; the stream
        // finishes in stopTranscription().
    }

    private func createAudioBuffer(from data: Data) -> AVAudioPCMBuffer? {
        makePCM16MonoBuffer(from: data, sampleRate: config.sampleRate)
    }
}

// MARK: - PCM Conversion

/// Wraps 16-bit mono PCM `data` in an `AVAudioPCMBuffer` at `sampleRate`.
/// A trailing odd byte (half a sample) is dropped.
func makePCM16MonoBuffer(from data: Data, sampleRate: Double) -> AVAudioPCMBuffer? {
    guard let format = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: true
    ) else { return nil }

    let frameCount = AVAudioFrameCount(data.count / MemoryLayout<Int16>.size)

    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
        return nil
    }

    buffer.frameLength = frameCount

    data.withUnsafeBytes { rawBufferPointer in
        guard let baseAddress = rawBufferPointer.baseAddress else { return }
        if let int16ChannelData = buffer.int16ChannelData {
            // Copy whole samples only: an odd trailing byte doesn't fit in
            // the buffer, and copying data.count would overrun it.
            memcpy(int16ChannelData[0], baseAddress, Int(frameCount) * MemoryLayout<Int16>.size)
        }
    }

    return buffer
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
    case alreadyRecognizing
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
        case .alreadyRecognizing:
            return "A transcription session is already running"
        case .audioConversionFailed:
            return "Failed to convert audio data"
        case .recognitionFailed(let error):
            return "Recognition failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Interruption Handling

#if os(iOS)
@available(iOS 17.0, *)
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

#endif
