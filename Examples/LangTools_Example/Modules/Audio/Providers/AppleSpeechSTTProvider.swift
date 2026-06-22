//
//  AppleSpeechSTTProvider.swift
//  Audio
//
//  Apple Speech Framework-based speech-to-text provider
//

import Foundation
import Speech
import AVFoundation
import AppleSpeech
import Chat
import LangTools

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

/// Apple Speech Framework-based speech-to-text provider
public class AppleSpeechSTTProvider: SpeechRecognitionProvider {
    public let providerType: STTProviderType = .appleSpeech
    public let providerID = LangToolsProviderID(rawValue: "apple.speech")
    public let displayName = "Apple Speech"
    public let capabilities = ProviderCapabilities(
        runsOnDevice: true,
        supportsStreamingPartials: true,
        supportsContinuousMode: true,
        supportsDualLanguageAutoDetect: true,
        requiresNetwork: false,
        requiresModelDownload: false
    )
    public var eventHandler: (@MainActor @Sendable (SpeechRecognitionEvent) -> Void)?

    public var authorizationState: ProviderAuthorizationState {
        Self.authorizationStatus.providerAuthorizationState
    }

    public var assetState: ProviderAssetState { .notRequired }

    public var isListening: Bool { isStreaming }

    public private(set) var currentTranscript: String = ""

    private var speechRecognizer: SFSpeechRecognizer?
    private var currentLocale: Locale

    // Streaming transcription properties
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var onPartialResultCallback: ((String) -> Void)?
    private var onFinalResultCallback: ((String) -> Void)?

    public init(locale: Locale = .current) {
        self.currentLocale = locale
        speechRecognizer = SFSpeechRecognizer(locale: locale)
    }

    /// Update the locale for speech recognition
    /// - Parameter locale: The new locale to use
    public func setLocale(_ locale: Locale) {
        guard locale != currentLocale else { return }
        currentLocale = locale
        speechRecognizer = SFSpeechRecognizer(locale: locale)
        print("[AppleSpeech] Changed locale to: \(locale.identifier)")
    }

    /// Update locale from current settings
    public func updateLocaleFromSettings() {
        let languageSetting = ToolSettings.shared.sttLanguage.rawValue
        let locale: Locale
        if languageSetting == "auto" {
            locale = .current
        } else {
            locale = Locale(identifier: languageSetting)
        }
        setLocale(locale)
    }

    public var isAvailable: Bool {
        guard let recognizer = speechRecognizer else { return false }
        return recognizer.isAvailable
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

    public func configure(languageIdentifier: String) {
        setLocale(Locale(identifier: languageIdentifier))
    }

    public func requestPermission() async throws -> Bool {
        let state = await requestAuthorization()
        guard state == .authorized else { throw STTError.permissionDenied }
        return true
    }

    public func transcribe(audioData: Data) async throws -> any LangToolsTranscriptionResponse {
        // Ensure we're using the current language setting
        updateLocaleFromSettings()

        guard speechRecognizer?.isAvailable == true else {
            throw STTError.notAvailable
        }

        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw STTError.permissionDenied
        }

        // Convert CAF audio to WAV format for Speech Framework
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("speech_\(UUID().uuidString).wav")

        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        do {
            try AudioConverter.convertToWAV(cafData: audioData, outputURL: tempURL)
            print("[AppleSpeech] Converted audio to WAV, file size: \(try Data(contentsOf: tempURL).count) bytes")
        } catch {
            print("[AppleSpeech] Audio conversion failed: \(error)")
            throw STTError.transcriptionFailed("Audio conversion failed: \(error.localizedDescription)")
        }

        let request = AppleSpeech.TranscriptionRequest(audioURL: tempURL, locale: currentLocale)
        let genericRequest: any LangToolsSpeechTranscriptionRequest = request
        print("[AppleSpeech] Transcribing \(genericRequest.speechAudioFormat ?? "unknown") audio with LangTools request abstraction")

        let transcript = try await request.execute()
        currentTranscript = transcript
        return transcript
    }

    /// Get supported locales for speech recognition
    public static var supportedLocales: Set<Locale> {
        SFSpeechRecognizer.supportedLocales()
    }

    /// Check current authorization status
    public static var authorizationStatus: SFSpeechRecognizerAuthorizationStatus {
        SFSpeechRecognizer.authorizationStatus()
    }

