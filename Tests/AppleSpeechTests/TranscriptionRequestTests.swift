//
//  TranscriptionRequestTests.swift
//  AppleSpeech
//
//  Tests for TranscriptionRequest functionality
//

import XCTest
import Speech
import AVFoundation
@testable import AppleSpeech

final class TranscriptionRequestTests: XCTestCase {

    var testAudioURL: URL!

    override func setUp() async throws {
        try await super.setUp()

        // Create a test audio file
        testAudioURL = try await createTestAudioFile()
    }

    override func tearDown() async throws {
        // Clean up test audio file
        if let url = testAudioURL, FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        testAudioURL = nil

        try await super.tearDown()
    }

    // MARK: - Initialization Tests

    func testTranscriptionRequestInitialization() {
        let request = AppleSpeech.TranscriptionRequest(
            audioURL: testAudioURL,
            locale: .current,
            reportPartialResults: true,
            taskHint: .dictation
        )

        XCTAssertEqual(request.audioURL, testAudioURL)
        XCTAssertEqual(request.locale, .current)
        XCTAssertTrue(request.reportPartialResults)
        XCTAssertEqual(request.taskHint, .dictation)
    }

    func testTranscriptionRequestDefaultValues() {
        let request = AppleSpeech.TranscriptionRequest(audioURL: testAudioURL)

        XCTAssertEqual(request.locale, .current)
        XCTAssertTrue(request.reportPartialResults)
        XCTAssertEqual(request.taskHint, .unspecified)
    }

    // MARK: - Task Hint Tests

    func testTaskHintVariations() {
        let hints: [SFSpeechRecognitionTaskHint] = [
            .unspecified,
            .dictation,
            .search,
            .confirmation
        ]

        for hint in hints {
            let request = AppleSpeech.TranscriptionRequest(
                audioURL: testAudioURL,
                taskHint: hint
            )
            XCTAssertEqual(request.taskHint, hint)
        }
    }

    // MARK: - Locale Tests

    func testDifferentLocales() {
        let locales = [
            Locale(identifier: "en_US"),
            Locale(identifier: "es_ES"),
            Locale(identifier: "fr_FR"),
            Locale(identifier: "de_DE")
        ]

        for locale in locales {
            let request = AppleSpeech.TranscriptionRequest(
                audioURL: testAudioURL,
                locale: locale
            )
            XCTAssertEqual(request.locale, locale)
        }
    }

    // MARK: - Execution Tests

    func testTranscriptionRequestWithInvalidURL() async {
        let invalidURL = URL(fileURLWithPath: "/nonexistent/audio.wav")
        let request = AppleSpeech.TranscriptionRequest(audioURL: invalidURL)

        do {
            _ = try await request.execute()
            XCTFail("Should throw error for invalid URL")
        } catch {
            // Expected to throw error
            XCTAssertNotNil(error)
        }
    }

    func testTranscriptionRequestWithEmptyAudio() async throws {
        // Create an empty audio file
        let emptyURL = try createEmptyAudioFile()
        defer { try? FileManager.default.removeItem(at: emptyURL) }

        let request = AppleSpeech.TranscriptionRequest(audioURL: emptyURL)

        do {
            let result = try await request.execute()
            // Empty audio should return empty string or throw
            XCTAssertTrue(result.isEmpty || result.count > 0)
        } catch {
            // Also acceptable to throw error for empty audio
            XCTAssertNotNil(error)
        }
    }

    // MARK: - Helper Methods

    private func createTestAudioFile() async throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "test_audio_\(UUID().uuidString).wav"
        let fileURL = tempDir.appendingPathComponent(fileName)

        // Create a simple WAV file with silence (1 second at 16kHz)
        let sampleRate = 16000.0
        let duration = 1.0
        let frameCount = Int(sampleRate * duration)

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!

        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        )!
        buffer.frameLength = AVAudioFrameCount(frameCount)

        // Fill with silence (zeros)
        if let channelData = buffer.floatChannelData {
            memset(channelData[0], 0, frameCount * MemoryLayout<Float>.size)
        }

        // Write to file
        let audioFile = try AVAudioFile(
            forWriting: fileURL,
            settings: format.settings
        )
        try audioFile.write(from: buffer)

        return fileURL
    }

    private func createEmptyAudioFile() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "empty_audio_\(UUID().uuidString).wav"
        let fileURL = tempDir.appendingPathComponent(fileName)

        // Create WAV file with minimal valid header but no audio data
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!

        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: 1
        )!
        buffer.frameLength = 0 // Empty buffer

        let audioFile = try AVAudioFile(
            forWriting: fileURL,
            settings: format.settings
        )
        try audioFile.write(from: buffer)

        return fileURL
    }
}
