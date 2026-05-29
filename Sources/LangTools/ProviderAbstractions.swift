import Foundation

/// Stable identifier for a concrete language provider implementation.
public struct LangToolsProviderID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
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
    public let supportsDualLanguageAutoDetect: Bool
    public let requiresNetwork: Bool
    public let requiresModelDownload: Bool

    public init(
        runsOnDevice: Bool,
        supportsStreamingPartials: Bool = false,
        supportsContinuousMode: Bool = false,
        supportsDualLanguageAutoDetect: Bool = false,
        requiresNetwork: Bool = false,
        requiresModelDownload: Bool = false
    ) {
        self.runsOnDevice = runsOnDevice
        self.supportsStreamingPartials = supportsStreamingPartials
        self.supportsContinuousMode = supportsContinuousMode
        self.supportsDualLanguageAutoDetect = supportsDualLanguageAutoDetect
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

/// Language selected during dual-language speech recognition.
public enum SpeechAutoDetectWinner: Equatable, Sendable {
    case primary
    case secondary
    case none
}

/// Speech recognition events emitted by an STT provider.
public enum SpeechRecognitionEvent: Equatable, Sendable {
    case partialTranscription(String)
    case finalTranscription(String)
    case dualLanguageFinalTranscription(String, winner: SpeechAutoDetectWinner)
    case autoDetectLanguageSwitch
}

/// Shared STT provider contract for live speech recognition.
@MainActor
public protocol SpeechRecognitionProviding: AnyObject {
    var providerID: LangToolsProviderID { get }
    var displayName: String { get }
    var capabilities: ProviderCapabilities { get }
    var authorizationState: ProviderAuthorizationState { get }
    var assetState: ProviderAssetState { get }
    var isListening: Bool { get }
    var currentTranscript: String { get }
    var eventHandler: (@MainActor @Sendable (SpeechRecognitionEvent) -> Void)? { get set }

    func configure(languageIdentifier: String)
    func requestAuthorization() async -> ProviderAuthorizationState
    func refreshAuthorizationState()
    func prepareAssetsIfNeeded()
    func startRecognition() throws
    func startDualLanguageRecognition(otherLanguageIdentifier: String) throws
    func stopRecognition(finalizePending: Bool, clearTranscript: Bool)
    func finalizeRecognition()
}

/// A text translation request expressed in provider-neutral language IDs.
public struct TextTranslationRequest: Equatable, Sendable {
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
public struct TextTranslationResponse: Equatable, Sendable {
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
    func translate(_ request: TextTranslationRequest) async throws -> TextTranslationResponse
}

/// A speech-synthesis request expressed in provider-neutral language IDs.
public struct SpeechSynthesisRequest: Equatable, Sendable {
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

    func speak(_ request: SpeechSynthesisRequest) throws
    func stopSpeaking()
}
