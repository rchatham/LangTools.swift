import AVFoundation
import Foundation
import LangTools
import Speech

private extension SFSpeechRecognizerAuthorizationStatus {
    var providerAuthorizationState: ProviderAuthorizationState {
        switch self {
        case .notDetermined: return .notDetermined
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .unavailable(reason: "Unknown speech authorization status")
        }
    }
}

/// Reusable Apple Speech recognition provider adapter.
@MainActor
public final class AppleSpeechRecognitionProvider: StreamingSpeechRecognitionProviding {
    public let providerID = LangToolsProviderID(rawValue: "apple.speech")
    public let displayName = "Apple Speech"
    public let capabilities = ProviderCapabilities(
        runsOnDevice: true,
        supportsStreamingPartials: true,
        supportsContinuousMode: true,
        supportsDualLanguageAutoDetect: false,
        requiresNetwork: false,
        requiresModelDownload: false
    )
    public var eventHandler: (@MainActor @Sendable (SpeechRecognitionEvent) -> Void)?

    public var authorizationState: ProviderAuthorizationState {
        Self.authorizationStatus.providerAuthorizationState
    }

    public var assetState: ProviderAssetState { .notRequired }
    public private(set) var isListening = false
    public private(set) var currentTranscript = ""

    private var speechRecognizer: SFSpeechRecognizer?
    private var currentLocale: Locale
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionSessionID = UUID()
    private var streamingFinalizeCleanupTask: Task<Void, Never>?
    private var onPartialResultCallback: ((String) -> Void)?
    private var onFinalResultCallback: ((String) -> Void)?
    private var languageIdentifierProvider: @MainActor () -> String?

    public init(
        locale: Locale = .current,
        languageIdentifierProvider: @escaping @MainActor () -> String? = { nil }
    ) {
        currentLocale = locale
        speechRecognizer = SFSpeechRecognizer(locale: locale)
        self.languageIdentifierProvider = languageIdentifierProvider
    }

    public var isAvailable: Bool {
        speechRecognizer?.isAvailable ?? false
    }

    public func setLocale(_ locale: Locale) {
        guard locale != currentLocale else { return }
        currentLocale = locale
        speechRecognizer = SFSpeechRecognizer(locale: locale)
    }

    public func updateLocaleFromSettings() {
        guard let languageIdentifier = languageIdentifierProvider() else { return }
        setLocale(Locale(identifier: languageIdentifier))
    }

    public func configure(languageIdentifier: String) {
        languageIdentifierProvider = { languageIdentifier }
        setLocale(Locale(identifier: languageIdentifier))
    }

    public func requestAuthorization() async -> ProviderAuthorizationState {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        return status.providerAuthorizationState
    }

    public func refreshAuthorizationState() {}
    public func prepareAssetsIfNeeded() {}

    public func transcribe(audioData: Data) async throws -> any LangToolsTranscriptionResponse {
        updateLocaleFromSettings()
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("speech_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try AppleLangToolsAudioConverter.convertToWAV(audioData: audioData, outputURL: tempURL)
        return try await transcribe(audioURL: tempURL)
    }

    public func transcribe(audioURL: URL) async throws -> any LangToolsTranscriptionResponse {
        guard speechRecognizer?.isAvailable == true else {
            throw AppleLangToolsSpeechError.notAvailable
        }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw AppleLangToolsSpeechError.permissionDenied
        }

        let request = AppleSpeech.TranscriptionRequest(audioURL: audioURL, locale: currentLocale)
        let transcript = try await request.execute()
        currentTranscript = transcript
        eventHandler?(.finalTranscription(transcript))
        return transcript
    }

    public static var supportedLocales: Set<Locale> {
        SFSpeechRecognizer.supportedLocales()
    }

    public static var authorizationStatus: SFSpeechRecognizerAuthorizationStatus {
        SFSpeechRecognizer.authorizationStatus()
    }

    public func startRecognition() throws {
        updateLocaleFromSettings()
        try startStreamingTranscription(onPartialResult: { _ in }, onFinalResult: { _ in })
    }

    public func startDualLanguageRecognition(otherLanguageIdentifier: String) throws {
        throw AppleLangToolsSpeechError.notAvailable
    }

    public func stopRecognition(finalizePending: Bool, clearTranscript: Bool) {
        isListening = false
        if finalizePending {
            _ = stopStreamingTranscription()
        } else {
            cancelStreamingTranscription()
        }
        if clearTranscript { currentTranscript = "" }
    }

    public func finalizeRecognition() {
        isListening = false
        _ = stopStreamingTranscription()
    }

