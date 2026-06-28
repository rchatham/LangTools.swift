//
//  STTService.swift
//  Audio
//
//  Multi-provider STT service supporting Apple Speech, OpenAI Whisper, and WhisperKit
//  Uses real-time streaming for Apple Speech and WhisperKit, chunked for OpenAI
//

import Foundation
import SwiftUI
import Combine
import AVFoundation
import LangTools

/// STT processing status for UI feedback
public enum STTStatus: Equatable {
    case idle
    case initializingProvider
    case recording
    case processing
    case transcribing
    case complete(String)
    case error(String)

    public var description: String {
        switch self {
        case .idle: return "Ready"
        case .initializingProvider: return "Initializing..."
        case .recording: return "Listening..."
        case .processing: return "Processing..."
        case .transcribing: return "Transcribing..."
        case .complete(let text): return text.isEmpty ? "No speech detected" : "Complete"
        case .error(let msg): return msg
        }
    }

    public var isActive: Bool {
        switch self {
        case .idle, .complete, .error: return false
        default: return true
        }
    }
}

public struct STTServiceConfiguration {
    public var languageIdentifierProvider: @MainActor () -> String?
    public var isOpenAISimulatedStreamingEnabled: @MainActor () -> Bool
    public var openAIStreamingChunkInterval: @MainActor () -> TimeInterval

    public init(
        languageIdentifierProvider: @escaping @MainActor () -> String? = { nil },
        isOpenAISimulatedStreamingEnabled: @escaping @MainActor () -> Bool = { false },
        openAIStreamingChunkInterval: @escaping @MainActor () -> TimeInterval = { 3.0 }
    ) {
        self.languageIdentifierProvider = languageIdentifierProvider
        self.isOpenAISimulatedStreamingEnabled = isOpenAISimulatedStreamingEnabled
        self.openAIStreamingChunkInterval = openAIStreamingChunkInterval
    }
}

/// Multi-provider STT service
@MainActor
public class STTService: ObservableObject {
    @Published public private(set) var isRecording: Bool = false
    @Published public private(set) var isProcessing: Bool = false
    @Published public private(set) var transcribedText: String = ""
    @Published public private(set) var partialTranscription: String = ""
    @Published public private(set) var status: STTStatus = .idle
    @Published public private(set) var error: STTError?

    /// WhisperKit loading state (for settings UI)
    @Published public private(set) var whisperKitLoadingState: WhisperKitLoadingState = .idle

    // Provider registry
    private var providers: [STTProviderType: any SpeechRecognitionProvider] = [:]
    private var currentProviderType: STTProviderType = .appleSpeech
    private var whisperKitCancellable: AnyCancellable?
    private var configuration = STTServiceConfiguration()

    // Audio recording for file-based transcription (OpenAI)
    private var audioRecorder: AVAudioEngineRecorder?

    // OpenAI chunked streaming
    private var chunkTimer: Timer?
    private var lastChunkSize: Int = 0
    private var isProcessingOpenAIChunk = false

    public static let shared = STTService()

    private init() {}

    // MARK: - Provider Registration

    public func configure(_ configuration: STTServiceConfiguration) {
        self.configuration = configuration
    }

    /// Register a provider for a given type
    public func registerProvider(_ provider: any SpeechRecognitionProvider, for type: STTProviderType) {
        providers[type] = provider

        // If this is WhisperKit, observe its loading state
        #if canImport(WhisperKitLangTools) && canImport(AVFoundation) && !os(watchOS)
        if type == .whisperKit, let whisperProvider = provider as? WhisperKitSTTProvider {
            whisperKitCancellable = whisperProvider.$loadingState
                .receive(on: RunLoop.main)
                .sink { [weak self] state in
                    self?.whisperKitLoadingState = state
                }
        }
        #endif
    }

    /// Set the current provider type
    public func setProvider(_ type: STTProviderType) {
        print("[STTService] setProvider called with type: \(type.rawValue)")
        currentProviderType = type

        // If switching to WhisperKit and it's not ready, trigger preload
        #if canImport(WhisperKitLangTools) && canImport(AVFoundation) && !os(watchOS)
        if type == .whisperKit, let whisperProvider = providers[.whisperKit] as? WhisperKitSTTProvider {
            if whisperProvider.loadingState == .idle {
                whisperProvider.preload()
            }
        }
        #endif

        // If switching to OpenAI, refresh API key from keychain
        if type == .openAIWhisper, let openAIProvider = providers[.openAIWhisper] as? OpenAISTTProvider {
            print("[STTService] Refreshing OpenAI API key...")
            openAIProvider.refreshApiKey()
        }
    }

