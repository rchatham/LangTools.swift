//
//  VoiceInputHandlerExample.swift
//  LangTools_Example
//
//  Voice input handler implementation using AppleSpeech module
//

import Foundation
import SwiftUI
import Combine
import Chat
import ChatUI
import Speech
import AVFoundation
import AppleSpeech

/// Example implementation of VoiceInputHandler using AppleSpeech module
@MainActor
public class VoiceInputHandlerExample: ObservableObject, VoiceInputHandler {
    // MARK: - Published Properties

    @Published private var _isRecording: Bool = false
    @Published private var _isProcessing: Bool = false
    @Published private var _audioLevel: Float = 0.0
    @Published private var _statusDescription: String = "Ready"
    @Published public var partialText: String = ""
    @Published public var pendingTranscribedText: String?

    // MARK: - VoiceInputHandler Protocol

    public var isRecording: Bool { _isRecording }
    public var isProcessing: Bool { _isProcessing }
    public var audioLevel: Float { _audioLevel }
    public var statusDescription: String { _statusDescription }
    public var isEnabled: Bool { settings.voiceInputEnabled }
    public var replaceSendButton: Bool { settings.voiceButtonReplaceSend }

    // MARK: - Private Properties

    private let settings: ToolSettings
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var tempFileURL: URL?
    private var transcribedText: String = ""
    private var settingsCancellable: AnyCancellable?

    public static let shared = VoiceInputHandlerExample()

    private init(settings: ToolSettings = .shared) {
        self.settings = settings

        // Forward settings changes to trigger view updates (matches App pattern)
        settingsCancellable = settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
    }

    // MARK: - VoiceInputHandler Methods

    public func toggleRecording() async {
        if _isRecording {
            // Stop recording and transcribe
            await stopRecording()
        } else {
            // Start recording
            await startRecording()
        }
    }

    public func cancelRecording() {
        stopAudioRecording()
        _statusDescription = "Cancelled"
        transcribedText = ""
        partialText = ""
    }

    public func getTranscribedText() -> String? {
        let text = transcribedText
        transcribedText = "" // Clear after retrieval
        return text.isEmpty ? nil : text
    }

    // MARK: - Private Methods

    private func startRecording() async {
        guard !_isRecording && !_isProcessing else { return }

        // Request permissions first
        let authorized = await requestPermissions()
        guard authorized else {
            _statusDescription = "Permissions denied"
            return
        }

        transcribedText = ""
        partialText = ""
        _statusDescription = "Recording..."

        do {
            try startAudioRecording()
        } catch {
            handleRecordingError(error, context: "starting recording")
        }
    }

    private func stopRecording() async {
        guard _isRecording else { return }

        _isProcessing = true
        _statusDescription = "Transcribing..."

        guard let audioData = stopAudioRecording() else {
            _isProcessing = false
            _statusDescription = "No audio data"
            return
        }

        // Transcribe using AppleSpeech module
        do {
            // Convert CAF audio to WAV format
            let wavURL = try convertToWAV(audioData: audioData)

            // Create transcription request
            let request = AppleSpeech.TranscriptionRequest(
                audioURL: wavURL,
                locale: .current,
                reportPartialResults: true,
                taskHint: .unspecified
            )

            // Execute transcription
            let transcript = try await request.execute()

            // Clean up temp file
            try? FileManager.default.removeItem(at: wavURL)

            transcribedText = transcript
            _statusDescription = transcript.isEmpty ? "No speech detected" : "Complete"
            _isProcessing = false
        } catch {
            _isProcessing = false
            handleRecordingError(error, context: "transcribing audio")
        }
    }

    private func requestPermissions() async -> Bool {
        // Request microphone permission (platform-specific)
        let micStatus: Bool
        #if os(iOS)
        micStatus = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        #elseif os(macOS)
        // macOS: Check if permission is granted (no runtime request API)
        // User must manually enable in System Settings > Privacy & Security > Microphone
        micStatus = true  // Assume granted; will fail at audio engine start if denied
        print("[VoiceInputHandlerExample] macOS: Microphone permission must be granted in System Settings")
        #else
        micStatus = false
        #endif

        guard micStatus else {
            #if os(macOS)
            _statusDescription = "Microphone permission required (System Settings)"
            #else
            _statusDescription = "Microphone permission denied"
            #endif
            return false
        }

        // Request speech recognition permission
        let speechStatus = await AppleSpeech.requestAuthorization()
        guard speechStatus == .authorized else {
            _statusDescription = "Speech recognition permission denied"
            return false
        }

        return true
    }

    // MARK: - Audio Recording

