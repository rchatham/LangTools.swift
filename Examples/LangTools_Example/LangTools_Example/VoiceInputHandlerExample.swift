//
//  VoiceInputHandlerExample.swift
//  LangTools_Example
//
//  Voice input handler implementation using AppleSpeech module
//

import Foundation
import SwiftUI
import Combine
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
    public var isEnabled: Bool { true } // Always enabled in example
    public var replaceSendButton: Bool { false } // Show both buttons

    // MARK: - Private Properties

    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var tempFileURL: URL?
    private var transcribedText: String = ""

    public static let shared = VoiceInputHandlerExample()

    private init() {}

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
            _statusDescription = "Failed to start recording"
            print("[VoiceInputHandlerExample] Error starting recording: \(error)")
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
            _statusDescription = error.localizedDescription
            _isProcessing = false
            print("[VoiceInputHandlerExample] Transcription error: \(error)")
        }
    }

    private func requestPermissions() async -> Bool {
        // Request microphone permission
        let micStatus = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }

        guard micStatus else { return false }

        // Request speech recognition permission
        let speechStatus = await AppleSpeech.requestAuthorization()
        return speechStatus == .authorized
    }

    // MARK: - Audio Recording

    private func startAudioRecording() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)
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
        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFile.processingFormat,
            frameCapacity: AVAudioFrameCount(inputFile.length)
        ) else {
            throw NSError(domain: "VoiceInput", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not create audio buffer"])
        }

        try inputFile.read(into: inputBuffer)

        // Create WAV file with same format
        let wavSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: inputFile.processingFormat.sampleRate,
            AVNumberOfChannelsKey: inputFile.processingFormat.channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let outputFile = try AVAudioFile(
            forWriting: tempWAV,
            settings: wavSettings,
            commonFormat: inputFile.processingFormat.commonFormat,
            interleaved: inputFile.processingFormat.isInterleaved
        )
        try outputFile.write(from: inputBuffer)

        return tempWAV
    }
}
