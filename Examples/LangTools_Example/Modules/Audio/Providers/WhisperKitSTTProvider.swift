//
//  WhisperKitSTTProvider.swift
//  Audio
//
//  WhisperKit-based speech-to-text provider (on-device ML)
//

import Foundation
import AVFoundation
import Chat

#if canImport(WhisperKit)
import WhisperKit
#endif

/// WhisperKit loading state for UI feedback
public enum WhisperKitLoadingState: Equatable {
    case idle
    case downloading
    case loading
    case ready
    case failed(String)

    public var description: String {
        switch self {
        case .idle: return "Not initialized"
        case .downloading: return "Downloading model..."
        case .loading: return "Loading model..."
        case .ready: return "Ready"
        case .failed(let error): return "Failed: \(error)"
        }
    }

    public var isLoading: Bool {
        switch self {
        case .downloading, .loading: return true
        default: return false
        }
    }
}

/// WhisperKit-based speech-to-text provider (on-device ML)
@available(macOS 13, iOS 16, *)
public class WhisperKitSTTProvider: STTProviderProtocol, ObservableObject {
    public let name = "WhisperKit"

    #if canImport(WhisperKit)
    private var whisperKit: WhisperKit?
    private var isInitializing = false
    private var currentModelVariant: String?
    private var audioStreamTranscriber: AudioStreamTranscriber?

    /// Continuation for waiting on final transcription when stopping
    private var finalTranscriptionContinuation: CheckedContinuation<String, Never>?

    /// Last transcribed text (used for timeout fallback)
    private var lastTranscribedText: String = ""

    /// Get the configured model variant from settings
    private var configuredModelVariant: String {
        ToolSettings.shared.whisperKitModelSize.rawValue
    }

    /// Current model state
    public var modelState: String {
        whisperKit?.modelState.description ?? "unloaded"
    }

    /// Published loading state for UI
    @Published public private(set) var loadingState: WhisperKitLoadingState = .idle

    /// Whether currently streaming
    @Published public private(set) var isStreaming: Bool = false
    #else
    @Published public private(set) var loadingState: WhisperKitLoadingState = .failed("WhisperKit not available")
    #endif

    public init() {}

    public var isAvailable: Bool {
        #if canImport(WhisperKit)
        guard let whisperKit = whisperKit else { return false }
        return whisperKit.modelState == .loaded || whisperKit.modelState == .prewarmed
        #else
        return false
        #endif
    }

    public func requestPermission() async throws -> Bool {
        #if canImport(WhisperKit)
        // Initialize WhisperKit and download model if needed
        if whisperKit == nil && !isInitializing {
            try await initializeWhisperKit()
        }
        return isAvailable
        #else
        throw STTError.notAvailable
        #endif
    }

    public func transcribe(audioData: Data) async throws -> String {
        #if canImport(WhisperKit)
        print("[WhisperKit] Received audio data: \(audioData.count) bytes")

        // Ensure WhisperKit is initialized
        if whisperKit == nil {
            print("[WhisperKit] Initializing WhisperKit...")
            do {
                try await initializeWhisperKit()
            } catch {
                print("[WhisperKit] Initialization failed: \(error)")
                throw error
            }
        }

        guard let whisperKit = whisperKit, isAvailable else {
            let reason = whisperKit == nil ? "not initialized" : "model state: \(modelState)"
            print("[WhisperKit] Provider not available - \(reason)")
            throw STTError.providerNotConfigured
        }

        print("[WhisperKit] Model state: \(modelState)")

        // Run heavy audio processing and transcription on background thread
        return try await Task.detached(priority: .userInitiated) {
            // Convert CAF audio to WAV format for WhisperKit
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("whisper_\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: tempURL) }

            do {
                try AudioConverter.convertToWAV(cafData: audioData, outputURL: tempURL)
                print("[WhisperKit] Converted to WAV: \(try Data(contentsOf: tempURL).count) bytes")
            } catch {
                print("[WhisperKit] Audio conversion failed: \(error)")
                throw STTError.transcriptionFailed("Audio conversion failed: \(error.localizedDescription)")
            }

            // Perform transcription
            print("[WhisperKit] Starting transcription...")
            do {
                // Get language setting
                let languageSetting = await MainActor.run { ToolSettings.shared.sttLanguage.rawValue }

                // Configure decoding options with language
                var decodingOptions = DecodingOptions()
                if languageSetting == "auto" {
                    decodingOptions.detectLanguage = true
                } else {
                    decodingOptions.language = languageSetting
                }

                // WhisperKit uses audioPaths (array) not audioPath (singular)
                let resultsArray = await whisperKit.transcribe(
                    audioPaths: [tempURL.path],
                    decodeOptions: decodingOptions
                )

                // Result is [[TranscriptionResult]?] - nested optional array
                guard let firstResult = resultsArray.first, let transcriptionResults = firstResult else {
                    print("[WhisperKit] No transcription results returned")
                    throw STTError.transcriptionFailed("No transcription results")
                }

                let transcribedText = transcriptionResults.map { $0.text }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)

                print("[WhisperKit] Transcription complete: '\(transcribedText)'")

                if transcribedText.isEmpty {
                    throw STTError.transcriptionFailed("No speech detected")
                }

                return transcribedText
            } catch let error as STTError {
                throw error
            } catch let error as WhisperError {
                print("[WhisperKit] WhisperKit error: \(error)")
                throw STTError.transcriptionFailed("WhisperKit error: \(error.localizedDescription)")
            } catch let error as NSError {
                print("[WhisperKit] NSError - domain: \(error.domain), code: \(error.code), desc: \(error.localizedDescription)")
                throw STTError.transcriptionFailed("WhisperKit: \(error.localizedDescription)")
            } catch {
                print("[WhisperKit] Transcription error: \(type(of: error)), \(error)")
                throw STTError.transcriptionFailed(error.localizedDescription)
            }
        }.value
        #else
        print("[WhisperKit] WhisperKit not available on this platform")
        throw STTError.notAvailable
        #endif
    }