    private func startAudioRecording() throws {
        // Configure audio session (platform-specific)
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)
        #elseif os(macOS)
        // macOS: AVAudioSession exists but behaves differently
        // Use default audio input device; no category/mode required
        // Audio engine will use system default microphone
        print("[VoiceInputHandlerExample] macOS: Using default audio input device")
        #endif

        audioEngine = AVAudioEngine()
        guard let audioEngine = audioEngine else {
            throw NSError(domain: "VoiceInput", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio engine"])
        }

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "recording_\(UUID().uuidString).caf"
        let fileURL = tempDir.appendingPathComponent(fileName)
        tempFileURL = fileURL

        audioFile = try AVAudioFile(
            forWriting: fileURL,
            settings: recordingFormat.settings,
            commonFormat: recordingFormat.commonFormat,
            interleaved: recordingFormat.isInterleaved
        )

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] buffer, _ in
            guard let self = self else { return }

            // Calculate audio level
            if let channelData = buffer.floatChannelData?[0] {
                let frameLength = Int(buffer.frameLength)
                var sum: Float = 0
                for i in 0..<frameLength {
                    sum += abs(channelData[i])
                }
                let average = sum / Float(frameLength)

                Task { @MainActor in
                    self._audioLevel = average * 10
                }
            }

            try? self.audioFile?.write(from: buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
        _isRecording = true
    }

    private func stopAudioRecording() -> Data? {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        audioFile = nil

        _isRecording = false
        _audioLevel = 0.0

        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false)
        #endif

        guard let fileURL = tempFileURL else { return nil }

        defer {
            try? FileManager.default.removeItem(at: fileURL)
            tempFileURL = nil
        }

        return try? Data(contentsOf: fileURL)
    }

    private func convertToWAV(audioData: Data) throws -> URL {
        // Write CAF data to temp file
        let tempCAF = FileManager.default.temporaryDirectory
            .appendingPathComponent("convert_\(UUID().uuidString).caf")
        let tempWAV = FileManager.default.temporaryDirectory
            .appendingPathComponent("convert_\(UUID().uuidString).wav")

        try audioData.write(to: tempCAF)
        defer { try? FileManager.default.removeItem(at: tempCAF) }

        // Read CAF and convert to WAV
        let inputFile = try AVAudioFile(forReading: tempCAF)
        let inputFormat = inputFile.processingFormat

        // Validate format compatibility
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw NSError(domain: "VoiceInput", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Invalid audio format: sample rate or channel count is zero"
            ])
        }

        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: AVAudioFrameCount(inputFile.length)
        ) else {
            throw NSError(domain: "VoiceInput", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Could not create audio buffer"
            ])
        }

        try inputFile.read(into: inputBuffer)

        // Use input format's properties for maximum cross-platform compatibility
        // 16-bit integer PCM is more widely compatible than 32-bit float
        let wavSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: inputFormat.sampleRate,  // Use actual rate from recording
            AVNumberOfChannelsKey: inputFormat.channelCount,
            AVLinearPCMBitDepthKey: 16,  // 16-bit is more compatible than 32-bit
            AVLinearPCMIsFloatKey: false,  // Use integer PCM for broader compatibility
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        print("[VoiceInputHandlerExample] Converting audio: \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount) channel(s)")

        let outputFile = try AVAudioFile(
            forWriting: tempWAV,
            settings: wavSettings,
            commonFormat: .pcmFormatInt16,  // Explicitly use 16-bit integer format
            interleaved: true
        )
        try outputFile.write(from: inputBuffer)

        return tempWAV
    }

    // MARK: - Error Handling

    private func handleRecordingError(_ error: Error, context: String) {
        let errorDescription = error.localizedDescription
        print("[VoiceInputHandlerExample] Error \(context): \(error)")

        // Provide platform-specific guidance
        #if os(macOS)
        if errorDescription.contains("microphone") || errorDescription.contains("permission") || errorDescription.contains("1852797029") {
            print("⚠️  macOS: Grant microphone permission in System Settings > Privacy & Security > Microphone")
            _statusDescription = "Microphone permission required (System Settings)"
        } else if errorDescription.contains("audio") || errorDescription.contains("recording") {
            print("⚠️  macOS: Check that microphone is connected and enabled in System Settings > Sound > Input")
            _statusDescription = "Audio error: \(errorDescription)"
        } else {
            _statusDescription = "Error \(context): \(errorDescription)"
        }
        #else
        if errorDescription.contains("permission") {
            _statusDescription = "Permission denied: Check Settings > Privacy"
        } else if errorDescription.contains("audio") || errorDescription.contains("recording") {
            _statusDescription = "Audio error: \(errorDescription)"
        } else {
            _statusDescription = "Error \(context): \(errorDescription)"
        }
        #endif
    }
}
