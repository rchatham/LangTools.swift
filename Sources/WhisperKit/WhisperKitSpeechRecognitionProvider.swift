import Foundation
import LangTools

#if canImport(WhisperKit) && canImport(AVFoundation) && !os(watchOS)
import AVFoundation
import WhisperKit

/// WhisperKit loading state for provider UIs.
public enum WhisperKitLoadingState: Equatable, Sendable {
    case idle
    case downloading
    case loading
    case ready
    case failed(String)

    public var isLoading: Bool {
        switch self {
        case .downloading, .loading: return true
        case .idle, .ready, .failed: return false
        }
    }

    public var description: String {
        switch self {
        case .idle: return "Idle"
        case .downloading: return "Downloading model"
        case .loading: return "Loading model"
        case .ready: return "Ready"
        case .failed(let message): return "Failed: \(message)"
        }
    }
}

/// Reusable WhisperKit speech-to-text provider adapter.
@available(macOS 13, iOS 16, *)
@MainActor
public final class WhisperKitSpeechRecognitionProvider: StreamingSpeechRecognitionProviding, ObservableObject {
    public let providerID = LangToolsProviderID(rawValue: "whisperkit.local")
    public let displayName = "WhisperKit"
    public let capabilities = ProviderCapabilities(
        runsOnDevice: true,
        supportsStreamingPartials: true,
        supportsContinuousMode: true,
        requiresNetwork: false,
        requiresModelDownload: true
    )
    public var eventHandler: (@MainActor @Sendable (SpeechRecognitionEvent) -> Void)?
    public var isDebugLoggingEnabled = false
    public private(set) var currentTranscript = ""

    @Published public private(set) var loadingState: WhisperKitLoadingState = .idle
    @Published public private(set) var isStreaming = false
    /// Last asynchronous startup/streaming error reported after `startRecognition()` returns.
    @Published public private(set) var lastError: WhisperKitLangToolsSpeechError?

    private var whisperKit: WhisperKit?
    private var isInitializing = false
    private var pendingInitializationContinuations: [CheckedContinuation<Void, Error>] = []
    private var currentModelVariant: String?
    private var modelVariantProvider: @MainActor () -> String
    private var languageIdentifierProvider: @MainActor () -> String?
    private var audioStreamTranscriber: AudioStreamTranscriber?
    private var startupTask: Task<Void, Never>?
    private var initializationTask: Task<Void, Never>?
    private var finalTranscriptionContinuation: CheckedContinuation<String, Never>?
    private var lastTranscribedText = ""
    private var hasEmittedFinalTranscription = false

    public init(
        modelVariant: String = "base",
        languageIdentifier: String? = nil
    ) {
        self.modelVariantProvider = { modelVariant }
        self.languageIdentifierProvider = { languageIdentifier }
    }

    public init(
        modelVariantProvider: @escaping @MainActor () -> String,
        languageIdentifierProvider: @escaping @MainActor () -> String?
    ) {
        self.modelVariantProvider = modelVariantProvider
        self.languageIdentifierProvider = languageIdentifierProvider
    }

    public var authorizationState: ProviderAuthorizationState { .authorized }

    public var assetState: ProviderAssetState {
        switch loadingState {
        case .idle: return .unknown
        case .downloading, .loading: return .preparing
        case .ready: return .ready
        case .failed(let reason): return .failed(reason: reason)
        }
    }

    public var isListening: Bool { isStreaming }

    public var isAvailable: Bool {
        guard let whisperKit else { return false }
        return whisperKit.modelState == .loaded || whisperKit.modelState == .prewarmed
    }

    public var modelState: String {
        whisperKit?.modelState.description ?? "unloaded"
    }

    var configuredLanguageIdentifier: String? {
        languageIdentifierProvider()
    }

    public func configure(languageIdentifier: String) {
        languageIdentifierProvider = { languageIdentifier == "auto" ? nil : languageIdentifier }
    }

