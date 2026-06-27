import Foundation
import LangTools

/// Reusable OpenAI speech-to-text provider adapter.
///
/// This provider intentionally does not perform audio transcoding. Callers must
/// pass audio bytes in a format supported by OpenAI's transcription endpoint and
/// either configure `defaultFileType` or call `transcribe(audioData:fileType:...)`.
@MainActor
open class OpenAISpeechRecognitionProvider: SpeechRecognitionProviding {
    public typealias AudioInputNormalizer = @MainActor (Data) throws -> (audioData: Data, fileType: OpenAI.AudioTranscriptionRequest.FileType)

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
    private var defaultFileType: OpenAI.AudioTranscriptionRequest.FileType
    private var languageIdentifierProvider: @MainActor () -> String?
    private var apiKeyProvider: @MainActor () -> String?
    private var audioInputNormalizer: AudioInputNormalizer?

    public var authorizationState: ProviderAuthorizationState {
        openAI == nil ? .unavailable(reason: "Missing OpenAI client") : .authorized
    }

    public var assetState: ProviderAssetState { .notRequired }
    public var isAvailable: Bool { openAI != nil }
    public var isListening: Bool { false }

    public init(
        openAI: OpenAI? = nil,
        defaultFileType: OpenAI.AudioTranscriptionRequest.FileType = .wav,
        languageIdentifierProvider: @escaping @MainActor () -> String? = { nil },
        audioInputNormalizer: AudioInputNormalizer? = nil
    ) {
        self.openAI = openAI
        self.defaultFileType = defaultFileType
        self.languageIdentifierProvider = languageIdentifierProvider
        self.apiKeyProvider = { nil }
        self.audioInputNormalizer = audioInputNormalizer
    }

    public convenience init(
        openAI: OpenAI? = nil,
        languageIdentifier: String?
    ) {
        self.init(
            openAI: openAI,
            languageIdentifierProvider: { languageIdentifier }
        )
    }

    public convenience init(
        apiKeyProvider: @escaping @MainActor () -> String?,
        defaultFileType: OpenAI.AudioTranscriptionRequest.FileType = .wav,
        languageIdentifierProvider: @escaping @MainActor () -> String? = { nil },
        audioInputNormalizer: AudioInputNormalizer? = nil
    ) {
        self.init(
            openAI: apiKeyProvider().map { OpenAI(apiKey: $0) },
            defaultFileType: defaultFileType,
            languageIdentifierProvider: languageIdentifierProvider,
            audioInputNormalizer: audioInputNormalizer
        )
        self.apiKeyProvider = apiKeyProvider
    }

    public func updateOpenAI(_ openAI: OpenAI?) {
        apiKeyProvider = { nil }
        self.openAI = openAI
    }

    public func updateApiKey(_ apiKey: String) {
        apiKeyProvider = { apiKey }
        openAI = OpenAI(apiKey: apiKey)
    }

    public func refreshApiKey() {
        // A nil dynamic key means "keep the currently injected client"; callers can
        // explicitly clear credentials with updateOpenAI(nil).
        guard let apiKey = apiKeyProvider() else { return }
        openAI = OpenAI(apiKey: apiKey)
    }

    public func updateDefaultFileType(_ fileType: OpenAI.AudioTranscriptionRequest.FileType) {
        defaultFileType = fileType
    }

    public func configure(languageIdentifier: String) {
        let normalizedLanguageIdentifier = languageIdentifier == "auto" ? nil : languageIdentifier
        languageIdentifierProvider = { normalizedLanguageIdentifier }
    }

    public func requestAuthorization() async -> ProviderAuthorizationState {
        refreshApiKey()
        return authorizationState
    }

    public func refreshAuthorizationState() {
        refreshApiKey()
    }

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
        refreshApiKey()
        if let audioInputNormalizer {
            let normalizedInput = try audioInputNormalizer(audioData)
            return try await transcribe(audioData: normalizedInput.audioData, fileType: normalizedInput.fileType)
        }
        return try await transcribe(audioData: audioData, fileType: defaultFileType)
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
            language: language ?? languageIdentifierProvider(),
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
