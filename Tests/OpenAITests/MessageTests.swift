//
//  MessageTests.swift
//  OpenAITests
//
//  Created by Reid Chatham on 12/15/23.
//

import XCTest
@testable import TestUtils
@testable import OpenAI

final class MessageTests: XCTestCase {
    func testSystemMessageDecodable() throws {
        OpenAI.decode { (result: Result<OpenAI.Message, Error>) in
            switch result {
            case .success(_): break
            case .failure(let error):
                XCTFail("failed to decode data \(error.localizedDescription)")
            }
        }(try getData(filename: "system_message")!)
    }

    func testUserMessageDecodable() throws {
        OpenAI.decode { (result: Result<OpenAI.Message, Error>) in
            switch result {
            case .success(_): break
            case .failure(let error):
                XCTFail("failed to decode data \(error.localizedDescription)")
            }
        }(try getData(filename: "user_message")!)
    }

    func testUserMessageWithImageDecodable() throws {
        OpenAI.decode { (result: Result<OpenAI.Message, Error>) in
            switch result {
            case .success(_): break
            case .failure(let error):
                XCTFail("failed to decode data \(error.localizedDescription)")
            }
        }(try getData(filename: "user_message_with_image-openai")!)
    }
    
    func testAssistantMessageDecodable() throws {
        OpenAI.decode { (result: Result<OpenAI.Message, Error>) in
            switch result {
            case .success(_): break
            case .failure(let error):
                XCTFail("failed to decode data \(error.localizedDescription)")
            }
        }(try getData(filename: "assistant_message")!)
    }

    func testAssistantMessageWithToolCallDecodable() throws {
        OpenAI.decode { (result: Result<OpenAI.Message, Error>) in
            switch result {
            case .success(_): break
            case .failure(let error):
                XCTFail("failed to decode data \(error.localizedDescription)")
            }
        }(try getData(filename: "assistant_message_with_tool_call")!)
    }
    
    func testSystemMessageEncodable() throws {
        let userMessage = OpenAI.Message(role: .system, content: "You are a helpful assistant.")
        let json = try userMessage.data()
        let data = try getData(filename: "system_message")!
        XCTAssert(json.dictionary == data.dictionary, "system message not encoded correctly")
    }

    func testUserMessageEncodable() throws {
        let userMessage = OpenAI.Message(role: .user, content: "Hello!")
        let json = try userMessage.data()
        let data = try getData(filename: "user_message")!
        XCTAssert(json.dictionary == data.dictionary, "user message not encoded correctly")
    }

    func testDeveloperMessageDecodable() throws {
        OpenAI.decode { (result: Result<OpenAI.Message, Error>) in
            switch result {
            case .success(let message):
                XCTAssertEqual(message.role, .developer)
                XCTAssertEqual(message.content.string, "You are a helpful assistant focused on data analysis.")
            case .failure(let error):
                XCTFail("failed to decode data \(error.localizedDescription)")
            }
        }(try getData(filename: "developer_message")!)
    }

    func testUserMessageWithAudioDecodable() throws {
        OpenAI.decode { (result: Result<OpenAI.Message, Error>) in
            switch result {
            case .success(let message):
                XCTAssertEqual(message.role, .user)
                guard case .array(let contents) = message.content else {
                    return XCTFail("Expected array content")
                }
                if case .audio(let audio) = contents[0] {
                    XCTAssertEqual(audio.input_audio.format, .mp3)
                } else {
                    XCTFail("Expected audio content")
                }
                if case .text(let text) = contents[1] {
                    XCTAssertEqual(text.text, "What did I say in this recording?")
                } else {
                    XCTFail("Expected text content")
                }
            case .failure(let error):
                XCTFail("failed to decode data \(error.localizedDescription)")
            }
        }(try getData(filename: "user_message_with_audio")!)
    }

    func testAssistantMessageWithRefusalDecodable() throws {
        OpenAI.decode { (result: Result<OpenAI.Message, Error>) in
            switch result {
            case .success(let message):
                XCTAssertEqual(message.role, .assistant)
                XCTAssertEqual(message.refusal, "I cannot assist with generating harmful content.")
            case .failure(let error):
                XCTFail("failed to decode data \(error.localizedDescription)")
            }
        }(try getData(filename: "assistant_message_with_refusal")!)
    }

    func testAssistantMessageWithAudioResponseDecodable() throws {
        OpenAI.decode { (result: Result<OpenAI.Message, Error>) in
            switch result {
            case .success(let message):
                XCTAssertEqual(message.role, .assistant)
                XCTAssertEqual(message.content.string, "Here's what you said, both as text and audio.")
                XCTAssertEqual(message.audio?.id, "audio-123")
                XCTAssertEqual(message.audio?.transcript, "Here's what you said, both as text and audio.")
            case .failure(let error):
                XCTFail("failed to decode data \(error.localizedDescription)")
            }
        }(try getData(filename: "assistant_message_with_audio_response")!)
    }
}