    public func requestAuthorization() async -> ProviderAuthorizationState { .authorized }
    public func refreshAuthorizationState() {}

    public func prepareAssetsIfNeeded() {
        preload()
    }

    public func startRecognition() throws {
        startupTask?.cancel()
        lastError = nil
        hasEmittedFinalTranscription = false
        currentTranscript = ""
        lastTranscribedText = ""
        isStreaming = true
        startupTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.startStreamingTranscription { [weak self] text, isFinal in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.currentTranscript = text
                        if isFinal {
                            self.emitFinalTranscriptionIfNeeded(text)
                        } else {
                            self.eventHandler?(.partialTranscription(text))
                        }
                    }
                }
            } catch is CancellationError {
                self.isStreaming = false
            } catch {
                self.isStreaming = false
                let speechError = error as? WhisperKitLangToolsSpeechError ?? .transcriptionFailed(error.localizedDescription)
                self.lastError = speechError
                self.eventHandler?(.recognitionFailed(speechError.localizedDescription))
            }
        }
    }

    public func stopRecognition(finalizePending: Bool, clearTranscript: Bool) {
        startupTask?.cancel()
        startupTask = nil
        guard finalizePending else {
            Task { [weak self] in
                guard let self else { return }
                _ = await self.stopStreamingTranscription()
                self.isStreaming = false
                if clearTranscript { self.currentTranscript = "" }
            }
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let text = await self.stopStreamingTranscription()
            if !text.isEmpty {
                self.currentTranscript = text
                self.emitFinalTranscriptionIfNeeded(text)
            }
            if clearTranscript { self.currentTranscript = "" }
        }
    }

    public func finalizeRecognition() {
        stopRecognition(finalizePending: true, clearTranscript: false)
    }

    public func transcribe(audioData: Data) async throws -> any LangToolsTranscriptionResponse {
        if whisperKit == nil {
            try await initializeWhisperKit()
        }
        guard let whisperKit, isAvailable else {
            throw WhisperKitLangToolsSpeechError.providerNotConfigured
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisper_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try WhisperKitLangToolsAudioConverter.convertToWAV(audioData: audioData, outputURL: tempURL)

        var decodingOptions = DecodingOptions()
        if let languageIdentifier = normalizedWhisperLanguageIdentifier() {
            decodingOptions.language = languageIdentifier
        } else {
            decodingOptions.detectLanguage = true
        }

        let resultsArray = await whisperKit.transcribe(
            audioPaths: [tempURL.path],
            decodeOptions: decodingOptions
        )
        guard let firstResult = resultsArray.first, let transcriptionResults = firstResult else {
            throw WhisperKitLangToolsSpeechError.transcriptionFailed("No transcription results")
        }

        let text = transcriptionResults.map { $0.text }.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw WhisperKitLangToolsSpeechError.transcriptionFailed("No speech detected")
        }

        currentTranscript = text
        eventHandler?(.finalTranscription(text))
        return text
    }

    public func preload() {
        guard whisperKit == nil && !isInitializing else { return }
        initializationTask?.cancel()
        initializationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.initializeWhisperKit()
            } catch is CancellationError {
                // Explicit resets cancel in-flight initialization and restore state.
            } catch {
                // `initializeWhisperKit()` publishes the failure state for UI.
            }
        }
    }

    public func reset() {
        initializationTask?.cancel()
        initializationTask = nil
        startupTask?.cancel()
        startupTask = nil
        whisperKit = nil
        isInitializing = false
        currentModelVariant = nil
        audioStreamTranscriber = nil
        finalTranscriptionContinuation?.resume(returning: currentTranscript)
        finalTranscriptionContinuation = nil
        isStreaming = false
        lastError = nil
        loadingState = .idle
    }

    public func reloadIfNeeded() async throws {
        let modelVariant = modelVariantProvider()
        if currentModelVariant != modelVariant {
            try await initializeWhisperKit()
        }
    }

    public func downloadModel(_ modelName: String) async throws {
        do {
            _ = try await WhisperKit.download(variant: modelName)
        } catch {
            throw WhisperKitLangToolsSpeechError.transcriptionFailed("Model download failed: \(error.localizedDescription)")
        }
    }

    public func isModelDownloaded(_ modelName: String) -> Bool {
        let modelFolderName = modelName.contains("_") ? modelName : "openai_whisper-\(modelName)"
        let modelFolder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("huggingface")
            .appendingPathComponent("models")
            .appendingPathComponent("argmaxinc")
            .appendingPathComponent("whisperkit-coreml")
            .appendingPathComponent(modelFolderName)
        guard let modelFolder else { return false }
        return FileManager.default.fileExists(atPath: modelFolder.path)
    }

    public static var availableModels: [String] {
        ["tiny", "base", "small", "medium", "large-v3"]
    }

    public static func recommendedModel() async -> String {
        WhisperKit.recommendedModels().default
    }

    private func initializeWhisperKit() async throws {
        let modelVariant = modelVariantProvider()
        if whisperKit != nil && currentModelVariant != modelVariant {
            whisperKit = nil
        }

        if whisperKit != nil { return }

        if isInitializing {
            // Await the in-flight initialization rather than returning silently.
            // This prevents a spurious providerNotConfigured error when transcribe()
            // races with a concurrent preload().
            try await withCheckedThrowingContinuation { continuation in
                pendingInitializationContinuations.append(continuation)
            }
            return
        }

        isInitializing = true
        loadingState = isModelDownloaded(modelVariant) ? .loading : .downloading
        do {
            let config = WhisperKitConfig(model: modelVariant, verbose: false, prewarm: false, load: false, download: true)
            let initializedWhisperKit = try await WhisperKit(config)
            try Task.checkCancellation()
            whisperKit = initializedWhisperKit
            loadingState = .loading
            try await whisperKit?.loadModels()
            try Task.checkCancellation()
            currentModelVariant = modelVariant
            loadingState = .ready
            isInitializing = false
            let waiting = pendingInitializationContinuations
            pendingInitializationContinuations.removeAll()
            waiting.forEach { $0.resume() }
        } catch is CancellationError {
            whisperKit = nil
            currentModelVariant = nil
            loadingState = .idle
            throw CancellationError()
        } catch {
            whisperKit = nil
            currentModelVariant = nil
            loadingState = .failed(error.localizedDescription)
            isInitializing = false
            let speechError = WhisperKitLangToolsSpeechError.transcriptionFailed("WhisperKit initialization failed: \(error.localizedDescription)")
            let waiting = pendingInitializationContinuations
            pendingInitializationContinuations.removeAll()
            waiting.forEach { $0.resume(throwing: speechError) }
            throw speechError
        }
    }

    func stripSpecialTokens(_ text: String) -> String {
        let patterns = ["<\\|[^|]+\\|>", "\\[[^\\]]*\\]"]
        return patterns.reduce(text) { result, pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
            let range = NSRange(result.startIndex..., in: result)
            return regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func startStreamingRecognition(onEvent: @escaping SpeechRecognitionStreamingEventHandler) async throws {
        try await startStreamingTranscription { text, isFinal in
            onEvent(isFinal ? .finalTranscription(text) : .partialTranscription(text))
        }
    }

    public func stopStreamingRecognition() async -> String? {
        await stopStreamingTranscription()
    }

    public func startStreamingTranscription(
        onPartialResult: @escaping (String, Bool) -> Void
    ) async throws {
        debugLog("startStreamingTranscription begin state=\(loadingState.description) modelState=\(modelState) available=\(isAvailable) language=\(configuredLanguageIdentifier ?? "auto") normalizedLanguage=\(normalizedWhisperLanguageIdentifier() ?? "auto")")
        if whisperKit == nil {
            debugLog("initializing WhisperKit before streaming")
            try await initializeWhisperKit()
        }
        try Task.checkCancellation()
        guard let whisperKit, isAvailable else {
            debugLog("provider unavailable after initialization state=\(loadingState.description) modelState=\(modelState)")
            throw WhisperKitLangToolsSpeechError.providerNotConfigured
        }
        guard let tokenizer = whisperKit.tokenizer else {
            debugLog("missing tokenizer modelState=\(modelState)")
            throw WhisperKitLangToolsSpeechError.providerNotConfigured
        }

        try configureAudioSessionForStreaming()

        var decodingOptions = DecodingOptions()
        if let languageIdentifier = normalizedWhisperLanguageIdentifier() {
            decodingOptions.language = languageIdentifier
        } else {
            decodingOptions.detectLanguage = true
        }

        debugLog("creating AudioStreamTranscriber")
        audioStreamTranscriber = AudioStreamTranscriber(
            audioEncoder: whisperKit.audioEncoder,
            featureExtractor: whisperKit.featureExtractor,
            segmentSeeker: whisperKit.segmentSeeker,
            textDecoder: whisperKit.textDecoder,
            tokenizer: tokenizer,
            audioProcessor: whisperKit.audioProcessor,
            decodingOptions: decodingOptions,
            requiredSegmentsForConfirmation: 2,
            silenceThreshold: 0.3,
            useVAD: true
        ) { [weak self] oldState, newState in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let confirmedText = newState.confirmedSegments.map { self.stripSpecialTokens($0.text) }.joined(separator: " ")
                let unconfirmedText = newState.unconfirmedSegments.map { self.stripSpecialTokens($0.text) }.joined(separator: " ")
                let fullText = (confirmedText + " " + unconfirmedText).trimmingCharacters(in: .whitespacesAndNewlines)
                if !fullText.isEmpty { self.lastTranscribedText = fullText }
                let isFinal = !newState.isRecording && oldState.isRecording
                let oldFullText = (oldState.confirmedSegments.map { self.stripSpecialTokens($0.text) } + oldState.unconfirmedSegments.map { self.stripSpecialTokens($0.text) }).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                if oldState.isRecording != newState.isRecording || oldState.confirmedSegments.count != newState.confirmedSegments.count || oldState.unconfirmedSegments.count != newState.unconfirmedSegments.count || isFinal {
                    self.debugLog("stream state recording \(oldState.isRecording)->\(newState.isRecording) confirmed=\(newState.confirmedSegments.count) unconfirmed=\(newState.unconfirmedSegments.count) text=\(fullText.debugDescription) final=\(isFinal)")
                }
                if !fullText.isEmpty && (fullText != oldFullText || isFinal) {
                    onPartialResult(fullText, isFinal)
                }
                if isFinal {
                    self.completeFinalTranscription(fullText)
                    self.isStreaming = false
                }
            }
        }

        hasEmittedFinalTranscription = false
        isStreaming = true
        debugLog("starting AudioStreamTranscriber")
        do {
            try await audioStreamTranscriber?.startStreamTranscription()
            debugLog("AudioStreamTranscriber start returned")
        } catch {
            isStreaming = false
            let speechError = error as? WhisperKitLangToolsSpeechError ?? .transcriptionFailed(error.localizedDescription)
            lastError = speechError
            eventHandler?(.recognitionFailed(speechError.localizedDescription))
            debugLog("AudioStreamTranscriber start threw: \(speechError.localizedDescription)")
            throw speechError
        }
    }

    public func stopStreamingTranscription() async -> String {
        debugLog("stopStreamingTranscription begin hasTranscriber=\(audioStreamTranscriber != nil) lastText=\(lastTranscribedText.debugDescription)")
        guard audioStreamTranscriber != nil else { return lastTranscribedText }
        guard finalTranscriptionContinuation == nil else { return lastTranscribedText }
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            finalTranscriptionContinuation = continuation
            let transcriber = audioStreamTranscriber
            Task.detached { await transcriber?.stopStreamTranscription() }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self.completeFinalTranscription(self.lastTranscribedText)
            }
        }
        isStreaming = false
        lastTranscribedText = ""
        deactivateAudioSessionAfterStreaming()
        debugLog("stopStreamingTranscription end result=\(result.debugDescription)")
        return result
    }

    private func normalizedWhisperLanguageIdentifier() -> String? {
        guard let identifier = languageIdentifierProvider(), !identifier.isEmpty else { return nil }
        return identifier.split(separator: "-").first.map(String.init)
    }

    private func configureAudioSessionForStreaming() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        debugLog("configuring AVAudioSession category=playAndRecord mode=default options=defaultToSpeaker,allowBluetooth")
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)
        debugLog("AVAudioSession active sampleRate=\(session.sampleRate) inputChannels=\(session.inputNumberOfChannels) route=\(session.currentRoute.inputs.map { $0.portType.rawValue }.joined(separator: ","))")
        #else
        debugLog("AVAudioSession configuration skipped on this platform")
        #endif
    }

    private func deactivateAudioSessionAfterStreaming() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func debugLog(_ message: String) {
        guard isDebugLoggingEnabled else { return }
        print("[WhisperKitSpeechRecognitionProvider] \(message)")
    }

    private func completeFinalTranscription(_ text: String) {
        guard let continuation = finalTranscriptionContinuation else { return }
        finalTranscriptionContinuation = nil
        continuation.resume(returning: text)
    }

    private func emitFinalTranscriptionIfNeeded(_ text: String) {
        guard !hasEmittedFinalTranscription else { return }
        hasEmittedFinalTranscription = true
        eventHandler?(.finalTranscription(text))
    }
}

