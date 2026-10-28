//
//  RealtimeAudio.swift
//  LangTools_Example
//
//  Streaming audio I/O for the realtime voice interface:
//  - RealtimeMicStreamer: captures mic input and emits PCM16 24kHz mono chunks
//    (the OpenAI Realtime API input format)
//  - RealtimePCMPlayer: plays PCM16 24kHz mono chunks as they stream in, with
//    immediate flush for interruption/barge-in
//

import Foundation
import AVFoundation

// MARK: - Mic Streamer

/// Captures microphone audio with AVAudioEngine and converts it on the fly to
/// 16-bit PCM, 24kHz, mono — the format expected by `input_audio_buffer.append`.
@MainActor
public final class RealtimeMicStreamer: ObservableObject {
    @Published public private(set) var isStreaming = false
    @Published public private(set) var audioLevel: Float = 0

    /// Receives converted PCM16 chunks (~100ms each). Called off the main thread.
    public var onAudioChunk: (@Sendable (Data) -> Void)?

    private var audioEngine: AVAudioEngine?
    private var converter: AVAudioConverter?

    public static let targetSampleRate: Double = 24000

    public init() {}

    public func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    public func start() throws {
        guard !isStreaming else { return }

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)
        #endif

        let engine = AVAudioEngine()
        audioEngine = engine

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RealtimeAudioError.invalidInputFormat
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: true
        ), let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw RealtimeAudioError.converterSetupFailed
        }
        self.converter = converter

        inputNode.installTap(onBus: 0, bufferSize: 2400, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }

            // Level metering for the UI
            if let channelData = buffer.floatChannelData?[0] {
                let frameLength = Int(buffer.frameLength)
                var sum: Float = 0
                for i in 0..<frameLength { sum += abs(channelData[i]) }
                let level = min((sum / Float(max(frameLength, 1))) * 10, 1.0)
                Task { @MainActor in self.audioLevel = level }
            }

            // Convert to PCM16 24kHz mono and hand off
            let ratio = targetFormat.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

            var consumed = false
            var conversionError: NSError?
            converter.convert(to: outBuffer, error: &conversionError) { _, outStatus in
                if consumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return buffer
            }
            guard conversionError == nil, outBuffer.frameLength > 0,
                  let int16Data = outBuffer.int16ChannelData else { return }

            let data = Data(bytes: int16Data[0], count: Int(outBuffer.frameLength) * MemoryLayout<Int16>.size)
            self.onAudioChunk?(data)
        }

        engine.prepare()
        try engine.start()
        isStreaming = true
    }

    public func stop() {
        guard isStreaming else { return }
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        converter = nil
        isStreaming = false
        audioLevel = 0
    }
}

// MARK: - Streaming PCM Player

/// Plays 16-bit PCM 24kHz mono audio chunks (the OpenAI Realtime output
/// format) as they stream in, using AVAudioPlayerNode. `flush()` drops all
/// queued audio immediately, which is what a barge-in interruption needs.
@MainActor
public final class RealtimePCMPlayer: ObservableObject {
    @Published public private(set) var isPlaying = false

    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var format: AVAudioFormat?
    private var pendingBuffers = 0
    private var playedFrames = 0
    /// Bumped by flush()/stop() so completion callbacks for buffers that were
    /// dropped (AVAudioPlayerNode still calls them on stop) are ignored.
    private var generation = 0

    public static let sampleRate: Double = 24000

    /// Milliseconds of audio actually played since the last
    /// `resetPlaybackPosition()` or `flush()`. Use this, not the amount
    /// received, as the truncation point on barge-in.
    public var playedMilliseconds: Int {
        playedFrames * 1000 / Int(Self.sampleRate)
    }

    /// Start counting played audio from zero, e.g. when a new response item begins.
    public func resetPlaybackPosition() {
        playedFrames = 0
    }

    public init() {}

    public func start() throws {
        guard engine == nil else { return }

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: false
        ) else { throw RealtimeAudioError.converterSetupFailed }
        self.format = format

        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
        node.play()

        self.engine = engine
        self.playerNode = node
    }

    public func stop() {
        generation += 1
        playerNode?.stop()
        engine?.stop()
        playerNode = nil
        engine = nil
        format = nil
        pendingBuffers = 0
        playedFrames = 0
        isPlaying = false
    }

    /// Enqueue a chunk of PCM16 24kHz mono audio for playback.
    public func enqueue(pcm16 data: Data) {
        guard let playerNode, let format else { return }

        let frameCount = data.count / MemoryLayout<Int16>.size
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else { return }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        // Convert Int16 samples to Float32 for the mixer
        data.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) in
            let samples = rawBuffer.bindMemory(to: Int16.self)
            guard let channel = buffer.floatChannelData?[0] else { return }
            for i in 0..<frameCount {
                // Divide by 32768 so -32768 maps to exactly -1.0.
                channel[i] = Float(samples[i]) / 32768
            }
        }

        pendingBuffers += 1
        isPlaying = true
        let bufferGeneration = generation
        playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, bufferGeneration == self.generation else { return }
                self.playedFrames += frameCount
                self.pendingBuffers = max(0, self.pendingBuffers - 1)
                if self.pendingBuffers == 0 { self.isPlaying = false }
            }
        }
    }

    /// Immediately drop all queued audio (barge-in interruption).
    public func flush() {
        generation += 1
        playerNode?.stop()
        pendingBuffers = 0
        playedFrames = 0
        isPlaying = false
        playerNode?.play()
    }
}

// MARK: - Errors

public enum RealtimeAudioError: Error, LocalizedError {
    case invalidInputFormat
    case converterSetupFailed
    case permissionDenied

    public var errorDescription: String? {
        switch self {
        case .invalidInputFormat: return "Microphone input format is invalid"
        case .converterSetupFailed: return "Failed to set up audio converter"
        case .permissionDenied: return "Microphone permission denied"
        }
    }
}
