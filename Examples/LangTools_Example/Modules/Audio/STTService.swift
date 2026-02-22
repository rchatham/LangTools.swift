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
import Speech
import Chat

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
    private var providers: [STTProviderType: STTProviderProtocol] = [:]
    private var currentProviderType: STTProviderType = .appleSpeech
    private var whisperKitCancellable: AnyCancellable?

    // Audio capture for Apple Speech real-time streaming
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var speechRecognizer: SFSpeechRecognizer?

    // Audio recording for file-based transcription (OpenAI)
    private var audioRecorder: AVAudioEngineRecorder?

    // Continuation for waiting on streaming results
    private var streamingContinuation: CheckedContinuation<String?, Never>?

    // OpenAI chunked streaming
    private var chunkTimer: Timer?
    private var lastChunkSize: Int = 0

    public static let shared = STTService()

    private init() {
        speechRecognizer = SFSpeechRecognizer(locale: .current)
    }

    // MARK: - Provider Registration

    /// Register a provider for a given type
    public func registerProvider(_ provider: STTProviderProtocol, for type: STTProviderType) {
        providers[type] = provider

        // If this is WhisperKit, observe its loading state
        if type == .whisperKit, let whisperProvider = provider as? WhisperKitSTTProvider {
            whisperKitCancellable = whisperProvider.$loadingState
                .receive(on: RunLoop.main)
                .sink { [weak self] state in
                    self?.whisperKitLoadingState = state
                }
        }
    }

    /// Set the current provider type
    public func setProvider(_ type: STTProviderType) {
        print("[STTService] setProvider called with type: \(type.rawValue)")
        currentProviderType = type

        // If switching to WhisperKit and it's not ready, trigger preload
        if type == .whisperKit, let whisperProvider = providers[.whisperKit] as? WhisperKitSTTProvider {
            if whisperProvider.loadingState == .idle {
                whisperProvider.preload()
            }
        }

        // If switching to OpenAI, refresh API key from keychain
        if type == .openAIWhisper, let openAIProvider = providers[.openAIWhisper] as? OpenAISTTProvider {
            print("[STTService] Refreshing OpenAI API key...")
            openAIProvider.refreshApiKey()
        }
    }

    /// Preload WhisperKit model
    public func preloadWhisperKit() {
        if let whisperProvider = providers[.whisperKit] as? WhisperKitSTTProvider {
            whisperProvider.preload()
        }
    }

    /// Get the current provider
    public var currentProvider: STTProviderProtocol? {
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

        // Request speech recognition permission (for Apple Speech)
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }

        // Also request provider-specific permissions
        if let provider = currentProvider {
            _ = try await provider.requestPermission()
        }

        return speechStatus == .authorized
    }

    // MARK: - Apple Speech Real-Time Streaming

    /// Start recording with real-time Apple Speech transcription
    public func startAppleSpeechStreaming() async {
        guard !isRecording && !isProcessing else {
            print("[STTService] Already recording or processing")
            return
        }

        // Clear previous state
        error = nil
        transcribedText = ""
        partialTranscription = ""

        // Update recognizer locale from settings
        let languageSetting = ToolSettings.shared.sttLanguage.rawValue
        let locale = languageSetting == "auto" ? Locale.current : Locale(identifier: languageSetting)
        speechRecognizer = SFSpeechRecognizer(locale: locale)

        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            status = .error("Speech recognition not available")
            return
        }

        do {
            recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            guard let request = recognitionRequest else {
                status = .error("Failed to create recognition request")
                return
            }

            request.shouldReportPartialResults = true

            if #available(iOS 13, macOS 13, *) {
                request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
            }

            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                guard let self = self else { return }

                if let error = error {
                    Task { @MainActor in
                        let nsError = error as NSError
                        if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 216 {
                            return // Cancellation is normal
                        }
                        print("[STTService] Recognition error: \(error.localizedDescription)")
                    }
                    return
                }

                guard let result = result else { return }
                let text = result.bestTranscription.formattedString

                Task { @MainActor in
                    self.partialTranscription = text

                    if result.isFinal {
                        self.transcribedText = text
                        self.status = text.isEmpty ? .complete("") : .complete(text)
                        self.isProcessing = false

                        self.streamingContinuation?.resume(returning: text.isEmpty ? nil : text)
                        self.streamingContinuation = nil
                    }
                }
            }

            try startAudioCapture()
            isRecording = true
            status = .recording

        } catch {
            status = .error("Failed to start recording: \(error.localizedDescription)")
            cleanupAppleSpeech()
        }
    }

    /// Stop Apple Speech streaming and get final result
    @discardableResult
    public func stopAppleSpeechStreaming() async -> String? {
        guard isRecording else { return nil }

        isRecording = false
        isProcessing = true
        status = .processing

        stopAudioCapture()
        recognitionRequest?.endAudio()

        let result = await withCheckedContinuation { continuation in
            self.streamingContinuation = continuation

            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if self.streamingContinuation != nil {
                    self.streamingContinuation?.resume(returning: self.partialTranscription.isEmpty ? nil : self.partialTranscription)
                    self.streamingContinuation = nil

                    await MainActor.run {
                        self.transcribedText = self.partialTranscription
                        self.status = self.partialTranscription.isEmpty ? .complete("") : .complete(self.partialTranscription)
                        self.isProcessing = false
                    }
                }
            }
        }

        cleanupAppleSpeech()
        return result
    }

    private func startAudioCapture() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)
        #endif

        audioEngine = AVAudioEngine()
        guard let audioEngine = audioEngine else {
            throw NSError(domain: "STT", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio engine"])
        }

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            self.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    private func stopAudioCapture() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false)
        #endif
    }

    private func cleanupAppleSpeech() {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
    }

    // MARK: - OpenAI Chunked Streaming

    /// Start chunked streaming for OpenAI (sends accumulated audio periodically)
    public func startOpenAIChunkedStreaming() async {
        guard !isRecording && !isProcessing else { return }

        guard ToolSettings.shared.enableOpenAISimulatedStreaming else {
            await startFileBasedRecording()
            return
        }

        error = nil
        transcribedText = ""
        partialTranscription = ""
        lastChunkSize = 0

        print("[STTService] Starting OpenAI chunked streaming...")

        do {
            audioRecorder = AVAudioEngineRecorder()
            try audioRecorder?.startRecording()
            isRecording = true
            status = .recording

            let interval = ToolSettings.shared.streamingChunkInterval.rawValue
            chunkTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.processOpenAIChunk()
                }
            }
        } catch {
            self.error = .recordingFailed(error.localizedDescription)
            status = .error("Recording failed")
        }
    }

    private func processOpenAIChunk() async {
        guard isRecording else {
            chunkTimer?.invalidate()
            chunkTimer = nil
            return
        }

        guard let provider = providers[.openAIWhisper],
              let audioData = audioRecorder?.getCurrentAudioData() else { return }

        guard audioData.count > lastChunkSize + 1000 else { return }
        lastChunkSize = audioData.count

        print("[STTService] Processing OpenAI chunk: \(audioData.count) bytes")

        do {
            let partialText = try await provider.transcribe(audioData: audioData)
            if !partialText.isEmpty {
                partialTranscription = partialText
            }
        } catch {
            print("[STTService] Chunk transcription error: \(error)")
            self.error = error as? STTError ?? .transcriptionFailed(error.localizedDescription)
            status = .error(error.localizedDescription)
        }
    }

    /// Stop OpenAI chunked streaming and get final transcription
    @discardableResult
    public func stopOpenAIChunkedStreaming() async -> String? {
        chunkTimer?.invalidate()
        chunkTimer = nil

        if !partialTranscription.isEmpty {
            transcribedText = partialTranscription
        }

        return await stopFileBasedRecording()
    }

    // MARK: - WhisperKit Streaming

    /// Start streaming transcription with WhisperKit
    public func startWhisperKitStreaming() async {
        guard let provider = providers[.whisperKit] as? WhisperKitSTTProvider else {
            print("[STTService] WhisperKit provider not available")
            error = .providerNotConfigured
            status = .error("WhisperKit not configured")
            return
        }

        // Show initializing if model is loading
        if provider.loadingState.isLoading {
            status = .initializingProvider
        }

        isRecording = true
        status = .recording
        partialTranscription = ""
        error = nil

        do {
            print("[STTService] Starting WhisperKit streaming...")
            try await provider.startStreamingTranscription { [weak self] text, isFinal in
                Task { @MainActor in
                    // Only log when text changes
                    if self?.partialTranscription != text {
                        print("[STTService] WhisperKit partial: '\(text)'")
                    }
                    self?.partialTranscription = text
                    if isFinal {
                        print("[STTService] WhisperKit final: '\(text)'")
                        self?.transcribedText = text
                        self?.status = .complete(text)
                        self?.partialTranscription = ""
                        self?.isRecording = false
                    }
                }
            }
        } catch {
            print("[STTService] WhisperKit streaming error: \(error)")
            self.error = error as? STTError ?? .transcriptionFailed(error.localizedDescription)
            status = .error(error.localizedDescription)
            isRecording = false
        }
    }

    /// Stop WhisperKit streaming
    public func stopWhisperKitStreaming() async {
        guard let provider = providers[.whisperKit] as? WhisperKitSTTProvider else {
            print("[STTService] stopWhisperKitStreaming: no WhisperKit provider")
            return
        }
        let result = await provider.stopStreamingTranscription()

        // Use the result from provider if available, otherwise fall back to partialTranscription
        if !result.isEmpty {
            print("[STTService] stopWhisperKitStreaming: using provider result '\(result)'")
            transcribedText = result
        } else if !partialTranscription.isEmpty {
            print("[STTService] stopWhisperKitStreaming: copying partialTranscription to transcribedText")
            transcribedText = partialTranscription
        }

        isRecording = false
        status = transcribedText.isEmpty ? .complete("") : .complete(transcribedText)
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
            let text = try await provider.transcribe(audioData: audioData)
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
        switch currentProviderType {
        case .appleSpeech:
            await startAppleSpeechStreaming()
        case .openAIWhisper:
            await startOpenAIChunkedStreaming()
        case .whisperKit:
            await startWhisperKitStreaming()
        }
    }

    /// Stop recording (uses current provider's best method)
    @discardableResult
    public func stopRecording() async -> String? {
        switch currentProviderType {
        case .appleSpeech:
            return await stopAppleSpeechStreaming()
        case .openAIWhisper:
            return await stopOpenAIChunkedStreaming()
        case .whisperKit:
            await stopWhisperKitStreaming()
            return transcribedText.isEmpty ? nil : transcribedText
        }
    }

    /// Cancel recording without transcription
    public func cancelRecording() {
        chunkTimer?.invalidate()
        chunkTimer = nil

        if let provider = providers[.appleSpeech] as? AppleSpeechSTTProvider, provider.isStreaming {
            provider.cancelStreamingTranscription()
        }

        stopAudioCapture()
        cleanupAppleSpeech()
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
