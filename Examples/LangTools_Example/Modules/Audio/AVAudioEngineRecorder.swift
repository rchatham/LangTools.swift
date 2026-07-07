//
//  AVAudioEngineRecorder.swift
//  LangTools_Example
//
//  Created by Reid Chatham on 12/2/24.
//

import Foundation
import AVFoundation

#if os(iOS)
import UIKit
#endif

/// Handles audio recording using AVAudioEngine
/// Records in native format (no conversion) to avoid format mismatch issues
///
/// This is a reusable audio recording utility that can be integrated into any app.
/// It provides:
/// - Real-time audio level monitoring for UI feedback
/// - Silence detection with configurable timeout
/// - Support for chunked audio data extraction during recording
/// - Proper audio session management for iOS
@MainActor
public class AVAudioEngineRecorder: ObservableObject {
    @Published public private(set) var isRecording: Bool = false
    @Published public private(set) var audioLevel: Float = 0.0
    @Published public private(set) var silenceDetected: Bool = false

    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var tempFileURL: URL?

    // Silence detection
    private var silenceStartTime: Date?
    private var silenceThreshold: Float = 0.01  // Audio level below this is considered silence
    public var silenceTimeoutSeconds: Double = 2.0  // Configurable timeout
    public var autoStopOnSilenceEnabled: Bool = false

    /// Callback when silence timeout is reached
    public var onSilenceTimeout: (() -> Void)?

    public init() {}

    /// Request microphone permission
    public func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    /// Check if microphone permission is granted
    public var hasPermission: Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }

    /// Start recording audio
    /// - Throws: AudioRecorderError if recording fails to start
    public func startRecording() throws {
        guard !isRecording else { return }

        // Configure audio session
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)
        #endif

        // Create audio engine
        audioEngine = AVAudioEngine()
        guard let audioEngine = audioEngine else {
            throw AudioRecorderError.engineCreationFailed
        }

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        // Validate format
        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            throw AudioRecorderError.invalidFormat(
                sampleRate: recordingFormat.sampleRate,
                channels: recordingFormat.channelCount
            )
        }

        // Create temp file - use .caf which supports any PCM format
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "recording_\(UUID().uuidString).caf"
        let fileURL = tempDir.appendingPathComponent(fileName)
        tempFileURL = fileURL

        // Create audio file matching the input format exactly
        // This avoids any format conversion issues
        audioFile = try AVAudioFile(
            forWriting: fileURL,
            settings: recordingFormat.settings,
            commonFormat: recordingFormat.commonFormat,
            interleaved: recordingFormat.isInterleaved
        )

        // Install tap - write directly without conversion
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] buffer, _ in
            guard let self = self else { return }

            // Calculate audio level for UI feedback
            if let channelData = buffer.floatChannelData?[0] {
                let frameLength = Int(buffer.frameLength)
                var sum: Float = 0
                for i in 0..<frameLength {
                    sum += abs(channelData[i])
                }
                let average = sum / Float(frameLength)
                let scaledLevel = average * 10 // Scale for visibility

                Task { @MainActor in
                    self.audioLevel = scaledLevel
                    self.checkSilence(level: scaledLevel)
                }
            }

            // Write directly to file (AVAudioFile is thread-safe for sequential writes)
            do {
                try self.audioFile?.write(from: buffer)
            } catch {
                print("Error writing audio: \(error)")
            }
        }

        // Start the engine
        audioEngine.prepare()
        try audioEngine.start()

        // Reset silence detection state
        silenceStartTime = nil
        silenceDetected = false

        isRecording = true
    }

    /// Check for silence and trigger callback if timeout reached
    private func checkSilence(level: Float) {
        guard autoStopOnSilenceEnabled && isRecording else {
            silenceStartTime = nil
            return
        }

        if level < silenceThreshold {
            // Audio is silent
            if silenceStartTime == nil {
                silenceStartTime = Date()
            } else if let startTime = silenceStartTime {
                let silenceDuration = Date().timeIntervalSince(startTime)
                if silenceDuration >= silenceTimeoutSeconds && !silenceDetected {
                    silenceDetected = true
                    print("[AVAudioEngineRecorder] Silence timeout reached after \(silenceDuration)s")
                    onSilenceTimeout?()
                }
            }
        } else {
            // Audio is not silent, reset timer
            silenceStartTime = nil
            silenceDetected = false
        }
    }

    /// Get current accumulated audio data without stopping recording
    /// Used for chunked streaming transcription
    public func getCurrentAudioData() -> Data? {
        guard isRecording, let fileURL = tempFileURL else { return nil }
        // Read the current file contents
        return try? Data(contentsOf: fileURL)
    }

    /// Stop recording and return the audio data
    public func stopRecording() -> Data? {
        guard isRecording else { return nil }

        // Stop and clean up
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        audioFile = nil  // Close the file

        isRecording = false
        audioLevel = 0.0

        // Deactivate audio session
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false)
        #endif

        // Read the recorded file
        guard let fileURL = tempFileURL else { return nil }

        defer {
            // Clean up temp file
            try? FileManager.default.removeItem(at: fileURL)
            tempFileURL = nil
        }

        return try? Data(contentsOf: fileURL)
    }

    /// Cancel recording without returning data
    public func cancelRecording() {
        guard isRecording else { return }

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        audioFile = nil

        isRecording = false
        audioLevel = 0.0

        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false)
        #endif

        // Clean up temp file
        if let fileURL = tempFileURL {
            try? FileManager.default.removeItem(at: fileURL)
            tempFileURL = nil
        }
    }
}

// MARK: - Error Types

/// Errors that can occur during audio recording
public enum AudioRecorderError: Error, LocalizedError {
    case engineCreationFailed
    case invalidFormat(sampleRate: Double, channels: UInt32)
    case recordingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .engineCreationFailed:
            return "Failed to create audio engine"
        case .invalidFormat(let sampleRate, let channels):
            return "Invalid input format: sampleRate=\(sampleRate), channels=\(channels)"
        case .recordingFailed(let reason):
            return "Recording failed: \(reason)"
        }
    }
}
