import Foundation
import LangTools

#if canImport(WhisperKit) && canImport(AVFoundation) && !os(watchOS)
import AVFoundation
import CoreML
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
public final class WhisperKitSpeechRecognitionProvider: BlockingStreamingSpeechRecognitionProviding, ObservableObject {
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
    private var currentModelVariant: String?
    private var modelVariantProvider: @MainActor () -> String
    private var languageIdentifierProvider: @MainActor () -> String?
    private var audioStreamTranscriber: AudioStreamTranscriber?
    private var startupTask: Task<Void, Never>?
    private var initializationTask: Task<Void, Never>?
    private var streamTranscriptionTask: Task<Void, Never>?
    private var finalTranscriptionContinuation: CheckedContinuation<String, Never>?
    var lastTranscribedText = ""
    private var hasEmittedFinalTranscription = false
    private var isStoppingStreaming = false

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
                try await self.startStreamingRecognition { [weak self] event in
                    self?.eventHandler?(event)
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

    /// Resets cached model/loading state.
    ///
    /// Callers should stop an active streaming session before calling `reset()`. This method
    /// cancels outstanding initialization/startup tasks and clears provider state synchronously;
    /// it does not wait for microphone capture teardown beyond the provider's cooperative
    /// streaming-session cleanup.
    public func reset() {
        initializationTask?.cancel()
        initializationTask = nil
        startupTask?.cancel()
        startupTask = nil
        completePendingFinalTranscriptionWithCurrentText()
        finishStreamingSession(clearLastTranscribedText: true, resetTranscriber: true)
        whisperKit = nil
        isInitializing = false
        currentModelVariant = nil
        isStoppingStreaming = false
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
        guard !isInitializing else { return }
        isInitializing = true
        defer { isInitializing = false }

        loadingState = isModelDownloaded(modelVariant) ? .loading : .downloading
        do {
            let config = makeWhisperKitConfig(modelVariant: modelVariant)
            let initializedWhisperKit = try await WhisperKit(config)
            try Task.checkCancellation()
            whisperKit = initializedWhisperKit
            loadingState = .loading
            try await whisperKit?.loadModels()
            try Task.checkCancellation()
            currentModelVariant = modelVariant
            loadingState = .ready
        } catch is CancellationError {
            whisperKit = nil
            currentModelVariant = nil
            loadingState = .idle
            throw CancellationError()
        } catch {
            whisperKit = nil
            currentModelVariant = nil
            loadingState = .failed(error.localizedDescription)
            throw WhisperKitLangToolsSpeechError.transcriptionFailed("WhisperKit initialization failed: \(error.localizedDescription)")
        }
    }

    private func makeWhisperKitConfig(modelVariant: String) -> WhisperKitConfig {
        let computeOptions = ModelComputeOptions(
            audioEncoderCompute: .cpuAndGPU,
            textDecoderCompute: .cpuAndNeuralEngine
        )
        return WhisperKitConfig(
            model: modelVariant,
            computeOptions: computeOptions,
            verbose: false,
            prewarm: false,
            load: false,
            download: true
        )
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
        try await startStreamingTranscription(
            onPartialResult: { text, isFinal in
                onEvent(isFinal ? .finalTranscription(text) : .partialTranscription(text))
            },
            onError: { error in
                onEvent(.recognitionFailed(error.localizedDescription))
            }
        )
    }

    public func stopStreamingRecognition() async -> String? {
        await stopStreamingTranscription()
    }

    @discardableResult
    public func runStreamingRecognition(onEvent: @escaping SpeechRecognitionStreamingEventHandler) async throws -> String? {
        try await withTaskCancellationHandler {
            try await prepareStreamingTranscriber { text, isFinal in
                onEvent(isFinal ? .finalTranscription(text) : .partialTranscription(text))
            }

            resetStreamingTranscriptState()
            isStreaming = true
            debugLog("running AudioStreamTranscriber until stopped")
            do {
                try await audioStreamTranscriber?.startStreamTranscription()
                finishStreamingSession(clearLastTranscribedText: false, resetTranscriber: false)
                return currentTranscript.isEmpty ? nil : currentTranscript
            } catch is CancellationError {
                await stopStreamingCapture(clearLastTranscribedText: false, resetTranscriber: false)
                throw CancellationError()
            } catch {
                await stopStreamingCapture(clearLastTranscribedText: false, resetTranscriber: false)
                let speechError = error as? WhisperKitLangToolsSpeechError ?? .transcriptionFailed(error.localizedDescription)
                handleStreamingFailure(speechError, onError: { error in
                    onEvent(.recognitionFailed(error.localizedDescription))
                })
                debugLog("AudioStreamTranscriber run threw: \(speechError.localizedDescription)")
                throw speechError
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                await self?.stopStreamingCapture(clearLastTranscribedText: false, resetTranscriber: false)
            }
        }
    }

    public func startStreamingTranscription(
        onPartialResult: @escaping (String, Bool) -> Void,
        onError: (@MainActor @Sendable (WhisperKitLangToolsSpeechError) -> Void)? = nil
    ) async throws {
        try await prepareStreamingTranscriber(onPartialResult: onPartialResult)

        resetStreamingTranscriptState()
        isStreaming = true
        debugLog("starting AudioStreamTranscriber")
        let transcriber = audioStreamTranscriber
        streamTranscriptionTask?.cancel()
        streamTranscriptionTask = Task { [weak self, transcriber] in
            do {
                try await transcriber?.startStreamTranscription()
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.debugLog("AudioStreamTranscriber start returned")
                    self.isStreaming = false
                }
            } catch is CancellationError {
                await MainActor.run { [weak self] in
                    self?.finishStreamingSession(clearLastTranscribedText: false, resetTranscriber: false, cancelTask: false)
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.finishStreamingSession(clearLastTranscribedText: false, resetTranscriber: false, cancelTask: false)
                    let speechError = error as? WhisperKitLangToolsSpeechError ?? .transcriptionFailed(error.localizedDescription)
                    self.handleStreamingFailure(speechError, onError: onError)
                    self.debugLog("AudioStreamTranscriber start threw: \(speechError.localizedDescription)")
                }
            }
        }
    }

