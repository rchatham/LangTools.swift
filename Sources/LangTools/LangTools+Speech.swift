import Foundation

// MARK: - Speech Audio Requests

/// Provider-neutral response for requests that return synthesized audio.
public protocol LangToolsAudioResponse {
    var audioData: Data { get }
}

extension Data: @retroactive LangToolsAudioResponse {
    public var audioData: Data { self }
}

/// Provider-neutral response for requests that return transcribed text.
public protocol LangToolsTranscriptionResponse {
    var transcriptText: String { get }
    var detectedLanguageIdentifier: String? { get }
}

extension String: @retroactive LangToolsTranscriptionResponse {
    public var transcriptText: String { self }
    public var detectedLanguageIdentifier: String? { nil }
}

/// Provider-neutral shape for text-to-speech requests.
///
/// Concrete providers keep their native request type while exposing these
/// normalized properties so apps can reason about TTS requests generically.
public protocol LangToolsSpeechSynthesisRequest {
    var speechText: String { get }
    var speechVoiceIdentifier: String? { get }
    var speechSpeed: Double? { get }
    var speechResponseFormat: String? { get }
}

/// HTTP/API-backed text-to-speech request handled by a `LangTools` provider.
public protocol LangToolsTTSRequest: LangToolsRequest, LangToolsSpeechSynthesisRequest where Response: LangToolsAudioResponse {}

/// Provider-neutral shape for speech-to-text requests.
///
/// Providers may use in-memory audio, file URLs, or platform-native request
/// types. At least one audio source should be non-nil for concrete requests.
public protocol LangToolsSpeechTranscriptionRequest {
    associatedtype TranscriptionResponse: LangToolsTranscriptionResponse
    var speechAudioData: Data? { get }
    var speechAudioFileURL: URL? { get }
    var speechAudioFormat: String? { get }
    var speechLanguageIdentifier: String? { get }
    var speechPrompt: String? { get }
}

/// HTTP/API-backed speech-to-text request handled by a `LangTools` provider.
///
/// - Important: **Breaking change from the original `Response == String` constraint.**
///   `Response` must now conform to `LangToolsTranscriptionResponse`. Existing conformances
///   can declare `typealias TranscriptionResponse = String` as a migration path, since
///   `String` already conforms to `LangToolsTranscriptionResponse`.
public protocol LangToolsSTTRequest: LangToolsRequest, LangToolsSpeechTranscriptionRequest where Response == TranscriptionResponse {}
