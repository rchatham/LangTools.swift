//
//  WhisperKitSTTProvider.swift
//  Audio
//
//  Example-app WhisperKit speech-to-text adapter
//

import Combine
import Foundation
import LangTools

/// Example-app WhisperKit provider that supplies injected settings around
/// the reusable WhisperKitLangTools provider.
@available(macOS 13, iOS 16, *)
public class WhisperKitSTTProvider: SpeechRecognitionProviding, ObservableObject {
    private let provider: WhisperKitSpeechRecognitionProvider
    private var cancellables: Set<AnyCancellable> = []

    @Published public private(set) var loadingState: WhisperKitLoadingState = .idle
    @Published public private(set) var isStreaming = false

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
    public var modelState: String { provider.modelState }

    public init(
        modelVariantProvider: @escaping @MainActor () -> String = { "base" },
        languageIdentifierProvider: @escaping @MainActor () -> String? = { nil }
    ) {
        provider = WhisperKitSpeechRecognitionProvider(
            modelVariantProvider: modelVariantProvider,
            languageIdentifierProvider: languageIdentifierProvider
        )

        provider.$loadingState
            .receive(on: RunLoop.main)
            .assign(to: &$loadingState)
        provider.$isStreaming
            .receive(on: RunLoop.main)
            .assign(to: &$isStreaming)
    }

    public var isAvailable: Bool {
        provider.isAvailable
    }

    public func requestAuthorization() async -> ProviderAuthorizationState {
        await provider.requestAuthorization()
    }

    public func refreshAuthorizationState() {
        provider.refreshAuthorizationState()
    }

    public func configure(languageIdentifier: String) {
        provider.configure(languageIdentifier: languageIdentifier)
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
        return try await provider.transcribe(audioData: audioData)
    }

    public func preload() {
        provider.preload()
    }

    public func reloadIfNeeded() async throws {
        try await provider.reloadIfNeeded()
    }

    public func startStreamingTranscription(
        onPartialResult: @escaping (String, Bool) -> Void
    ) async throws {
        try await provider.startStreamingTranscription(onPartialResult: onPartialResult)
    }

    public func stopStreamingTranscription() async -> String {
        await provider.stopStreamingTranscription()
    }

    public func downloadModel(_ modelName: String) async throws {
        try await provider.downloadModel(modelName)
    }

    public func isModelDownloaded(_ modelName: String) -> Bool {
        provider.isModelDownloaded(modelName)
    }

    public static var availableModels: [String] {
        WhisperKitSpeechRecognitionProvider.availableModels
    }

    public static func recommendedModel() async -> String {
        await WhisperKitSpeechRecognitionProvider.recommendedModel()
    }
}
