//
//  AppleSpeechSTTProvider.swift
//  Audio
//
//  Example-app Apple Speech Framework speech-to-text adapter
//

import AppleLangTools
import Chat
import Foundation
import LangTools
import Speech

/// Example-app Apple Speech provider that supplies settings integration around
/// the reusable AppleLangTools provider.
public class AppleSpeechSTTProvider: SpeechRecognitionProvider {
    public let providerType: STTProviderType = .appleSpeech

    private let provider: AppleSpeechRecognitionProvider
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

    public init(locale: Locale = .current) {
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
        let languageSetting = ToolSettings.shared.sttLanguage.rawValue
        let locale = languageSetting == "auto" ? Locale.current : Locale(identifier: languageSetting)
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

    public func requestPermission() async throws -> Bool {
        let state = await requestAuthorization()
        guard state == .authorized else { throw STTError.permissionDenied }
        return true
    }

    public func transcribe(audioData: Data) async throws -> any LangToolsTranscriptionResponse {
        updateLocaleFromSettings()
        do {
            return try await provider.transcribe(audioData: audioData)
        } catch let error as AppleLangToolsSpeechError {
            throw map(error)
        } catch {
            throw STTError.transcriptionFailed(error.localizedDescription)
        }
    }

    public static var supportedLocales: Set<Locale> {
        AppleSpeechRecognitionProvider.supportedLocales
    }

    public static var authorizationStatus: SFSpeechRecognizerAuthorizationStatus {
        AppleSpeechRecognitionProvider.authorizationStatus
    }

    public func startRecognition() throws {
        updateLocaleFromSettings()
        try mapProviderError { try provider.startRecognition() }
    }

    public func startDualLanguageRecognition(otherLanguageIdentifier: String) throws {
        try mapProviderError { try provider.startDualLanguageRecognition(otherLanguageIdentifier: otherLanguageIdentifier) }
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
        try mapProviderError {
            try provider.startStreamingTranscription(
                onPartialResult: onPartialResult,
                onFinalResult: onFinalResult
            )
        }
    }

    @discardableResult
    public func stopStreamingTranscription() -> String? {
        provider.stopStreamingTranscription()
    }

    public func cancelStreamingTranscription() {
        provider.cancelStreamingTranscription()
    }

    private func mapProviderError(_ operation: () throws -> Void) throws {
        do {
            try operation()
        } catch let error as AppleLangToolsSpeechError {
            throw map(error)
        }
    }

    private func map(_ error: AppleLangToolsSpeechError) -> STTError {
        switch error {
        case .notAvailable:
            return .notAvailable
        case .permissionDenied:
            return .permissionDenied
        case .recordingFailed(let message):
            return .recordingFailed(message)
        }
    }
}
