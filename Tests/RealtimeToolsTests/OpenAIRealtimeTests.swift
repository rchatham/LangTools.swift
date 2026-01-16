//
//  OpenAIRealtimeTests.swift
//  LangTools
//
//  Created by Reid Chatham on 1/16/26.
//

import XCTest
@testable import OpenAI
@testable import LangTools

final class OpenAIRealtimeTests: XCTestCase {

    // MARK: - Session Configuration Tests

    func testRealtimeSessionConfigurationDefaults() {
        let config = RealtimeSessionConfiguration()

        XCTAssertNil(config.type)
        XCTAssertNil(config.modalities)
        XCTAssertNil(config.instructions)
        XCTAssertNil(config.voice)
    }

    func testRealtimeSessionConfigurationComplete() {
        let config = RealtimeSessionConfiguration(
            type: .conversation,
            modalities: [.text, .audio],
            instructions: "You are a helpful assistant",
            voice: "alloy",
            inputAudioFormat: .pcm16,
            outputAudioFormat: .pcm16,
            turnDetection: RealtimeSessionConfiguration.TurnDetection(
                type: .serverVad,
                threshold: 0.5,
                silenceDurationMs: 500
            ),
            temperature: 0.8
        )

        XCTAssertEqual(config.type, .conversation)
        XCTAssertEqual(config.modalities, [.text, .audio])
        XCTAssertEqual(config.instructions, "You are a helpful assistant")
        XCTAssertEqual(config.voice, "alloy")
        XCTAssertEqual(config.inputAudioFormat, .pcm16)
        XCTAssertEqual(config.temperature, 0.8)
    }

    // MARK: - Audio Format Tests

    func testAudioFormatSampleRates() {
        XCTAssertEqual(RealtimeSessionConfiguration.AudioFormat.pcm16.sampleRate, 24000)
        XCTAssertEqual(RealtimeSessionConfiguration.AudioFormat.g711_ulaw.sampleRate, 8000)
        XCTAssertEqual(RealtimeSessionConfiguration.AudioFormat.g711_alaw.sampleRate, 8000)
    }

    // MARK: - Turn Detection Tests

    func testTurnDetectionConfiguration() {
        let turnDetection = RealtimeSessionConfiguration.TurnDetection(
            type: .serverVad,
            threshold: 0.6,
            prefixPaddingMs: 300,
            silenceDurationMs: 500,
            createResponse: true,
            interruptResponse: true
        )

        XCTAssertEqual(turnDetection.type, .serverVad)
        XCTAssertEqual(turnDetection.threshold, 0.6)
        XCTAssertEqual(turnDetection.prefixPaddingMs, 300)
        XCTAssertEqual(turnDetection.silenceDurationMs, 500)
        XCTAssertEqual(turnDetection.createResponse, true)
        XCTAssertEqual(turnDetection.interruptResponse, true)
    }

    // MARK: - Client Event Tests

    func testSessionUpdateEventType() {
        let session = SessionUpdateEvent.Session(
            modalities: ["text", "audio"],
            instructions: "Test instructions"
        )
        let event = SessionUpdateEvent(session: session)

        XCTAssertEqual(event.type, "session.update")
        XCTAssertEqual(event.session.modalities, ["text", "audio"])
        XCTAssertEqual(event.session.instructions, "Test instructions")
    }

    func testInputAudioBufferAppendEventType() {
        let event = InputAudioBufferAppendEvent(audio: "base64encodedaudio")

        XCTAssertEqual(event.type, "input_audio_buffer.append")
        XCTAssertEqual(event.audio, "base64encodedaudio")
    }

    func testInputAudioBufferCommitEventType() {
        let event = InputAudioBufferCommitEvent()

        XCTAssertEqual(event.type, "input_audio_buffer.commit")
    }

    func testInputAudioBufferClearEventType() {
        let event = InputAudioBufferClearEvent()

        XCTAssertEqual(event.type, "input_audio_buffer.clear")
    }

    func testResponseCreateEventType() {
        let event = ResponseCreateEvent()

        XCTAssertEqual(event.type, "response.create")
    }

