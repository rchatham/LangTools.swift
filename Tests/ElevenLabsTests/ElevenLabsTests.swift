//
//  ElevenLabsTests.swift
//  LangTools
//
//  Created by Reid Chatham on 1/16/26.
//

import XCTest
@testable import ElevenLabs
@testable import LangTools

final class ElevenLabsTests: XCTestCase {

    // MARK: - Model Tests

    func testModelIDInitialization() {
        let model = ElevenLabsModel(modelID: .elevenFlashV2_5)
        XCTAssertEqual(model.id, "eleven_flash_v2_5")
        XCTAssertEqual(model.rawValue, "eleven_flash_v2_5")
    }

    func testModelRawValueInitialization() {
        let model = ElevenLabsModel(rawValue: "eleven_multilingual_v2")
        XCTAssertNotNil(model)
        XCTAssertEqual(model?.id, "eleven_multilingual_v2")
    }

    func testInvalidModelRawValueReturnsNil() {
        let model = ElevenLabsModel(rawValue: "invalid-model")
        XCTAssertNil(model)
    }

    func testCustomModelIDInitialization() {
        let model = ElevenLabsModel(customModelID: "custom-fine-tuned-model")
        XCTAssertEqual(model.id, "custom-fine-tuned-model")
    }

    func testAllModelsExist() {
        XCTAssertFalse(ElevenLabsModel.allCases.isEmpty)
        XCTAssertTrue(ElevenLabsModel.allCases.contains(.elevenFlashV2_5))
        XCTAssertTrue(ElevenLabsModel.allCases.contains(.elevenMultilingualV2))
        XCTAssertTrue(ElevenLabsModel.allCases.contains(.scribeRealtimeV2))
    }

    // MARK: - Voice Settings Tests

    func testVoiceSettingsDefaults() {
        let settings = VoiceSettings()
        XCTAssertEqual(settings.stability, 0.5)
        XCTAssertEqual(settings.similarityBoost, 0.75)
        XCTAssertNil(settings.style)
        XCTAssertNil(settings.useSpeakerBoost)
    }

    func testVoiceSettingsCustomValues() {
        let settings = VoiceSettings(
            stability: 0.8,
            similarityBoost: 0.9,
            style: 0.5,
            useSpeakerBoost: true
        )
        XCTAssertEqual(settings.stability, 0.8)
        XCTAssertEqual(settings.similarityBoost, 0.9)
        XCTAssertEqual(settings.style, 0.5)
        XCTAssertEqual(settings.useSpeakerBoost, true)
    }

    func testVoiceSettingsEncoding() throws {
        let settings = VoiceSettings(stability: 0.7, similarityBoost: 0.8)
        let data = try JSONEncoder().encode(settings)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(json?["stability"] as? Double, 0.7)
        XCTAssertEqual(json?["similarity_boost"] as? Double, 0.8)
    }

    // MARK: - Output Format Tests

    func testOutputFormatSampleRates() {
        XCTAssertEqual(ElevenLabsOutputFormat.pcm_16000.sampleRate, 16000)
        XCTAssertEqual(ElevenLabsOutputFormat.pcm_22050.sampleRate, 22050)
        XCTAssertEqual(ElevenLabsOutputFormat.pcm_24000.sampleRate, 24000)
        XCTAssertEqual(ElevenLabsOutputFormat.pcm_44100.sampleRate, 44100)
        XCTAssertEqual(ElevenLabsOutputFormat.mp3_44100_128.sampleRate, 44100)
        XCTAssertEqual(ElevenLabsOutputFormat.ulaw_8000.sampleRate, 8000)
    }

    func testOutputFormatIsPCM() {
        XCTAssertTrue(ElevenLabsOutputFormat.pcm_16000.isPCM)
        XCTAssertTrue(ElevenLabsOutputFormat.pcm_24000.isPCM)
        XCTAssertFalse(ElevenLabsOutputFormat.mp3_44100_128.isPCM)
        XCTAssertFalse(ElevenLabsOutputFormat.ulaw_8000.isPCM)
    }

    // MARK: - Request Tests

    func testTextToSpeechRequestEncoding() throws {
        let request = ElevenLabs.TextToSpeechRequest(
            text: "Hello, world!",
            voiceId: "test-voice-id",
            modelId: ElevenLabsModel.elevenFlashV2_5.id
        )

        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(json?["text"] as? String, "Hello, world!")
        XCTAssertEqual(json?["model_id"] as? String, "eleven_flash_v2_5")
    }

    func testTextToSpeechRequestEndpoint() {
        let request = ElevenLabs.TextToSpeechRequest(
            text: "Test",
            voiceId: "voice123"
        )

        XCTAssertEqual(request.endpoint, "text-to-speech/voice123")
    }

    func testTextToSpeechStreamRequestEndpoint() {
        let request = ElevenLabs.TextToSpeechStreamRequest(
            text: "Test",
            voiceId: "voice456"
        )

        XCTAssertEqual(request.endpoint, "text-to-speech/voice456/stream")
    }

    // MARK: - Error Response Tests

    func testErrorResponseDecoding() throws {
        let json = """
        {
            "detail": {
                "status": "error",
                "message": "Invalid API key"
            }
        }
        """
        let data = json.data(using: .utf8)!
        let error = try JSONDecoder().decode(ElevenLabsErrorResponse.self, from: data)

        XCTAssertEqual(error.detail?.status, "error")
        XCTAssertEqual(error.detail?.message, "Invalid API key")
    }

    // MARK: - WebSocket Error Tests

    func testWebSocketErrorDescriptions() {
        XCTAssertNotNil(ElevenLabsWebSocketError.invalidURL.errorDescription)
        XCTAssertNotNil(ElevenLabsWebSocketError.notConnected.errorDescription)
        XCTAssertNotNil(ElevenLabsWebSocketError.encodingError.errorDescription)
    }

    func testSTTErrorDescriptions() {
        XCTAssertNotNil(ElevenLabsSTTError.invalidURL.errorDescription)
        XCTAssertNotNil(ElevenLabsSTTError.serverError("test").errorDescription)
    }
}
