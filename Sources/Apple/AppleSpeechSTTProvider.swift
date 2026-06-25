//
//  AppleSpeechSTTProvider.swift
//  Audio
//
//  Example-app Apple Speech Framework speech-to-text adapter
//

import Foundation
import LangTools
import Speech

/// Example-app Apple Speech provider that supplies settings integration around
/// the reusable AppleLangTools provider.
public class AppleSpeechSTTProvider: SpeechRecognitionProviding {
    private let provider: AppleSpeechRecognitionProvider
    private let languageIdentifierProvider: @MainActor () -> String?
    private var currentLocale: Locale

    public var providerID: LangToolsProviderID { provider.providerID }
    public var displayName: String { provider.displayName }
    public var capabilities: ProviderCapabilities { provider.capabilities }
    public var eventHandler: (@MainActor @Sendable (SpeechRecognitionEvent) -> Void)? {
        get { provider.eventHandler }
        set { provider.eventHandler = newValue }
    }
    public var authorizationState: ProviderAuthorizationState { provider.authorizationState }
    public var assetState: ProviderAssetState { provider.assetState }
    public var isListening: Bool { provider.isListening }
    public var currentTranscript: String { provider.currentTranscript }
    public var isStreaming: Bool { provider.isStreaming }

    public init(
        locale: Locale = .current,
        languageIdentifierProvider: @escaping @MainActor () -> String? = { nil }
    ) {
        self.languageIdentifierProvider = languageIdentifierProvider
        currentLocale = locale
        provider = AppleSpeechRecognitionProvider(locale: locale)
    }

    public var isAvailable: Bool {
        provider.isAvailable
    }

    public func setLocale(_ locale: Locale) {
        guard locale != currentLocale else { return }
        currentLocale = locale
        provider.setLocale(locale)
        print("[AppleSpeech] Changed locale to: \(locale.identifier)")
    }

    public func updateLocaleFromSettings() {
        let locale = languageIdentifierProvider().map(Locale.init(identifier:)) ?? Locale.current
        setLocale(locale)
    }

    public func requestAuthorization() async -> ProviderAuthorizationState {
        await provider.requestAuthorization()
    }

    public func refreshAuthorizationState() {
        provider.refreshAuthorizationState()
    }

    public func configure(languageIdentifier: String) {
        setLocale(Locale(identifier: languageIdentifier))
        provider.configure(languageIdentifier: languageIdentifier)
    }

    public func prepareAssetsIfNeeded() {}

    public func transcribe(audioData: Data) async throws -> any LangToolsTranscriptionResponse {
        updateLocaleFromSettings()
        return try await provider.transcribe(audioData: audioData)
    }

    public static var supportedLocales: Set<Locale> {
        AppleSpeechRecognitionProvider.supportedLocales
    }

    public static var authorizationStatus: SFSpeechRecognizerAuthorizationStatus {
        AppleSpeechRecognitionProvider.authorizationStatus
    }

    public func startRecognition() throws {
        updateLocaleFromSettings()
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

    public func startStreamingTranscription(
        onPartialResult: @escaping (String) -> Void,
        onFinalResult: @escaping (String) -> Void
    ) throws {
        updateLocaleFromSettings()
        try provider.startStreamingTranscription(
            onPartialResult: onPartialResult,
            onFinalResult: onFinalResult
        )
    }

    @discardableResult
    public func stopStreamingTranscription() -> String? {
        provider.stopStreamingTranscription()
    }

    public func cancelStreamingTranscription() {
        provider.cancelStreamingTranscription()
    }
}