    func testResponseCancelEventType() {
        let event = ResponseCancelEvent()

        XCTAssertEqual(event.type, "response.cancel")
    }

    func testConversationItemCreateEventType() {
        let item = ConversationItemCreateEvent.Item(
            type: "message",
            role: "user",
            content: [
                ConversationItemCreateEvent.Item.Content(type: "input_text", text: "Hello")
            ]
        )
        let event = ConversationItemCreateEvent(item: item)

        XCTAssertEqual(event.type, "conversation.item.create")
        XCTAssertEqual(event.item.type, "message")
        XCTAssertEqual(event.item.role, "user")
    }

    func testConversationItemTruncateEventType() {
        let event = ConversationItemTruncateEvent(
            itemId: "item123",
            contentIndex: 0,
            audioEndMs: 1000
        )

        XCTAssertEqual(event.type, "conversation.item.truncate")
        XCTAssertEqual(event.itemId, "item123")
        XCTAssertEqual(event.audioEndMs, 1000)
    }

    // MARK: - Client Event Enum Tests

    func testClientEventEnumTypes() {
        XCTAssertEqual(OpenAIRealtimeClientEvent.sessionUpdate(SessionUpdateEvent(session: .init())).type, "session.update")
        XCTAssertEqual(OpenAIRealtimeClientEvent.inputAudioBufferAppend(InputAudioBufferAppendEvent(audio: "")).type, "input_audio_buffer.append")
        XCTAssertEqual(OpenAIRealtimeClientEvent.inputAudioBufferCommit(InputAudioBufferCommitEvent()).type, "input_audio_buffer.commit")
        XCTAssertEqual(OpenAIRealtimeClientEvent.inputAudioBufferClear(InputAudioBufferClearEvent()).type, "input_audio_buffer.clear")
        XCTAssertEqual(OpenAIRealtimeClientEvent.responseCreate(ResponseCreateEvent()).type, "response.create")
        XCTAssertEqual(OpenAIRealtimeClientEvent.responseCancel(ResponseCancelEvent()).type, "response.cancel")
    }

    // MARK: - Server Event Decoding Tests

    func testSessionCreatedEventDecoding() throws {
        let json = """
        {
            "type": "session.created",
            "event_id": "evt_123",
            "session": {
                "id": "sess_123",
                "object": "realtime.session",
                "model": "gpt-4o-realtime-preview",
                "modalities": ["text", "audio"],
                "voice": "alloy"
            }
        }
        """

        let data = json.data(using: .utf8)!
        let event = try JSONDecoder().decode(OpenAIRealtimeServerEvent.self, from: data)

        if case .sessionCreated(let sessionEvent) = event {
            XCTAssertEqual(sessionEvent.eventId, "evt_123")
            XCTAssertEqual(sessionEvent.session.id, "sess_123")
            XCTAssertEqual(sessionEvent.session.model, "gpt-4o-realtime-preview")
            XCTAssertEqual(sessionEvent.session.voice, "alloy")
        } else {
            XCTFail("Expected sessionCreated event")
        }
    }

    func testErrorEventDecoding() throws {
        let json = """
        {
            "type": "error",
            "event_id": "evt_error",
            "error": {
                "type": "invalid_request_error",
                "code": "invalid_value",
                "message": "Invalid parameter value"
            }
        }
        """

        let data = json.data(using: .utf8)!
        let event = try JSONDecoder().decode(OpenAIRealtimeServerEvent.self, from: data)

        if case .error(let errorEvent) = event {
            XCTAssertEqual(errorEvent.eventId, "evt_error")
            XCTAssertEqual(errorEvent.error.type, "invalid_request_error")
            XCTAssertEqual(errorEvent.error.code, "invalid_value")
            XCTAssertEqual(errorEvent.error.message, "Invalid parameter value")
        } else {
            XCTFail("Expected error event")
        }
    }