    // MARK: - Real-time Streaming Transcription

    public func startRecognition() throws {
        try startStreamingTranscription(
            onPartialResult: { _ in },
            onFinalResult: { _ in }
        )
    }

    public func stopRecognition(finalizePending: Bool, clearTranscript: Bool) {
        if finalizePending {
            _ = stopStreamingTranscription()
        } else {
            cancelStreamingTranscription()
        }
        if clearTranscript { currentTranscript = "" }
    }

    public func finalizeRecognition() {
        _ = stopStreamingTranscription()
    }

    /// Start real-time streaming transcription
    /// - Parameters:
    ///   - onPartialResult: Callback for partial results during recognition
    ///   - onFinalResult: Callback when recognition completes with final text
    public func startStreamingTranscription(
        onPartialResult: @escaping (String) -> Void,
        onFinalResult: @escaping (String) -> Void
    ) throws {
        // Ensure we're using current language setting
        updateLocaleFromSettings()

        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            throw STTError.notAvailable
        }

        // Check authorization
        let status = SFSpeechRecognizer.authorizationStatus()
        guard status == .authorized else {
            throw STTError.permissionDenied
        }

        // Store callbacks
        self.onPartialResultCallback = onPartialResult
        self.onFinalResultCallback = onFinalResult

        // Configure audio session FIRST (before creating AVAudioEngine)
        #if os(iOS)
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        print("[AppleSpeech] Audio session configured for recording")
        #endif

        // Create audio engine AFTER audio session is configured
        audioEngine = AVAudioEngine()
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()

        guard let recognitionRequest = recognitionRequest,
              let audioEngine = audioEngine else {
            throw STTError.notAvailable
        }

        recognitionRequest.shouldReportPartialResults = true

        print("[AppleSpeech] Starting streaming transcription...")

        // Configure audio input BEFORE starting recognition task
        let inputNode = audioEngine.inputNode

        // Verify the hardware format is valid
        let hwFormat = inputNode.inputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0 && hwFormat.channelCount > 0 else {
            print("[AppleSpeech] No valid audio input device (rate: \(hwFormat.sampleRate), channels: \(hwFormat.channelCount))")
            cleanupStreaming()
            throw STTError.recordingFailed("No valid audio input device available. Please check microphone permissions.")
        }

        print("[AppleSpeech] Hardware format: \(hwFormat.sampleRate) Hz, \(hwFormat.channelCount) channels")

        // Start recognition task
        recognitionTask = recognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self = self else { return }

            if let error = error {
                print("[AppleSpeech] Streaming error: \(error)")
                self.cleanupStreaming()
                return
            }

            if let result = result {
                let text = result.bestTranscription.formattedString

                if result.isFinal {
                    print("[AppleSpeech] Streaming final result: '\(text)'")
                    self.currentTranscript = text
                    self.eventHandler?(.finalTranscription(text))
                    self.onFinalResultCallback?(text)
                    self.cleanupStreaming()
                } else {
                    print("[AppleSpeech] Streaming partial: '\(text)'")
                    self.currentTranscript = text
                    self.eventHandler?(.partialTranscription(text))
                    self.onPartialResultCallback?(text)
                }
            }
        }

        // Use nil format to let the system choose the best format automatically
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        print("[AppleSpeech] Audio engine started for streaming")
    }

    /// Stop streaming transcription and finalize
    @discardableResult
    public func stopStreamingTranscription() -> String? {
        print("[AppleSpeech] Stopping streaming transcription...")
        recognitionRequest?.endAudio()
        return nil
    }

    /// Cancel streaming transcription without waiting for final result
    public func cancelStreamingTranscription() {
        print("[AppleSpeech] Cancelling streaming transcription...")
        cleanupStreaming()
    }

    /// Cleanup streaming resources
    private func cleanupStreaming() {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        recognitionTask?.cancel()

        recognitionRequest = nil
        audioEngine = nil
        recognitionTask = nil
        onPartialResultCallback = nil
        onFinalResultCallback = nil

        print("[AppleSpeech] Streaming cleanup complete")
    }

    /// Check if streaming is currently active
    public var isStreaming: Bool {
        audioEngine?.isRunning ?? false
    }
}