    /// Preload WhisperKit model
    public func preloadWhisperKit() {
        #if canImport(WhisperKitLangTools) && canImport(AVFoundation) && !os(watchOS)
        if let whisperProvider = providers[.whisperKit] as? WhisperKitSTTProvider {
            whisperProvider.preload()
        }
        #endif
    }

    /// Get the current provider
    public var currentProvider: (any SpeechRecognitionProvider)? {
        providers[currentProviderType]
    }

    /// Check if the current provider is available
    public var isAvailable: Bool {
        currentProvider?.isAvailable ?? false
    }

    // MARK: - Permissions

    /// Request microphone and speech recognition permissions
    public func requestPermissions() async throws -> Bool {
        // Request microphone permission
        let micStatus = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }

        guard micStatus else { return false }

        guard let provider = currentProvider else { return false }
        return try await provider.requestPermission()
    }

    // MARK: - Provider Streaming

    /// Start provider-owned streaming for providers such as Apple Speech and WhisperKit.
    public func startAppleSpeechStreaming() async {
        guard let provider = providers[.appleSpeech] as? any StreamingSpeechRecognitionProviding else {
            print("[STTService] Apple Speech provider not available")
            error = .providerNotConfigured
            status = .error("Apple Speech not configured")
            return
        }
        await startProviderStreaming(provider, label: "Apple Speech")
    }

    /// Stop Apple Speech streaming and get final result.
    @discardableResult
    public func stopAppleSpeechStreaming() async -> String? {
        guard let provider = providers[.appleSpeech] as? any StreamingSpeechRecognitionProviding else {
            print("[STTService] stopAppleSpeechStreaming: no Apple Speech provider")
            return nil
        }
        return await stopProviderStreaming(provider, label: "Apple Speech")
    }

    private func startProviderStreaming(
        _ provider: any StreamingSpeechRecognitionProviding,
        label: String
    ) async {
        guard !isRecording && !isProcessing else {
            print("[STTService] Already recording or processing")
            return
        }
        guard !provider.supportsExternalAudioStreaming else {
            error = .providerNotConfigured
            status = .error("\(label) requires externally captured audio")
            return
        }

        if let languageIdentifier = configuration.languageIdentifierProvider() {
            provider.configure(languageIdentifier: languageIdentifier)
        }

        error = nil
        transcribedText = ""
        partialTranscription = ""
        isRecording = true
        status = .recording

        do {
            print("[STTService] Starting \(label) streaming...")
            try await provider.startStreamingRecognition { [weak self] event in
                self?.handleStreamingRecognitionEvent(event)
            }
        } catch {
            print("[STTService] \(label) streaming error: \(error)")
            self.error = error as? STTError ?? .transcriptionFailed(error.localizedDescription)
            status = .error(error.localizedDescription)
            isRecording = false
        }
    }

    @discardableResult
    private func stopProviderStreaming(
        _ provider: any StreamingSpeechRecognitionProviding,
        label: String
    ) async -> String? {
        guard isRecording else { return nil }

        isRecording = false
        isProcessing = true
        status = .processing

        let result = await provider.stopStreamingRecognition()
        if let result, !result.isEmpty {
            print("[STTService] stopProviderStreaming(\(label)): using provider result '\(result)'")
            transcribedText = result
        } else if !partialTranscription.isEmpty {
            print("[STTService] stopProviderStreaming(\(label)): copying partialTranscription to transcribedText")
            transcribedText = partialTranscription
        }

        isProcessing = false
        status = transcribedText.isEmpty ? .complete("") : .complete(transcribedText)
        return transcribedText.isEmpty ? nil : transcribedText
    }

    // MARK: - OpenAI Chunked Streaming

    /// Start chunked streaming for OpenAI (sends bounded recording segments periodically)
    public func startOpenAIChunkedStreaming() async {
        guard !isRecording && !isProcessing else { return }

        guard configuration.isOpenAISimulatedStreamingEnabled() else {
            await startFileBasedRecording()
            return
        }

        error = nil
        transcribedText = ""
        partialTranscription = ""
        lastChunkSize = 0
        print("[STTService] Starting OpenAI chunked streaming...")

        guard let provider = providers[.openAIWhisper] as? any StreamingSpeechRecognitionProviding,
              provider.supportsExternalAudioStreaming else {
            error = .providerNotConfigured
            status = .error("OpenAI streaming provider not configured")
            return
        }

        do {
            audioRecorder = AVAudioEngineRecorder()
            try audioRecorder?.startRecording()
            try await provider.startStreamingRecognition { [weak self] event in
                self?.handleStreamingRecognitionEvent(event)
            }
            isRecording = true
            status = .recording

            let interval = configuration.openAIStreamingChunkInterval()
            chunkTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.processOpenAIChunk()
                }
            }
        } catch {
            audioRecorder?.cancelRecording()
            audioRecorder = nil
            self.error = error as? STTError ?? .recordingFailed(error.localizedDescription)
            status = .error("Recording failed")
        }
    }

    private func processOpenAIChunk() async {
        guard isRecording else {
            chunkTimer?.invalidate()
            chunkTimer = nil
            return
        }
        guard !isProcessingOpenAIChunk else { return }

        guard let provider = providers[.openAIWhisper] as? any StreamingSpeechRecognitionProviding,
              provider.supportsExternalAudioStreaming,
              let audioData = audioRecorder?.getCurrentAudioData() else { return }

        guard audioData.count > lastChunkSize + 1000 else { return }
        lastChunkSize = audioData.count

        print("[STTService] Processing OpenAI cumulative chunk: \(audioData.count) bytes")
        isProcessingOpenAIChunk = true
        defer { isProcessingOpenAIChunk = false }
        do {
            try await provider.appendStreamingAudio(audioData)
        } catch {
            handleOpenAIStreamingError(error)
        }
    }

    private func handleOpenAIStreamingError(_ error: Error) {
        chunkTimer?.invalidate()
        chunkTimer = nil
        audioRecorder?.cancelRecording()
        audioRecorder = nil
        isRecording = false
        isProcessingOpenAIChunk = false
        print("[STTService] OpenAI streaming error: \(error)")
        self.error = error as? STTError ?? .transcriptionFailed(error.localizedDescription)
        status = .error(error.localizedDescription)
    }

    private func handleStreamingRecognitionEvent(_ event: SpeechRecognitionEvent) {
        switch event {
        case .partialTranscription(let text):
            if !text.isEmpty { partialTranscription = text }
        case .finalTranscription(let text), .dualLanguageFinalTranscription(let text, _):
            transcribedText = text
            partialTranscription = ""
            isRecording = false
            isProcessing = false
            status = .complete(text)
        case .recognitionFailed(let message):
            error = .transcriptionFailed(message)
            status = .error(message)
            isRecording = false
            isProcessing = false
        case .autoDetectLanguageSwitch:
            break
        }
    }

    /// Stop OpenAI chunked streaming and get final transcription
    @discardableResult
    public func stopOpenAIChunkedStreaming() async -> String? {
        chunkTimer?.invalidate()
        chunkTimer = nil

        guard isRecording else { return nil }
        isRecording = false
        isProcessing = true
        status = .processing

        let finalAudioData = audioRecorder?.stopRecording()
        audioRecorder = nil

        guard let provider = providers[.openAIWhisper] as? any StreamingSpeechRecognitionProviding,
              provider.supportsExternalAudioStreaming else {
            error = .providerNotConfigured
            status = .error("Provider not configured")
            isProcessing = false
            return nil
        }

        if let finalAudioData, finalAudioData.count > lastChunkSize {
            do {
                try await provider.appendStreamingAudio(finalAudioData)
            } catch {
                print("[STTService] Final audio chunk append failed: \(error)")
                self.error = error as? STTError ?? .transcriptionFailed(error.localizedDescription)
                status = .error(error.localizedDescription)
                isProcessing = false
                return nil
            }
        }

        let finalText = await provider.stopStreamingRecognition()
        if let finalText, !finalText.isEmpty {
            transcribedText = finalText
        } else if !partialTranscription.isEmpty {
            transcribedText = partialTranscription
        }

        isProcessing = false
        status = transcribedText.isEmpty ? .complete("") : .complete(transcribedText)
        return transcribedText.isEmpty ? nil : transcribedText
    }

    // MARK: - WhisperKit Streaming

    /// Start streaming transcription with WhisperKit
    public func startWhisperKitStreaming() async {
        guard let provider = providers[.whisperKit] as? any StreamingSpeechRecognitionProviding else {
            print("[STTService] WhisperKit provider not available")
            error = .providerNotConfigured
            status = .error("WhisperKit not configured")
            return
        }

        #if canImport(WhisperKitLangTools) && canImport(AVFoundation) && !os(watchOS)
        if let whisperProvider = providers[.whisperKit] as? WhisperKitSTTProvider,
           whisperProvider.loadingState.isLoading {
            status = .initializingProvider
        }
        #endif

        await startProviderStreaming(provider, label: "WhisperKit")
    }

    /// Stop WhisperKit streaming
    public func stopWhisperKitStreaming() async {
        guard let provider = providers[.whisperKit] as? any StreamingSpeechRecognitionProviding else {
            print("[STTService] stopWhisperKitStreaming: no WhisperKit provider")
            return
        }
        await stopProviderStreaming(provider, label: "WhisperKit")
    }

    // MARK: - File-Based Recording (Fallback)

    /// Start file-based recording (for providers without streaming)
    public func startFileBasedRecording() async {
        guard !isRecording && !isProcessing else { return }

        error = nil
        transcribedText = ""
        partialTranscription = ""

        do {
            audioRecorder = AVAudioEngineRecorder()
            try audioRecorder?.startRecording()
            isRecording = true
            status = .recording
        } catch {
            self.error = .recordingFailed(error.localizedDescription)
            status = .error("Recording failed")
        }
    }

    /// Stop file-based recording and transcribe
    @discardableResult
    public func stopFileBasedRecording() async -> String? {
        guard isRecording else { return nil }

        isRecording = false
        isProcessing = true
        status = .processing

        guard let audioData = audioRecorder?.stopRecording() else {
            error = .noAudioData
            status = .error("No audio data")
            isProcessing = false
            return nil
        }

        audioRecorder = nil

        guard let provider = currentProvider else {
            error = .providerNotConfigured
            status = .error("Provider not configured")
            isProcessing = false
            return nil
        }

        status = .transcribing

        do {
            let response = try await provider.transcribe(audioData: audioData)
            let text = response.transcriptText
            transcribedText = text
            status = .complete(text)
            isProcessing = false
            return text
        } catch {
            self.error = error as? STTError ?? .transcriptionFailed(error.localizedDescription)
            status = .error(error.localizedDescription)
            isProcessing = false
            return nil
        }
    }

    // MARK: - Legacy API (for backward compatibility)

    /// Start recording (uses current provider's best method)
    public func startRecording() async {
        guard let provider = currentProvider else {
            error = .providerNotConfigured
            status = .error("Provider not configured")
            return
        }

        if currentProviderType == .openAIWhisper {
            await startOpenAIChunkedStreaming()
        } else if let streamingProvider = provider as? any StreamingSpeechRecognitionProviding,
                  !streamingProvider.supportsExternalAudioStreaming {
            await startProviderStreaming(streamingProvider, label: provider.displayName)
        } else {
            await startFileBasedRecording()
        }
    }

    /// Stop recording (uses current provider's best method)
    @discardableResult
    public func stopRecording() async -> String? {
        guard let provider = currentProvider else { return nil }

        if currentProviderType == .openAIWhisper {
            return await stopOpenAIChunkedStreaming()
        } else if let streamingProvider = provider as? any StreamingSpeechRecognitionProviding,
                  !streamingProvider.supportsExternalAudioStreaming {
            return await stopProviderStreaming(streamingProvider, label: provider.displayName)
        } else {
            return await stopFileBasedRecording()
        }
    }

    /// Cancel recording without transcription
    public func cancelRecording() {
        chunkTimer?.invalidate()
        chunkTimer = nil

        currentProvider?.stopRecognition(finalizePending: false, clearTranscript: true)

        audioRecorder?.cancelRecording()
        audioRecorder = nil

        partialTranscription = ""
        transcribedText = ""
        isRecording = false
        isProcessing = false
        error = nil
        status = .idle
    }

    /// Update partial transcription (for external use)
    public func updatePartialTranscription(_ text: String) {
        partialTranscription = text
    }

    /// Clear partial transcription
    public func clearPartialTranscription() {
        partialTranscription = ""
    }

    /// Clear any error state
    public func clearError() {
        error = nil
    }
}

// MARK: - VoiceInputService Protocol

/// Protocol for injecting voice input into ChatUI
@MainActor
public protocol VoiceInputService: AnyObject {
    var isRecording: Bool { get }
    var isProcessing: Bool { get }
    var statusDescription: String { get }

    func toggleRecording() async
    func getTranscribedText() -> String?
}

extension STTService: VoiceInputService {
    public func toggleRecording() async {
        if isRecording {
            await stopRecording()
        } else {
            await startRecording()
        }
    }

    public func getTranscribedText() -> String? {
        transcribedText.isEmpty ? nil : transcribedText
    }

    public var statusDescription: String {
        status.description
    }
}
