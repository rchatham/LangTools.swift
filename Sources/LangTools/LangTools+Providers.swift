import Foundation

/// Stable identifier for a concrete language provider implementation.
public struct LangToolsProviderID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Capability flags shared by speech, translation, and speech-synthesis providers.
///
/// Capabilities are intentionally explicit so product code does not assume every
/// provider can mimic Apple framework behavior.
public struct ProviderCapabilities: Equatable, Sendable {
    public let runsOnDevice: Bool
    public let supportsStreamingPartials: Bool
    public let supportsContinuousMode: Bool
    public let requiresNetwork: Bool
    public let requiresModelDownload: Bool

    public init(
        runsOnDevice: Bool,
        supportsStreamingPartials: Bool = false,
        supportsContinuousMode: Bool = false,
        requiresNetwork: Bool = false,
        requiresModelDownload: Bool = false
    ) {
        self.runsOnDevice = runsOnDevice
        self.supportsStreamingPartials = supportsStreamingPartials
        self.supportsContinuousMode = supportsContinuousMode
        self.requiresNetwork = requiresNetwork
        self.requiresModelDownload = requiresModelDownload
    }
}

/// Provider authorization/readiness state expressed without app-specific UI types.
public enum ProviderAuthorizationState: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
    case restricted
    case unavailable(reason: String)
}

/// Local model or framework asset readiness state.
public enum ProviderAssetState: Equatable, Sendable {
    case unknown
    case notRequired
    case missing
    case preparing
    case ready
    case failed(reason: String)
}

/// Speech recognition events emitted by an STT provider.
public enum SpeechRecognitionEvent: Equatable, Sendable {
    case partialTranscription(String)
    case finalTranscription(String)
    case recognitionFailed(String)
}

/// Shared STT provider contract for live speech recognition.
@MainActor
public protocol SpeechRecognitionProviding: AnyObject {
    var providerID: LangToolsProviderID { get }
    var displayName: String { get }
    var capabilities: ProviderCapabilities { get }
    var authorizationState: ProviderAuthorizationState { get }
    var assetState: ProviderAssetState { get }
    var isAvailable: Bool { get }
    var isListening: Bool { get }
    var currentTranscript: String { get }
    /// Called on `@MainActor` whenever a speech recognition event fires.
    /// Conforming types must guarantee delivery on the main actor. Setting this
    /// property is not thread-safe; update it only from the main actor before
    /// calling `startRecognition()`.
    var eventHandler: (@MainActor @Sendable (SpeechRecognitionEvent) -> Void)? { get set }

    func configure(languageIdentifier: String)
    func requestAuthorization() async -> ProviderAuthorizationState
    func refreshAuthorizationState()
    func prepareAssetsIfNeeded()
    /// Transcribe already-captured audio data in a provider-supported format.
    func transcribe(audioData: Data) async throws -> any LangToolsTranscriptionResponse
    func startRecognition() throws
    func stopRecognition(finalizePending: Bool, clearTranscript: Bool)
    func finalizeRecognition()
}

/// Provider-neutral callback used by streaming speech recognizers.
public typealias SpeechRecognitionStreamingEventHandler = @MainActor @Sendable (SpeechRecognitionEvent) -> Void

/// Streaming recognition errors shared by provider-neutral streaming adapters.
public enum StreamingSpeechRecognitionError: Error, LocalizedError, Equatable, Sendable {
    case externalAudioUnsupported
    case notStreaming

    public var errorDescription: String? {
        switch self {
        case .externalAudioUnsupported:
            return "This speech recognition provider does not accept externally captured streaming audio"
        case .notStreaming:
            return "Speech recognition streaming has not started"
        }
    }
}