    /// Preload WhisperKit model (call this when user selects WhisperKit in settings)
    public func preload() {
        #if canImport(WhisperKit)
        guard whisperKit == nil && !isInitializing else { return }

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try await self?.initializeWhisperKit()
            } catch {
                print("[WhisperKit] Preload failed: \(error)")
            }
        }
        #endif
    }

    #if canImport(WhisperKit)
    /// Initialize WhisperKit with the configured model
    private func initializeWhisperKit() async throws {
        let modelVariant = await MainActor.run { configuredModelVariant }

        // Check if we need to reload due to model change
        if whisperKit != nil && currentModelVariant != modelVariant {
            print("[WhisperKit] Model changed from \(currentModelVariant ?? "none") to \(modelVariant), reinitializing...")
            whisperKit = nil
        }

        guard !isInitializing else { return }
        isInitializing = true
        defer { isInitializing = false }

        // Check if model needs to be downloaded
        let needsDownload = !isModelDownloaded(modelVariant)

        await MainActor.run {
            loadingState = needsDownload ? .downloading : .loading
        }

        do {
            let config = WhisperKitConfig(
                model: modelVariant,
                verbose: false,
                prewarm: true,
                download: true
            )

            do {
                whisperKit = try await WhisperKit(config)
            } catch {
                // Prewarm can fail on some devices - retry without prewarm
                print("[WhisperKit] Prewarm failed, retrying without prewarm: \(error)")
                let configNoPrewarm = WhisperKitConfig(
                    model: modelVariant,
                    verbose: false,
                    prewarm: false,
                    download: true
                )
                whisperKit = try await WhisperKit(configNoPrewarm)
            }

            // After prewarm, models are nil - must reload them
            if whisperKit?.modelState == .prewarmed {
                print("[WhisperKit] Models are prewarmed but nil, reloading...")
                try await whisperKit?.loadModels()
            }

            currentModelVariant = modelVariant

            await MainActor.run {
                loadingState = .ready
            }
            print("[WhisperKit] Initialized with model: \(modelVariant), state: \(whisperKit?.modelState.description ?? "unknown")")
        } catch let error as NSError {
            await MainActor.run {
                loadingState = .failed(error.localizedDescription)
            }
            print("[WhisperKit] Initialization NSError - domain: \(error.domain), code: \(error.code), desc: \(error.localizedDescription)")
            throw STTError.transcriptionFailed("WhisperKit initialization failed: \(error.localizedDescription)")
        } catch {
            await MainActor.run {
                loadingState = .failed(error.localizedDescription)
            }
            print("[WhisperKit] Initialization error: \(type(of: error)), \(error)")
            throw STTError.transcriptionFailed("WhisperKit initialization failed: \(error.localizedDescription)")
        }
    }

    /// Reload WhisperKit with the current settings (call when model size changes)
    public func reloadIfNeeded() async throws {
        let modelVariant = await MainActor.run { configuredModelVariant }
        if currentModelVariant != modelVariant {
            try await initializeWhisperKit()
        }
    }

    /// Strip Whisper special tokens from transcription text
    private func stripSpecialTokens(_ text: String) -> String {
        let pattern = "<\\|[^|]+\\|>"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Start streaming transcription with real-time partial results
    public func startStreamingTranscription(
        onPartialResult: @escaping (String, Bool) -> Void
    ) async throws {
        // Ensure WhisperKit is initialized
        if whisperKit == nil {
            try await initializeWhisperKit()
        }

        guard let whisperKit = whisperKit, isAvailable else {
            throw STTError.providerNotConfigured
        }

        // Ensure all required components are available
        guard let tokenizer = whisperKit.tokenizer else {
            throw STTError.providerNotConfigured
        }

        // Get decoding options from settings
        let languageSetting = await MainActor.run { ToolSettings.shared.sttLanguage.rawValue }
        var decodingOptions = DecodingOptions()
        if languageSetting == "auto" {
            decodingOptions.detectLanguage = true
        } else {
            decodingOptions.language = languageSetting
        }

        // Create the stream transcriber with state callback
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
            guard let self = self else { return }

            // Combine confirmed + unconfirmed segments for full text
            let confirmedText = newState.confirmedSegments.map { self.stripSpecialTokens($0.text) }.joined(separator: " ")
            let unconfirmedText = newState.unconfirmedSegments.map { self.stripSpecialTokens($0.text) }.joined(separator: " ")
            let fullText = (confirmedText + " " + unconfirmedText).trimmingCharacters(in: .whitespacesAndNewlines)

            // Store latest text for timeout fallback
            if !fullText.isEmpty {
                self.lastTranscribedText = fullText
            }

            // Determine if this is final (recording stopped)
            let isFinal = !newState.isRecording && oldState.isRecording

            let oldFullText = (oldState.confirmedSegments.map { self.stripSpecialTokens($0.text) } + oldState.unconfirmedSegments.map { self.stripSpecialTokens($0.text) }).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)

            // Only log and send callback when text actually changes (or is final)
            if !fullText.isEmpty && (fullText != oldFullText || isFinal) {
                onPartialResult(fullText, isFinal)
            }

            if isFinal {
                // Resume continuation with final text (if waiting)
                if let continuation = self.finalTranscriptionContinuation {
                    self.finalTranscriptionContinuation = nil
                    print("[WhisperKit] Resuming continuation with final text: '\(fullText)'")
                    continuation.resume(returning: fullText)
                }

                Task { @MainActor [weak self] in
                    self?.isStreaming = false
                }
            }
        }

        await MainActor.run {
            isStreaming = true
        }

        print("[WhisperKit] Starting streaming transcription...")
        try await audioStreamTranscriber?.startStreamTranscription()
    }

    /// Stop streaming transcription and return final text
    public func stopStreamingTranscription() async -> String {
        print("[WhisperKit] Stopping streaming transcription...")

        guard isStreaming else {
            print("[WhisperKit] Not streaming, returning last text: '\(lastTranscribedText)'")
            return lastTranscribedText
        }

        // Use continuation to wait for final callback
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            self.finalTranscriptionContinuation = continuation

            // Stop the transcriber (will trigger isFinal callback)
            let transcriber = audioStreamTranscriber
            Task.detached {
                await transcriber?.stopStreamTranscription()
            }

            // Timeout fallback after 2 seconds
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if let cont = self.finalTranscriptionContinuation {
                    self.finalTranscriptionContinuation = nil
                    print("[WhisperKit] Timeout - returning last text: '\(self.lastTranscribedText)'")
                    cont.resume(returning: self.lastTranscribedText)
                }
            }
        }

        await MainActor.run {
            isStreaming = false
        }

        // Clear for next session
        lastTranscribedText = ""

        print("[WhisperKit] Final transcription: '\(result)'")
        return result
    }
    #endif

    /// Download a WhisperKit model
    public func downloadModel(_ modelName: String) async throws {
        #if canImport(WhisperKit)
        do {
            _ = try await WhisperKit.download(variant: modelName)
        } catch {
            throw STTError.transcriptionFailed("Model download failed: \(error.localizedDescription)")
        }
        #else
        throw STTError.notAvailable
        #endif
    }

    /// Check if a model is downloaded locally
    public func isModelDownloaded(_ modelName: String) -> Bool {
        #if canImport(WhisperKit)
        let modelFolder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("huggingface")
            .appendingPathComponent("models")
            .appendingPathComponent("argmaxinc")
            .appendingPathComponent("whisperkit-coreml")
            .appendingPathComponent("openai_whisper-\(modelName)")

        if let folder = modelFolder {
            return FileManager.default.fileExists(atPath: folder.path)
        }
        return false
        #else
        return false
        #endif
    }

    /// Get list of available models
    public static var availableModels: [String] {
        ["tiny", "base", "small", "medium", "large-v3"]
    }

    /// Get recommended model for current device
    public static func recommendedModel() async -> String {
        #if canImport(WhisperKit)
        let support = WhisperKit.recommendedModels()
        return support.default
        #else
        return "base"
        #endif
    }
}
