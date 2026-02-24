//
//  GeminiTests.swift
//  GeminiTests
//
//  Created by Reid Chatham on 12/6/23.
//

import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import TestUtils
@testable import Gemini
@testable import OpenAI

class GeminiTests: XCTestCase {

    var api: Gemini!

    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(MockURLProtocol.self)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        api = Gemini(apiKey: "").configure(testURLSessionConfiguration: config)
    }

    override func tearDown() {
        MockURLProtocol.mockNetworkHandlers.removeAll()
        URLProtocol.unregisterClass(MockURLProtocol.self)
        super.tearDown()
    }

    func testGeminiChatCompletion() async throws {
        MockURLProtocol.mockNetworkHandlers[OpenAI.ChatCompletionRequest.endpoint] = { request in
            return (.success(try OpenAI.ChatCompletionResponse(
                id: "gemini-test-id",
                object: "chat.completion",
                created: 0,
                model: "gemini-1.5-flash",
                system_fingerprint: nil,
                choices: [.init(
                    index: 0,
                    message: .init(role: .assistant, content: "Hello from Gemini!"),
                    finish_reason: .stop,
                    delta: nil,
                    logprobs: nil)],
                usage: .init(prompt_tokens: 10, completion_tokens: 5, total_tokens: 15),
                service_tier: nil,
                choose: { _ in 0 }).data()), 200)
        }

        let request = OpenAI.ChatCompletionRequest(
            model: .gemini15Flash,
            messages: [.init(role: .user, content: "Hi")]
        )
        let response = try await api.perform(request: request)

        XCTAssertEqual(response.id, "gemini-test-id")
        XCTAssertEqual(response.choices[0].message?.content.string, "Hello from Gemini!")
        XCTAssertEqual(response.choices[0].finish_reason, .stop)
    }

    func testGeminiChatStream() async throws {
        MockURLProtocol.mockNetworkHandlers[OpenAI.ChatCompletionRequest.endpoint] = { request in
            return (.success(try OpenAI.ChatCompletionResponse(
                id: "gemini-stream-id",
                object: "chat.completion.chunk",
                created: 0,
                model: "gemini-1.5-flash",
                system_fingerprint: nil,
                choices: [.init(
                    index: 0,
                    message: nil,
                    finish_reason: nil,
                    delta: .init(
                        role: .assistant,
                        content: "Streaming response",
                        tool_calls: nil,
                        audio: nil,
                        refusal: nil),
                    logprobs: nil)],
                usage: nil,
                service_tier: nil,
                choose: { _ in 0 }).streamData()), 200)
        }

        var results: [OpenAI.ChatCompletionResponse] = []
        let request = OpenAI.ChatCompletionRequest(
            model: .gemini15Flash,
            messages: [.init(role: .user, content: "Hi")],
            stream: true
        )

        for try await response in api.stream(request: request) {
            results.append(response)
        }

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].choices[0].delta?.content, "Streaming response")
    }

    func testGeminiModelVariants() {
        // Verify all Gemini model variants are available
        let models: [GeminiModel] = [
            .gemini2Flash,
            .gemini2FlashThinking,
            .gemini15Flash,
            .gemini15Flash8B,
            .gemini15Pro,
            .gemini10Pro
        ]

        for model in models {
            XCTAssertFalse(model.rawValue.isEmpty, "Model \(model) should have a valid raw value")
        }
    }

    func testGeminiRequestValidation() {
        let validRequest = OpenAI.ChatCompletionRequest(
            model: .gemini15Flash,
            messages: [.init(role: .user, content: "test")]
        )

        let isValid = Gemini.requestValidators.contains { $0(validRequest) }
        XCTAssertTrue(isValid, "Gemini request validator should accept Gemini model requests")
    }

    func testGeminiModelRawValues() throws {
        // Verify active model IDs are correct
        XCTAssertEqual(GeminiModel.gemini3Pro.rawValue, "gemini-3-pro")
        XCTAssertEqual(GeminiModel.gemini3Flash.rawValue, "gemini-3-flash")
        XCTAssertEqual(GeminiModel.gemini31Pro.rawValue, "gemini-3.1-pro")

        // Verify deprecated model IDs
        XCTAssertEqual(GeminiModel.gemini25Flash.rawValue, "gemini-2.5-flash")
        XCTAssertEqual(GeminiModel.gemini2Flash.rawValue, "gemini-2.0-flash")

        // Verify retired model IDs
        XCTAssertEqual(GeminiModel.gemini15Flash.rawValue, "gemini-1.5-flash")
        XCTAssertEqual(GeminiModel.gemini10Pro.rawValue, "gemini-1.0-pro")
    }

    func testGeminiIsDeprecatedProperty() throws {
        // Deprecated models should return true
        XCTAssertTrue(GeminiModel.gemini25Flash.isDeprecated)
        XCTAssertTrue(GeminiModel.gemini25FlashLite.isDeprecated)
        XCTAssertTrue(GeminiModel.gemini25Pro.isDeprecated)
        XCTAssertTrue(GeminiModel.gemini2Flash.isDeprecated)
        XCTAssertTrue(GeminiModel.gemini2FlashLite.isDeprecated)

        // Active models should return false
        XCTAssertFalse(GeminiModel.gemini3Pro.isDeprecated)
        XCTAssertFalse(GeminiModel.gemini3Flash.isDeprecated)
        XCTAssertFalse(GeminiModel.gemini31Pro.isDeprecated)

        // Retired models are not "deprecated"
        XCTAssertFalse(GeminiModel.gemini15Flash.isDeprecated)
        XCTAssertFalse(GeminiModel.gemini10Pro.isDeprecated)
    }

    func testGeminiIsRetiredProperty() throws {
        // Retired models should return true
        XCTAssertTrue(GeminiModel.gemini15Flash.isRetired)
        XCTAssertTrue(GeminiModel.gemini15Flash8B.isRetired)
        XCTAssertTrue(GeminiModel.gemini15Pro.isRetired)
        XCTAssertTrue(GeminiModel.gemini10Pro.isRetired)

        // Active models should return false
        XCTAssertFalse(GeminiModel.gemini3Pro.isRetired)
        XCTAssertFalse(GeminiModel.gemini3Flash.isRetired)

        // Deprecated (but not yet retired) models should return false
        XCTAssertFalse(GeminiModel.gemini25Flash.isRetired)
        XCTAssertFalse(GeminiModel.gemini2Flash.isRetired)
    }
}

extension Gemini {
    internal func configure(testURLSessionConfiguration: URLSessionConfiguration) -> Self {
        openAI.configure(testURLSessionConfiguration: testURLSessionConfiguration)
        return self
    }
}
