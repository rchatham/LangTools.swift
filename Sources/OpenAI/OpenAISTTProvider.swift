import Foundation
import LangTools

/// Reusable OpenAI speech-to-text provider adapter.
///
/// This provider intentionally does not perform audio transcoding. Callers must
/// pass audio bytes in a format supported by OpenAI's transcription endpoint and
/// either configure `defaultFileType` or call `transcribe(audioData:fileType:...)`.
@MainActor
open class OpenAISTTProvider: SpeechRecognitionProviding {
    public typealias AudioInputNormalizer = @MainActor (Data) throws -> (audioData: Data, fileType: OpenAI.AudioTranscriptionRequest.FileType)

    private let provider: OpenAISpeechRecognitionProvider
    private var defaultFileType: OpenAI.AudioTranscriptionRequest.FileType
    private var languageIdentifierProvider: @MainActor () -> String?
    private var apiKeyProvider: @MainActor () -> String?
    private var audioInputNormalizer: AudioInputNormalizer?

    public var providerID: LangToolsProviderID { provider.providerID }
    public var displayName: String { provider.displayName }
    public var capabilities: ProviderCapabilities { provider.capabilities }
    public var eventHandler: (@MainActor @Sendable (SpeechRecognitionEvent) -> Void)? {
        get { provider.eventHandler }
        set { provider.eventHandler = newValue }
    }
    public var currentTranscript: String { provider.currentTranscript }
    public var authorizationState: ProviderAuthorizationState { provider.authorizationState }
    public var assetState: ProviderAssetState { provider.assetState }
    public var isAvailable: Bool { provider.isAvailable }
    public var isListening: Bool { provider.isListening }

    public init(
        openAI: OpenAI? = nil,
        defaultFileType: OpenAI.AudioTranscriptionRequest.FileType = .wav,
        languageIdentifierProvider: @escaping @MainActor () -> String? = { nil },
        audioInputNormalizer: AudioInputNormalizer? = nil
    ) {
        self.provider = OpenAISpeechRecognitionProvider(openAI: openAI)
        self.defaultFileType = defaultFileType
        self.languageIdentifierProvider = languageIdentifierProvider
        self.apiKeyProvider = { nil }
        self.audioInputNormalizer = audioInputNormalizer
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
        provider.updateOpenAI(openAI)
    }

    public func updateApiKey(_ apiKey: String) {
        apiKeyProvider = { apiKey }
        provider.updateOpenAI(OpenAI(apiKey: apiKey))
    }

    public func refreshApiKey() {
        provider.updateOpenAI(apiKeyProvider().map { OpenAI(apiKey: $0) })
    }

    public func updateDefaultFileType(_ fileType: OpenAI.AudioTranscriptionRequest.FileType) {
        defaultFileType = fileType
    }

    public func configure(languageIdentifier: String) {
        let normalizedLanguageIdentifier = languageIdentifier == "auto" ? nil : languageIdentifier
        languageIdentifierProvider = { normalizedLanguageIdentifier }
        provider.configure(languageIdentifier: languageIdentifier)
    }

    public func requestAuthorization() async -> ProviderAuthorizationState {
        refreshApiKey()
        return await provider.requestAuthorization()
    }

    public func refreshAuthorizationState() {
        refreshApiKey()
        provider.refreshAuthorizationState()
    }

    public func prepareAssetsIfNeeded() {
        provider.prepareAssetsIfNeeded()
    }

    public func startRecognition() throws {
        try provider.startRecognition()
    }

    public func startDualLanguageRecognition(otherLanguageIdentifier: String) throws {
        try provider.startDualLanguageRecognition(otherLanguageIdentifier: otherLanguageIdentifier)
    }

    public func stopRecognition(finalizePending: Bool, clearTranscript: Bool) {
        provider.stopRecognition(finalizePending: finalizePending, clearTranscript: clearTranscript)
    }

    public func finalizeRecognition() {
        provider.finalizeRecognition()
    }

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
        try await provider.transcribe(
            audioData: audioData,
            fileType: fileType,
            language: language ?? languageIdentifierProvider(),
            prompt: prompt,
            responseFormat: responseFormat
        )
    }
}