/// Optional STT provider contract for providers that expose streaming
/// transcription with partial/final events.
///
/// `SpeechRecognitionProviding.startRecognition()` remains the common live
/// recognition entry point. This protocol is for callers that need direct
/// streaming control and want to consume events without relying on a mutable
/// `eventHandler` property. Providers that own microphone capture can implement
/// only start/stop. Providers that consume externally captured audio can also
/// override `appendStreamingAudio(_:)`.
///
/// The shape of data passed to `appendStreamingAudio(_:)` is provider-defined:
/// low-latency streaming providers may accept incremental chunks, while
/// request/response providers may require the latest complete/cumulative audio
/// buffer and replace their current transcript with each response.
@MainActor
public protocol StreamingSpeechRecognitionProviding: SpeechRecognitionProviding {
    var isStreaming: Bool { get }
    /// Whether this provider accepts externally captured audio through
    /// `appendStreamingAudio(_:)` during an active streaming session.
    var supportsExternalAudioStreaming: Bool { get }

    func startStreamingRecognition(onEvent: @escaping SpeechRecognitionStreamingEventHandler) async throws
    /// Append externally captured audio during an active streaming session.
    ///
    /// Providers define whether `audioData` must be an incremental chunk or the
    /// latest complete/cumulative buffer. Callers should consult concrete
    /// provider documentation before assuming incremental append semantics.
    func appendStreamingAudio(_ audioData: Data) async throws
    func stopStreamingRecognition() async -> String?
}

public extension StreamingSpeechRecognitionProviding {
    var supportsExternalAudioStreaming: Bool { false }

    func appendStreamingAudio(_ audioData: Data) async throws {
        throw StreamingSpeechRecognitionError.externalAudioUnsupported
    }
}

/// A text translation request expressed in provider-neutral language IDs.
public struct LangToolsTextTranslationRequest: Equatable, Sendable {
    public let text: String
    public let sourceLanguageIdentifier: String
    public let targetLanguageIdentifier: String

    public init(text: String, sourceLanguageIdentifier: String, targetLanguageIdentifier: String) {
        self.text = text
        self.sourceLanguageIdentifier = sourceLanguageIdentifier
        self.targetLanguageIdentifier = targetLanguageIdentifier
    }
}

/// A text translation response expressed in provider-neutral language IDs.
public struct LangToolsTextTranslationResponse: Equatable, Sendable {
    public let translatedText: String
    public let detectedSourceLanguageIdentifier: String?

    public init(translatedText: String, detectedSourceLanguageIdentifier: String? = nil) {
        self.translatedText = translatedText
        self.detectedSourceLanguageIdentifier = detectedSourceLanguageIdentifier
    }
}

/// Shared text-translation provider contract.
public protocol TextTranslationProviding: Sendable {
    var providerID: LangToolsProviderID { get }
    var displayName: String { get }
    var capabilities: ProviderCapabilities { get }

    func prepare(sourceLanguageIdentifier: String, targetLanguageIdentifier: String) async throws
    func translate(_ request: LangToolsTextTranslationRequest) async throws -> LangToolsTextTranslationResponse
}

/// Provider-neutral input for a live (platform) speech-synthesis provider.
///
/// Named `LangToolsSpeechSynthesisInput` rather than `LangToolsSpeechSynthesisRequest`
/// to avoid collision with the protocol `LangToolsSpeechSynthesisRequest` in
/// `LangTools+Speech.swift`, which abstracts HTTP/API TTS endpoints.
public struct LangToolsSpeechSynthesisInput: Equatable, Sendable {
    public let text: String
    public let languageIdentifier: String
    public let voiceIdentifier: String?
    public let rate: Double?

    public init(text: String, languageIdentifier: String, voiceIdentifier: String? = nil, rate: Double? = nil) {
        self.text = text
        self.languageIdentifier = languageIdentifier
        self.voiceIdentifier = voiceIdentifier
        self.rate = rate
    }
}

/// Shared TTS provider contract.
@MainActor
public protocol SpeechSynthesisProviding: AnyObject {
    var providerID: LangToolsProviderID { get }
    var displayName: String { get }
    var capabilities: ProviderCapabilities { get }
    var isSpeaking: Bool { get }

    func speak(_ request: LangToolsSpeechSynthesisInput) throws
    func stopSpeaking()
}
