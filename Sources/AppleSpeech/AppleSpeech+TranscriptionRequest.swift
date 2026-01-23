//
//  AppleSpeech+TranscriptionRequest.swift
//  LangTools
//
//  Speech-to-text transcription request for Apple Speech framework
//

import Foundation
import Speech
import AVFoundation

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
    public struct TranscriptionRequest {
        /// Audio file URL to transcribe
        public let audioURL: URL

        /// Locale for speech recognition (e.g., en-US, es-ES, fr-FR)
        public let locale: Locale

        /// Whether to report partial results during recognition
        public let reportPartialResults: Bool

        /// Task hint for better recognition accuracy
        public let taskHint: SFSpeechRecognitionTaskHint

        public init(
            audioURL: URL,
            locale: Locale = .current,
            reportPartialResults: Bool = true,
            taskHint: SFSpeechRecognitionTaskHint = .unspecified
        ) {
            self.audioURL = audioURL
            self.locale = locale
            self.reportPartialResults = reportPartialResults
            self.taskHint = taskHint
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
            return try await withCheckedThrowingContinuation { continuation in
                var hasResumed = false

                recognizer.recognitionTask(with: request) { result, error in
                    // Prevent multiple resumes
                    guard !hasResumed else { return }

                    if let error = error {
                        hasResumed = true
                        continuation.resume(throwing: AppleSpeechError.recognitionFailed(error.localizedDescription))
                        return
                    }

                    guard let result = result else {
                        hasResumed = true
                        continuation.resume(throwing: AppleSpeechError.noResult)
                        return
                    }

                    // Only resume on final result
                    if result.isFinal {
                        hasResumed = true
                        let text = result.bestTranscription.formattedString

                        if text.isEmpty {
                            continuation.resume(throwing: AppleSpeechError.noSpeechDetected)
                        } else {
                            continuation.resume(returning: text)
                        }
                    }
                    // Partial results are ignored in this non-streaming implementation
                    // For streaming, use the StreamingTranscriptionRequest type
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
        }
    }
}
