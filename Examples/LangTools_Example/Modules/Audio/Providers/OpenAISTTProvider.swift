//
//  OpenAISTTProvider.swift
//  Audio
//
//  Example-app OpenAI Whisper speech-to-text adapter
//

import Foundation
import LangTools
import OpenAI

/// Example-app OpenAI Whisper provider that supplies keychain/settings integration
/// around the reusable OpenAI provider.
public class OpenAISTTProvider: SpeechRecognitionProvider {
    public let providerType: STTProviderType = .openAIWhisper

    private let provider = OpenAISpeechRecognitionProvider()
    private let apiKeyProvider: @MainActor () -> String?
    private let languageIdentifierProvider: @MainActor () -> String?
    private var languageIdentifier: String?

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
    public var isListening: Bool { provider.isListening }

    public init(
        apiKeyProvider: @escaping @MainActor () -> String? = { nil },
        languageIdentifierProvider: @escaping @MainActor () -> String? = { nil }
    ) {
        self.apiKeyProvider = apiKeyProvider
        self.languageIdentifierProvider = languageIdentifierProvider
        refreshApiKey()
    }

    public var isAvailable: Bool {
        authorizationState == .authorized
    }

    public func requestAuthorization() async -> ProviderAuthorizationState {
        refreshApiKey()
        return authorizationState
    }

    public func refreshAuthorizationState() {
        refreshApiKey()
    }

    public func configure(languageIdentifier: String) {
        self.languageIdentifier = languageIdentifier == "auto" ? nil : languageIdentifier
        provider.configure(languageIdentifier: languageIdentifier)
    }

    public func prepareAssetsIfNeeded() {}

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

    public func requestPermission() async throws -> Bool {
        guard isAvailable else { throw STTError.providerNotConfigured }
        return true
    }

    public func transcribe(audioData: Data) async throws -> any LangToolsTranscriptionResponse {
        if !isAvailable { refreshApiKey() }
        guard isAvailable else { throw STTError.providerNotConfigured }

        let wavData: Data
        do {
            wavData = try AudioConverter.convertToWAV(cafData: audioData)
        } catch {
            throw STTError.transcriptionFailed("Audio conversion failed: \(error.localizedDescription)")
        }

        let language = languageIdentifier ?? languageIdentifierProvider()

        do {
            return try await provider.transcribe(audioData: wavData, fileType: .wav, language: language)
        } catch {
            throw STTError.transcriptionFailed("OpenAI API error: \(error.localizedDescription)")
        }
    }

    /// Update the API key (called when user updates settings)
    public func updateApiKey(_ apiKey: String) {
        provider.updateOpenAI(OpenAI(apiKey: apiKey))
    }

    /// Refresh API key from Keychain
    public func refreshApiKey() {
        if let apiKey = apiKeyProvider() {
            provider.updateOpenAI(OpenAI(apiKey: apiKey))
        } else {
            provider.updateOpenAI(nil)
        }
    }
}