    func testInputAudioBufferSpeechStartedDecoding() throws {
        let json = """
        {
            "type": "input_audio_buffer.speech_started",
            "event_id": "evt_speech",
            "audio_start_ms": 1500,
            "item_id": "item_123"
        }
        """

        let data = json.data(using: .utf8)!
        let event = try JSONDecoder().decode(OpenAIRealtimeServerEvent.self, from: data)

        if case .inputAudioBufferSpeechStarted(let speechEvent) = event {
            XCTAssertEqual(speechEvent.eventId, "evt_speech")
            XCTAssertEqual(speechEvent.audioStartMs, 1500)
            XCTAssertEqual(speechEvent.itemId, "item_123")
        } else {
            XCTFail("Expected speechStarted event")
        }
    }

    func testResponseAudioDeltaDecoding() throws {
        let json = """
        {
            "type": "response.audio.delta",
            "event_id": "evt_audio",
            "response_id": "resp_123",
            "item_id": "item_123",
            "output_index": 0,
            "content_index": 0,
            "delta": "SGVsbG8gV29ybGQ="
        }
        """

        let data = json.data(using: .utf8)!
        let event = try JSONDecoder().decode(OpenAIRealtimeServerEvent.self, from: data)

        if case .responseAudioDelta(let audioEvent) = event {
            XCTAssertEqual(audioEvent.eventId, "evt_audio")
            XCTAssertEqual(audioEvent.responseId, "resp_123")
            XCTAssertEqual(audioEvent.delta, "SGVsbG8gV29ybGQ=")

            // Test base64 decoding
            let audioData = audioEvent.audioData
            XCTAssertNotNil(audioData)
            XCTAssertEqual(String(data: audioData!, encoding: .utf8), "Hello World")
        } else {
            XCTFail("Expected responseAudioDelta event")
        }
    }

    // MARK: - Error Tests

    func testRealtimeErrorDescriptions() {
        XCTAssertNotNil(OpenAIRealtimeError.invalidURL.errorDescription)
        XCTAssertNotNil(OpenAIRealtimeError.notConnected.errorDescription)
        XCTAssertNotNil(OpenAIRealtimeError.encodingError.errorDescription)
        XCTAssertNotNil(OpenAIRealtimeError.decodingError.errorDescription)
        XCTAssertNotNil(OpenAIRealtimeError.sessionError("test").errorDescription)
    }

    // MARK: - Tool Configuration Tests

    func testRealtimeTool() {
        let tool = RealtimeSessionConfiguration.RealtimeTool(
            type: "function",
            name: "get_weather",
            description: "Get current weather",
            parameters: nil
        )

        XCTAssertEqual(tool.type, "function")
        XCTAssertEqual(tool.name, "get_weather")
        XCTAssertEqual(tool.description, "Get current weather")
    }

    // MARK: - Tool Choice Tests

    func testToolChoiceEncoding() throws {
        let autoChoice = RealtimeSessionConfiguration.ToolChoice.auto
        let noneChoice = RealtimeSessionConfiguration.ToolChoice.none
        let requiredChoice = RealtimeSessionConfiguration.ToolChoice.required
        let functionChoice = RealtimeSessionConfiguration.ToolChoice.function("get_weather")

        let encoder = JSONEncoder()

        let autoData = try encoder.encode(autoChoice)
        XCTAssertEqual(String(data: autoData, encoding: .utf8), "\"auto\"")

        let noneData = try encoder.encode(noneChoice)
        XCTAssertEqual(String(data: noneData, encoding: .utf8), "\"none\"")

        let requiredData = try encoder.encode(requiredChoice)
        XCTAssertEqual(String(data: requiredData, encoding: .utf8), "\"required\"")

        let functionData = try encoder.encode(functionChoice)
        XCTAssertEqual(String(data: functionData, encoding: .utf8), "\"get_weather\"")
    }

    // MARK: - Max Tokens Tests

    func testMaxTokensEncoding() throws {
        let countTokens = RealtimeSessionConfiguration.MaxTokens.count(1000)
        let infiniteTokens = RealtimeSessionConfiguration.MaxTokens.infinite

        let encoder = JSONEncoder()

        let countData = try encoder.encode(countTokens)
        XCTAssertEqual(String(data: countData, encoding: .utf8), "1000")

        let infiniteData = try encoder.encode(infiniteTokens)
        XCTAssertEqual(String(data: infiniteData, encoding: .utf8), "\"inf\"")
    }
}
