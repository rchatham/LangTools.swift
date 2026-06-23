import Foundation
import LangTools

/// Reusable OpenAI speech-to-text provider adapter.
@MainActor
public final class OpenAISpeechRecognitionProvider: SpeechRecognitionProviding {
    public let providerID = LangToolsProviderID(rawValue: "openai.whisper")
    public let displayName = "OpenAI Whisper"
    public let capabilities = ProviderCapabilities(
        runsOnDevice: false,
        supportsStreamingPartials: false,
        supportsContinuousMode: false,
        supportsDualLanguageAutoDetect: false,
        requiresNetwork: true,
        requiresModelDownload: false
    )

    public var eventHandler: (@MainActor @Sendable (SpeechRecognitionEvent) -> Void)?
    public private(set) var currentTranscript = ""

    private var openAI: OpenAI?
    private var languageIdentifier: String?

    public var authorizationState: ProviderAuthorizationState {
        openAI == nil ? .unavailable(reason: "Missing OpenAI client") : .authorized
    }

    public var assetState: ProviderAssetState { .notRequired }
    public var isAvailable: Bool { openAI != nil }
    public var isListening: Bool { false }

    public init(openAI: OpenAI? = nil, languageIdentifier: String? = nil) {
        self.openAI = openAI
        self.languageIdentifier = languageIdentifier
    }

    public func updateOpenAI(_ openAI: OpenAI?) {
        self.openAI = openAI
    }

    public func configure(languageIdentifier: String) {
        self.languageIdentifier = languageIdentifier == "auto" ? nil : languageIdentifier
    }

    public func requestAuthorization() async -> ProviderAuthorizationState { authorizationState }
    public func refreshAuthorizationState() {}
    public func prepareAssetsIfNeeded() {}

    public func startRecognition() throws {
        throw OpenAISpeechProviderError.liveRecognitionUnsupported
    }

    public func startDualLanguageRecognition(otherLanguageIdentifier: String) throws {
        throw OpenAISpeechProviderError.liveRecognitionUnsupported
    }

    public func stopRecognition(finalizePending: Bool, clearTranscript: Bool) {
        if clearTranscript { currentTranscript = "" }
    }

    public func finalizeRecognition() {}

    public func transcribe(audioData: Data) async throws -> any LangToolsTranscriptionResponse {
        try await transcribe(audioData: audioData, fileType: .wav, language: languageIdentifier)
    }

    public func transcribe(
        audioData: Data,
        fileType: OpenAI.AudioTranscriptionRequest.FileType,
        language: String? = nil,
        prompt: String? = nil,
        responseFormat: OpenAI.AudioTranscriptionRequest.ResponseFormat? = .json
    ) async throws -> any LangToolsTranscriptionResponse {
        guard let openAI else { throw OpenAISpeechProviderError.providerNotConfigured }

        let request = OpenAI.AudioTranscriptionRequest(
            file: audioData,
            fileType: fileType,
            prompt: prompt,
            language: language ?? languageIdentifier,
            responseFormat: responseFormat
        )
        let response = try await openAI.perform(request: request)
        currentTranscript = response.transcriptText
        eventHandler?(.finalTranscription(response.transcriptText))
        return response
    }
}

public enum OpenAISpeechProviderError: Error, LocalizedError {
    case providerNotConfigured
    case liveRecognitionUnsupported
    case speechSynthesisPlaybackUnsupported

    public var errorDescription: String? {
        switch self {
        case .providerNotConfigured:
            return "OpenAI speech provider is not configured"
        case .liveRecognitionUnsupported:
            return "OpenAI speech provider does not support live recognition"
        case .speechSynthesisPlaybackUnsupported:
            return "OpenAI speech provider does not support local speech playback; use synthesize(_:voice:) to request audio data"
        }
    }
}
