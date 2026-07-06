//
//  InterruptionDetectionTests.swift
//  LangTools
//
//  Created by Reid Chatham on 1/16/26.
//

import XCTest
@testable import RealtimeTools
@testable import LangTools

// MARK: - Test Helpers

/// Deterministic VAD stub that returns scripted results, so the
/// InterruptionDetector state machine can be tested without real audio.
private final class ScriptedVAD: VoiceActivityDetector, @unchecked Sendable {
    var configuration: VADConfiguration
    var resetCount = 0

    init(configuration: VADConfiguration = VADConfiguration()) {
        self.configuration = configuration
    }

    func process(audio: Data) async -> VADResult {
        VADResult(isSpeech: false, probability: 0, timestamp: 0)
    }

    func reset() async {
        resetCount += 1
    }
}

/// Generates PCM16 test audio
private enum TestAudio {
    static func silence(samples: Int) -> Data {
        Data(count: samples * 2)
    }

    static func tone(samples: Int, amplitude: Double = 0.5, frequency: Double = 200, sampleRate: Double = 16000) -> Data {
        var data = Data(capacity: samples * 2)
        for i in 0..<samples {
            let value = amplitude * sin(2.0 * .pi * frequency * Double(i) / sampleRate)
            var sample = Int16(value * Double(Int16.max))
            withUnsafeBytes(of: &sample) { data.append(contentsOf: $0) }
        }
        return data
    }
}

// MARK: - EnergyVAD Tests

final class EnergyVADTests: XCTestCase {

    func testSilenceIsNotSpeech() async {
        let vad = EnergyVAD()
        // Feed several frames of silence (20ms frames at 16kHz = 320 samples)
        for _ in 0..<10 {
            let result = await vad.process(audio: TestAudio.silence(samples: 320))
            XCTAssertFalse(result.isSpeech)
        }
    }

    func testLoudToneAfterSilenceIsSpeech() async {
        let vad = EnergyVAD()
        // Establish a noise floor with silence
        for _ in 0..<10 {
            _ = await vad.process(audio: TestAudio.silence(samples: 320))
        }
        // A loud 200Hz tone has speech-like energy and ZCR
        var sawSpeech = false
        for _ in 0..<10 {
            let result = await vad.process(audio: TestAudio.tone(samples: 320))
            if result.isSpeech { sawSpeech = true }
        }
        XCTAssertTrue(sawSpeech, "Expected loud tone frames to be classified as speech")
    }

    func testEmptyAudioReturnsNoSpeech() async {
        let vad = EnergyVAD()
        let result = await vad.process(audio: Data())
        XCTAssertFalse(result.isSpeech)
        XCTAssertEqual(result.probability, 0)
    }

    func testTimestampAdvancesWithSamples() async {
        let vad = EnergyVAD(sampleRate: 16000)
        let first = await vad.process(audio: TestAudio.silence(samples: 16000)) // 1 second
        XCTAssertEqual(first.timestamp, 0, accuracy: 0.001)
        let second = await vad.process(audio: TestAudio.silence(samples: 320))
        XCTAssertEqual(second.timestamp, 1.0, accuracy: 0.001)
    }

    func testResetClearsState() async {
        let vad = EnergyVAD()
        _ = await vad.process(audio: TestAudio.tone(samples: 320))
        await vad.reset()
        let result = await vad.process(audio: TestAudio.silence(samples: 320))
        XCTAssertEqual(result.timestamp, 0, accuracy: 0.001)
    }
}

// MARK: - InterruptionDetector Tests

final class InterruptionDetectorTests: XCTestCase {

    /// Builds a detector with fast thresholds and a captured event list
    private func makeDetector(
        minPlaybackBeforeInterrupt: TimeInterval = 0.5
    ) -> (InterruptionDetector, () -> [InterruptionEvent]) {
        let vadConfig = VADConfiguration(minSpeechDuration: 0.1, silenceTimeout: 0.3)
        let vad = ScriptedVAD(configuration: vadConfig)
        let detector = InterruptionDetector(
            vad: vad,
            configuration: InterruptionConfiguration(
                enabled: true,
                mode: .immediate,
                minPlaybackBeforeInterrupt: minPlaybackBeforeInterrupt,
                speechDetectionDebounce: 0.1
            )
        )
        let lock = NSLock()
        var events: [InterruptionEvent] = []
        detector.onEvent = { event in
            lock.lock(); events.append(event); lock.unlock()
        }
        return (detector, { lock.lock(); defer { lock.unlock() }; return events })
    }

    private func speech(at t: TimeInterval) -> VADResult {
        VADResult(isSpeech: true, probability: 0.9, timestamp: t)
    }

    private func silence(at t: TimeInterval) -> VADResult {
        VADResult(isSpeech: false, probability: 0.1, timestamp: t)
    }