    private func prepareStreamingTranscriber(
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
                if !fullText.isEmpty {
                    self.lastTranscribedText = fullText
                    self.currentTranscript = fullText
                }
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
        finishStreamingSession(clearLastTranscribedText: true, resetTranscriber: false)
        debugLog("stopStreamingTranscription end result=\(result.debugDescription)")
        return result
    }

    private func stopStreamingCapture(clearLastTranscribedText: Bool, resetTranscriber: Bool) async {
        guard !isStoppingStreaming else { return }
        isStoppingStreaming = true
        defer { isStoppingStreaming = false }
        let transcriber = audioStreamTranscriber
        await transcriber?.stopStreamTranscription()
        completePendingFinalTranscriptionWithCurrentText()
        finishStreamingSession(clearLastTranscribedText: clearLastTranscribedText, resetTranscriber: resetTranscriber)
    }

    func setStreamingTranscriptForTesting(_ text: String) {
        currentTranscript = text
        lastTranscribedText = text
    }

    func resetStreamingTranscriptState() {
        currentTranscript = ""
        lastTranscribedText = ""
        hasEmittedFinalTranscription = false
    }

    private func finishStreamingSession(
        clearLastTranscribedText: Bool,
        resetTranscriber: Bool,
        cancelTask: Bool = true
    ) {
        if cancelTask {
            streamTranscriptionTask?.cancel()
        }
        streamTranscriptionTask = nil
        isStreaming = false
        if clearLastTranscribedText {
            lastTranscribedText = ""
        }
        if resetTranscriber {
            audioStreamTranscriber = nil
        }
        deactivateAudioSessionAfterStreaming()
    }

    func handleStreamingFailure(
        _ speechError: WhisperKitLangToolsSpeechError,
        onError: (@MainActor @Sendable (WhisperKitLangToolsSpeechError) -> Void)?
    ) {
        lastError = speechError
        eventHandler?(.recognitionFailed(speechError.localizedDescription))
        onError?(speechError)
    }

    private func completePendingFinalTranscriptionWithCurrentText() {
        guard let continuation = finalTranscriptionContinuation else { return }
        finalTranscriptionContinuation = nil
        continuation.resume(returning: currentTranscript.isEmpty ? lastTranscribedText : currentTranscript)
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