public enum WhisperKitLangToolsSpeechError: Error, LocalizedError {
    case notAvailable
    case providerNotConfigured
    case transcriptionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notAvailable:
            return "WhisperKit speech recognition is not available"
        case .providerNotConfigured:
            return "WhisperKit speech provider is not configured"
        case .transcriptionFailed(let message):
            return "WhisperKit transcription failed: \(message)"
        }
    }
}

enum WhisperKitLangToolsAudioConverter {
    static func convertToWAV(audioData: Data, outputURL: URL) throws {
        let wavData = try convertToWAV(audioData: audioData)
        try wavData.write(to: outputURL)
    }

    static func convertToWAV(audioData: Data) throws -> Data {
        let tempInput = FileManager.default.temporaryDirectory
            .appendingPathComponent("convert_\(UUID().uuidString).caf")
        let tempWAV = FileManager.default.temporaryDirectory
            .appendingPathComponent("convert_\(UUID().uuidString).wav")
        defer {
            try? FileManager.default.removeItem(at: tempInput)
            try? FileManager.default.removeItem(at: tempWAV)
        }
        try audioData.write(to: tempInput)
        let inputFile = try AVAudioFile(forReading: tempInput)
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFile.processingFormat, frameCapacity: AVAudioFrameCount(inputFile.length)) else {
            throw WhisperKitLangToolsSpeechError.transcriptionFailed("Could not create input audio buffer")
        }
        try inputFile.read(into: inputBuffer)
        let wavSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: inputFile.processingFormat.sampleRate,
            AVNumberOfChannelsKey: inputFile.processingFormat.channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: inputFile.processingFormat.isInterleaved ? false : true
        ]
        let outputFile = try AVAudioFile(forWriting: tempWAV, settings: wavSettings, commonFormat: inputFile.processingFormat.commonFormat, interleaved: inputFile.processingFormat.isInterleaved)
        try outputFile.write(from: inputBuffer)
        return try Data(contentsOf: tempWAV)
    }
}
#endif
