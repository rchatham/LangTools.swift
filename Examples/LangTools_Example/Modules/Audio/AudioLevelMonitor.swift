//
//  AudioLevelMonitor.swift
//  LangTools_Example
//
//  Monitors audio input levels for UI visualization.
//  Separate from STT processing - only calculates levels for display.
//

import Foundation
import AVFoundation

/// Monitors audio input levels for UI visualization
///
/// This service creates a single AVAudioEngine tap dedicated to measuring
/// audio amplitude for visual feedback (waveforms, microphone button pulse).
/// It is intentionally separate from transcription to maintain clean separation
/// of concerns - STTService handles transcription, AudioLevelMonitor handles UI.
///
/// Usage:
/// ```swift
/// let monitor = AudioLevelMonitor()
/// monitor.start()  // Begin monitoring
/// // Observe monitor.audioLevel for UI updates
/// monitor.stop()   // Stop monitoring
/// ```
@MainActor
public class AudioLevelMonitor: ObservableObject {
    /// Current audio level (0.0 to 1.0, clamped)
    @Published public private(set) var audioLevel: Float = 0.0

    private var audioEngine: AVAudioEngine?
    private var isMonitoring = false

    public init() {}

    /// Start monitoring audio levels
    ///
    /// Creates an AVAudioEngine with an input tap that samples audio amplitude.
    /// The audio level is calculated as: `min(1.0, averageAbsoluteAmplitude * 10)`
    public func start() {
        guard !isMonitoring else { return }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<frameLength {
                sum += abs(channelData[i])
            }
            let average = sum / Float(frameLength)
            Task { @MainActor in
                // Clamp to 0.0-1.0 range for consistent UI behavior
                self?.audioLevel = min(1.0, average * 10)
            }
        }

        do {
            try engine.start()
            audioEngine = engine
            isMonitoring = true
            print("[AudioLevelMonitor] Started")
        } catch {
            print("[AudioLevelMonitor] Failed to start: \(error)")
        }
    }

    /// Stop monitoring audio levels
    ///
    /// Removes the input tap, stops the engine, and resets audio level to 0.
    public func stop() {
        guard isMonitoring else { return }

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        audioLevel = 0.0
        isMonitoring = false
        print("[AudioLevelMonitor] Stopped")
    }
}