    func testSpeechStartedAfterDebounce() {
        let (detector, events) = makeDetector()

        detector.handle(result: speech(at: 0.00))  // candidate
        XCTAssertTrue(events().isEmpty, "Should not fire before debounce window")
        detector.handle(result: speech(at: 0.05))
        XCTAssertTrue(events().isEmpty)
        detector.handle(result: speech(at: 0.15))  // past 0.1s debounce

        guard case .speechStarted(let timestamp)? = events().first else {
            return XCTFail("Expected speechStarted, got \(events())")
        }
        XCTAssertEqual(timestamp, 0.0, accuracy: 0.001)
    }

    func testShortNoiseBlipIsDiscarded() {
        let (detector, events) = makeDetector()

        detector.handle(result: speech(at: 0.00))
        detector.handle(result: silence(at: 0.05)) // blip shorter than debounce
        detector.handle(result: silence(at: 0.50))

        XCTAssertTrue(events().isEmpty, "A blip shorter than the debounce window should emit no events")
    }

    func testSpeechEndedAfterSilenceTimeout() {
        let (detector, events) = makeDetector()

        detector.handle(result: speech(at: 0.00))
        detector.handle(result: speech(at: 0.15))   // speechStarted
        detector.handle(result: silence(at: 0.20))  // trailing silence begins
        detector.handle(result: silence(at: 0.40))  // 0.2s silence — under 0.3s timeout
        XCTAssertEqual(events().count, 1)
        detector.handle(result: silence(at: 0.55))  // 0.35s silence — past timeout

        guard case .speechEnded(_, let duration)? = events().last else {
            return XCTFail("Expected speechEnded, got \(events())")
        }
        XCTAssertEqual(duration, 0.20, accuracy: 0.001)
    }

    func testResumedSpeechWithinTimeoutIsSameUtterance() {
        let (detector, events) = makeDetector()

        detector.handle(result: speech(at: 0.00))
        detector.handle(result: speech(at: 0.15))   // speechStarted
        detector.handle(result: silence(at: 0.20))
        detector.handle(result: speech(at: 0.35))   // resumes before 0.3s timeout
        detector.handle(result: silence(at: 0.40))
        detector.handle(result: silence(at: 0.80))  // now past timeout — speechEnded

        let captured = events()
        XCTAssertEqual(captured.count, 2, "Expected exactly speechStarted + speechEnded, got \(captured)")
    }

    func testInterruptionFiresDuringPlayback() {
        let (detector, events) = makeDetector(minPlaybackBeforeInterrupt: 0.5)

        detector.playbackStarted(at: 0.0)
        detector.handle(result: speech(at: 1.00))
        detector.handle(result: speech(at: 1.15))   // committed speech during playback

        let captured = events()
        XCTAssertEqual(captured.count, 2)
        guard case .interruptionDetected? = captured.last else {
            return XCTFail("Expected interruptionDetected, got \(captured)")
        }
    }

    func testNoInterruptionWithinPlaybackGracePeriod() {
        let (detector, events) = makeDetector(minPlaybackBeforeInterrupt: 0.5)

        detector.playbackStarted(at: 0.0)
        detector.handle(result: speech(at: 0.10))
        detector.handle(result: speech(at: 0.25))   // speech commits at 0.25s < 0.5s grace

        let captured = events()
        XCTAssertEqual(captured.count, 1, "Expected only speechStarted within the grace period, got \(captured)")
        guard case .speechStarted? = captured.first else {
            return XCTFail("Expected speechStarted, got \(captured)")
        }
    }

    func testNoInterruptionWithoutPlayback() {
        let (detector, events) = makeDetector()

        detector.handle(result: speech(at: 0.00))
        detector.handle(result: speech(at: 0.15))

        let captured = events()
        XCTAssertEqual(captured.count, 1)
        guard case .speechStarted? = captured.first else {
            return XCTFail("Expected only speechStarted, got \(captured)")
        }
    }

    func testInterruptionFiresOncePerUtterance() {
        let (detector, events) = makeDetector(minPlaybackBeforeInterrupt: 0.0)

        detector.playbackStarted(at: 0.0)
        detector.handle(result: speech(at: 1.00))
        detector.handle(result: speech(at: 1.15))   // speechStarted + interruption
        detector.handle(result: speech(at: 1.30))   // continued speech — no second interruption

        let interruptions = events().filter { if case .interruptionDetected = $0 { return true }; return false }
        XCTAssertEqual(interruptions.count, 1)
    }

    func testPlaybackStoppedDisarmsInterruption() {
        let (detector, events) = makeDetector(minPlaybackBeforeInterrupt: 0.0)

        detector.playbackStarted(at: 0.0)
        detector.playbackStopped()
        detector.handle(result: speech(at: 1.00))
        detector.handle(result: speech(at: 1.15))

        let interruptions = events().filter { if case .interruptionDetected = $0 { return true }; return false }
        XCTAssertTrue(interruptions.isEmpty, "No interruption should fire after playback stopped")
    }

    func testResetClearsDetectorAndVAD() async {
        let vad = ScriptedVAD()
        let detector = InterruptionDetector(vad: vad)
        detector.playbackStarted()
        await detector.reset()
        XCTAssertFalse(detector.isPlaybackActive)
        XCTAssertEqual(vad.resetCount, 1)
    }
}
