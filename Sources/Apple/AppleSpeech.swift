//
//  AppleSpeech.swift
//  LangTools
//
//  On-device speech recognition using Apple's Speech framework
//

import Foundation
import Speech

/// Namespace for Apple Speech recognition functionality
///
/// AppleSpeech provides on-device speech-to-text using iOS/macOS Speech framework.
/// It's completely private (on-device), supports multiple languages, and works offline.
///
/// Example usage:
/// ```swift
/// // Request authorization
/// let status = await AppleSpeech.requestAuthorization()
/// guard status == .authorized else { return }
///
/// // Create and execute transcription request
/// let request = AppleSpeech.TranscriptionRequest(
///     audioURL: audioFileURL,
///     locale: .current
/// )
/// let transcript = try await request.execute()
/// ```
public enum AppleSpeech {
    /// Get the set of locales supported by Apple Speech framework
    public static var supportedLocales: Set<Locale> {
        SFSpeechRecognizer.supportedLocales()
    }

    /// Request permission to use speech recognition
    public static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    /// Current authorization status
    public static var authorizationStatus: SFSpeechRecognizerAuthorizationStatus {
        SFSpeechRecognizer.authorizationStatus()
    }
}
