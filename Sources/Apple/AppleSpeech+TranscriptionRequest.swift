//
//  AppleSpeech+TranscriptionRequest.swift
//  LangTools
//
//  Speech-to-text transcription request for Apple Speech framework
//

import Foundation
import Speech
import AVFoundation
import LangTools

private final class AppleSpeechTranscriptionContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?
    private var recognitionTask: SFSpeechRecognitionTask?

    init(_ continuation: CheckedContinuation<String, Error>) {
        self.continuation = continuation
    }

    func setRecognitionTask(_ task: SFSpeechRecognitionTask) {
        lock.lock()
        defer { lock.unlock() }
        recognitionTask = task
    }

    func cancelRecognitionTask() {
        lock.lock()
        let task = recognitionTask
        recognitionTask = nil
        lock.unlock()
        task?.cancel()
    }

    @discardableResult
    func resume(returning value: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let continuation else { return false }
        self.continuation = nil
        recognitionTask = nil
        continuation.resume(returning: value)
        return true
    }

    @discardableResult
    func resume(throwing error: Error) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let continuation else { return false }
        self.continuation = nil
        recognitionTask = nil
        continuation.resume(throwing: error)
        return true
    }
}

extension AppleSpeech {
    /// Request for transcribing audio using Apple's Speech framework
    ///
    /// Supports file-based transcription with:
    /// - On-device processing (privacy-first)
    /// - Multiple language support
    /// - Offline capability
    /// - Partial results during recognition
    ///
    /// Example:
    /// ```swift
    /// let request = AppleSpeech.TranscriptionRequest(
    ///     audioURL: audioFileURL,
    ///     locale: Locale(identifier: "en-US")
    /// )
    /// let transcript = try await request.execute()
    /// ```
    public struct TranscriptionRequest: LangToolsSpeechTranscriptionRequest {
        public typealias TranscriptionResponse = String
        /// Audio file URL to transcribe
        public let audioURL: URL

        /// Locale for speech recognition (e.g., en-US, es-ES, fr-FR)
        public let locale: Locale

        /// Whether to report partial results during recognition
        public let reportPartialResults: Bool

        /// Task hint for better recognition accuracy
        public let taskHint: SFSpeechRecognitionTaskHint

        /// Maximum wall-clock time to wait for Apple Speech to produce a final result.
        public let recognitionTimeout: TimeInterval

        public var speechAudioData: Data? { nil }
        public var speechAudioFileURL: URL? { audioURL }
        public var speechAudioFormat: String? { audioURL.pathExtension.isEmpty ? nil : audioURL.pathExtension.lowercased() }
        public var speechLanguageIdentifier: String? { locale.identifier }
        public var speechPrompt: String? { nil }

        public init(
            audioURL: URL,
            locale: Locale = .current,
            reportPartialResults: Bool = true,
            taskHint: SFSpeechRecognitionTaskHint = .unspecified,
            recognitionTimeout: TimeInterval? = nil
        ) {
            self.audioURL = audioURL
            self.locale = locale
            self.reportPartialResults = reportPartialResults
            self.taskHint = taskHint
            self.recognitionTimeout = recognitionTimeout ?? 120
        }

        /// Execute the transcription request
        public func execute() async throws -> String {
            // Create speech recognizer for the specified locale
            guard let recognizer = SFSpeechRecognizer(locale: locale) else {
                throw AppleSpeechError.localeNotSupported(locale.identifier)
            }

            guard recognizer.isAvailable else {
                throw AppleSpeechError.recognizerNotAvailable
            }

            // Check authorization
            let authStatus = SFSpeechRecognizer.authorizationStatus()
            guard authStatus == .authorized else {
                throw AppleSpeechError.permissionDenied(authStatus)
            }

            // Create recognition request
            let request = SFSpeechURLRecognitionRequest(url: audioURL)
            request.shouldReportPartialResults = reportPartialResults
            request.taskHint = taskHint

            // Perform recognition
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                let continuationBox = AppleSpeechTranscriptionContinuationBox(continuation)

                let recognitionTask = recognizer.recognitionTask(with: request) { result, error in
                    if let error = error {
                        continuationBox.resume(throwing: AppleSpeechError.recognitionFailed(error.localizedDescription))
                        return
                    }

                    guard let result else { return }

                    // Only resume on final result
                    if result.isFinal {
                        let text = result.bestTranscription.formattedString

                        if text.isEmpty {
                            continuationBox.resume(throwing: AppleSpeechError.noSpeechDetected)
                        } else {
                            continuationBox.resume(returning: text)
                        }
                    }
                    // Partial results are ignored in this non-streaming implementation
                    // For streaming, use the StreamingTranscriptionRequest type
                }

                continuationBox.setRecognitionTask(recognitionTask)
                DispatchQueue.global().asyncAfter(deadline: .now() + recognitionTimeout) {
                    if continuationBox.resume(throwing: AppleSpeechError.recognitionTimedOut) {
                        continuationBox.cancelRecognitionTask()
                    }
                }
            }
        }
    }
}

// MARK: - Error Types

public enum AppleSpeechError: Error, LocalizedError {
    case localeNotSupported(String)
    case recognizerNotAvailable
    case permissionDenied(SFSpeechRecognizerAuthorizationStatus)
    case recognitionFailed(String)
    case noResult
    case noSpeechDetected
    case recognitionTimedOut

    public var errorDescription: String? {
        switch self {
        case .localeNotSupported(let locale):
            return "Speech recognition not supported for locale: \(locale)"
        case .recognizerNotAvailable:
            return "Speech recognizer not available"
        case .permissionDenied(let status):
            return "Speech recognition permission denied (status: \(status.rawValue))"
        case .recognitionFailed(let reason):
            return "Speech recognition failed: \(reason)"
        case .noResult:
            return "No recognition result returned"
        case .noSpeechDetected:
            return "No speech detected in audio"
        case .recognitionTimedOut:
            return "Speech recognition timed out before producing a final result"
        }
    }
}
