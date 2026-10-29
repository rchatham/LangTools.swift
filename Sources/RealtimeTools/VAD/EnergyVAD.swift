//
//  EnergyVAD.swift
//  RealtimeTools
//
//  Created by Reid Chatham on 1/16/26.
//

import Foundation
import LangTools

// MARK: - Energy-Based Voice Activity Detector

/// A lightweight, dependency-free voice activity detector using signal energy
/// and zero-crossing rate with an adaptive noise floor.
///
/// This is the built-in on-device VAD for `RealtimeTools`. It expects
/// 16-bit signed PCM mono audio. For higher accuracy in noisy environments,
/// conform an external model (TEN VAD, Silero VAD via ONNX Runtime, or
/// Picovoice Cobra) to `VoiceActivityDetector` and inject it into the
/// pipeline instead.
public final class EnergyVAD: VoiceActivityDetector, @unchecked Sendable {
    // MARK: - Properties

    public var configuration: VADConfiguration

    /// Sample rate of the incoming PCM audio
    public let sampleRate: Int

    private let lock = NSLock()

    // Adaptive noise floor estimation
    private var noiseFloor: Double = 0.005
    private var noiseFloorInitialized = false

    // Smoothed speech probability to avoid flickering frame decisions
    private var smoothedProbability: Double = 0

    // Running timestamp derived from processed sample counts
    private var processedSamples: Int = 0

    /// How quickly the noise floor adapts during non-speech (0-1, higher = faster)
    private let noiseAdaptationRate: Double

    /// Exponential smoothing factor for the probability output (0-1, higher = more responsive)
    private let probabilitySmoothing: Double

    // MARK: - Initialization

    public init(
        configuration: VADConfiguration = VADConfiguration(mode: .onDevice),
        sampleRate: Int = 16000,
        noiseAdaptationRate: Double = 0.05,
        probabilitySmoothing: Double = 0.35
    ) {
        self.configuration = configuration
        self.sampleRate = sampleRate
        self.noiseAdaptationRate = noiseAdaptationRate
        self.probabilitySmoothing = probabilitySmoothing
    }

    // MARK: - VoiceActivityDetector

    public func process(audio: Data) async -> VADResult {
        lock.lock()
        defer { lock.unlock() }

        let samples = pcm16Samples(from: audio)
        let timestamp = TimeInterval(processedSamples) / TimeInterval(sampleRate)
        processedSamples += samples.count

        guard !samples.isEmpty else {
            return VADResult(isSpeech: false, probability: 0, timestamp: timestamp)
        }

        let energy = rmsEnergy(of: samples)
        let zcr = zeroCrossingRate(of: samples)

        // Initialize the noise floor from the first frames we see
        if !noiseFloorInitialized {
            noiseFloor = max(energy, 0.001)
            noiseFloorInitialized = true
        }

        // Signal-to-noise ratio relative to the adaptive floor
        let snr = energy / max(noiseFloor, 1e-6)

        // Energy score: ramps from 0 at the noise floor to 1 at ~8x the floor.
        // 7.0 (not e.g. 3x or 15x) is an empirically-tuned divisor, not derived
        // from a spec — adjust if false negatives/positives show up in practice.
        let energyScore = min(max((snr - 1.0) / 7.0, 0), 1)

        // Voiced speech typically has a moderate zero-crossing rate; very high
        // ZCR indicates fricative noise or static, very low indicates silence/hum.
        // 0.02/0.35 and the 0.4 partial-credit floor are empirically-tuned
        // heuristic thresholds, not derived from a spec.
        let zcrScore: Double = zcr > 0.02 && zcr < 0.35 ? 1.0 : 0.4

        let rawProbability = energyScore * zcrScore
        smoothedProbability += probabilitySmoothing * (rawProbability - smoothedProbability)

        let isSpeech = smoothedProbability >= configuration.threshold

        // Only adapt the noise floor while we are confident there is no speech,
        // so the floor doesn't learn the user's voice as "noise".
        if !isSpeech {
            noiseFloor += noiseAdaptationRate * (energy - noiseFloor)
            noiseFloor = max(noiseFloor, 0.0005)
        }

        return VADResult(isSpeech: isSpeech, probability: smoothedProbability, timestamp: timestamp)
    }

    public func reset() async {
        lock.lock()
        defer { lock.unlock() }
        noiseFloor = 0.005
        noiseFloorInitialized = false
        smoothedProbability = 0
        processedSamples = 0
    }

    // MARK: - Signal Analysis

    private func pcm16Samples(from data: Data) -> [Int16] {
        let count = data.count / MemoryLayout<Int16>.size
        guard count > 0 else { return [] }
        return data.withUnsafeBytes { rawBuffer in
            Array(rawBuffer.bindMemory(to: Int16.self).prefix(count))
        }
    }

    private func rmsEnergy(of samples: [Int16]) -> Double {
        let sumOfSquares = samples.reduce(0.0) { sum, sample in
            let normalized = Double(sample) / Double(Int16.max)
            return sum + normalized * normalized
        }
        return (sumOfSquares / Double(samples.count)).squareRoot()
    }

    private func zeroCrossingRate(of samples: [Int16]) -> Double {
        guard samples.count > 1 else { return 0 }
        var crossings = 0
        for i in 1..<samples.count where (samples[i] >= 0) != (samples[i - 1] >= 0) {
            crossings += 1
        }
        return Double(crossings) / Double(samples.count - 1)
    }
}