    public func startStreamingTranscription(
        onPartialResult: @escaping (String) -> Void,
        onFinalResult: @escaping (String) -> Void
    ) throws {
        updateLocaleFromSettings()
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            throw AppleLangToolsSpeechError.notAvailable
        }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw AppleLangToolsSpeechError.permissionDenied
        }

        onPartialResultCallback = onPartialResult
        onFinalResultCallback = onFinalResult

        #if os(iOS)
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        #endif

        audioEngine = AVAudioEngine()
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()

        guard let recognitionRequest, let audioEngine else {
            throw AppleLangToolsSpeechError.notAvailable
        }

        recognitionRequest.shouldReportPartialResults = true
        let inputNode = audioEngine.inputNode
        let hwFormat = inputNode.inputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0 && hwFormat.channelCount > 0 else {
            cleanupStreaming()
            throw AppleLangToolsSpeechError.recordingFailed("No valid audio input device available")
        }

        let sessionID = UUID()
        recognitionSessionID = sessionID

        recognitionTask = recognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            if error != nil {
                Task { @MainActor [weak self] in
                    guard let self, self.recognitionSessionID == sessionID else { return }
                    self.cleanupStreaming()
                }
                return
            }
            guard let result else { return }
            let text = result.bestTranscription.formattedString
            let isFinal = result.isFinal
            Task { @MainActor [weak self] in
                guard let self, self.recognitionSessionID == sessionID else { return }
                if isFinal {
                    self.currentTranscript = text
                    self.eventHandler?(.finalTranscription(text))
                    self.onFinalResultCallback?(text)
                    self.cleanupStreaming()
                } else {
                    self.currentTranscript = text
                    self.eventHandler?(.partialTranscription(text))
                    self.onPartialResultCallback?(text)
                }
            }
        }

        do {
            let streamingRequest = recognitionRequest
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
                streamingRequest.append(buffer)
            }
            audioEngine.prepare()
            try audioEngine.start()
            isListening = true
        } catch {
            cleanupStreaming()
            throw error
        }
    }

    /// Ends the current streaming request and returns the best-known transcript, if any.
    /// The final result may still arrive asynchronously through the final-result callback.
    @discardableResult
    public func stopStreamingTranscription() -> String? {
        guard recognitionRequest != nil else {
            return currentTranscript.isEmpty ? nil : currentTranscript
        }
        recognitionRequest?.endAudio()
        scheduleStreamingFinalizeCleanup(for: recognitionSessionID)
        return currentTranscript.isEmpty ? nil : currentTranscript
    }

    public func cancelStreamingTranscription() {
        cleanupStreaming()
    }

    public var isStreaming: Bool {
        isListening
    }

    public func startStreamingRecognition(onEvent: @escaping SpeechRecognitionStreamingEventHandler) async throws {
        try startStreamingTranscription(
            onPartialResult: { text in
                onEvent(.partialTranscription(text))
            },
            onFinalResult: { text in
                onEvent(.finalTranscription(text))
            }
        )
    }

    public func stopStreamingRecognition() async -> String? {
        stopStreamingTranscription()
    }

    private func scheduleStreamingFinalizeCleanup(for sessionID: UUID) {
        streamingFinalizeCleanupTask?.cancel()
        streamingFinalizeCleanupTask = Task { [weak self] in
            // Give Speech a short window to deliver a final result after endAudio(),
            // then release the mic/engine if no callback arrives.
            try? await Task.sleep(for: .seconds(3))
            await MainActor.run {
                guard let self, self.recognitionSessionID == sessionID else { return }
                self.cleanupStreaming()
            }
        }
    }

    private func cleanupStreaming() {
        streamingFinalizeCleanupTask?.cancel()
        streamingFinalizeCleanupTask = nil
        isListening = false
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        recognitionTask?.cancel()
        recognitionRequest = nil
        audioEngine = nil
        recognitionTask = nil
        recognitionSessionID = UUID()
        onPartialResultCallback = nil
        onFinalResultCallback = nil
    }
}

public enum AppleLangToolsSpeechError: Error, LocalizedError {
    case notAvailable
    case permissionDenied
    case recordingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notAvailable:
            return "Speech recognition is not available on this device"
        case .permissionDenied:
            return "Speech recognition permission was denied"
        case .recordingFailed(let message):
            return "Recording failed: \(message)"
        }
    }
}

enum AppleLangToolsAudioConverter {
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
        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFile.processingFormat,
            frameCapacity: AVAudioFrameCount(inputFile.length)
        ) else {
            throw AppleLangToolsSpeechError.recordingFailed("Could not create input audio buffer")
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
        let outputFile = try AVAudioFile(
            forWriting: tempWAV,
            settings: wavSettings,
            commonFormat: inputFile.processingFormat.commonFormat,
            interleaved: inputFile.processingFormat.isInterleaved
        )
        try outputFile.write(from: inputBuffer)
        return try Data(contentsOf: tempWAV)
    }
}
