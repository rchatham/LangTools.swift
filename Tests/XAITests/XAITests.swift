//
//  XAITests.swift
//  XAITests
//
//  Created by Reid Chatham on 12/6/23.
//

import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import TestUtils
@testable import XAI
@testable import OpenAI

class XAITests: XCTestCase {

    var api: XAI!

    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(MockURLProtocol.self)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        api = XAI(apiKey: "").configure(testURLSessionConfiguration: config)
    }

    override func tearDown() {
        MockURLProtocol.mockNetworkHandlers.removeAll()
        URLProtocol.unregisterClass(MockURLProtocol.self)
        super.tearDown()
    }

    func testXAIChatCompletion() async throws {
        MockURLProtocol.mockNetworkHandlers[OpenAI.ChatCompletionRequest.endpoint] = { request in
            return (.success(try OpenAI.ChatCompletionResponse(
                id: "xai-test-id",
                object: "chat.completion",
                created: 0,
                model: "grok-2-1212",
                system_fingerprint: nil,
                choices: [.init(
                    index: 0,
                    message: .init(role: .assistant, content: "Hello from Grok!"),
                    finish_reason: .stop,
                    delta: nil,
                    logprobs: nil)],
                usage: .init(prompt_tokens: 10, completion_tokens: 5, total_tokens: 15),
                service_tier: nil,
                choose: { _ in 0 }).data()), 200)
        }

        let request = OpenAI.ChatCompletionRequest(
            model: .grok,
            messages: [.init(role: .user, content: "Hi")]
        )
        let response = try await api.perform(request: request)

        XCTAssertEqual(response.id, "xai-test-id")
        XCTAssertEqual(response.choices[0].message?.content.string, "Hello from Grok!")
        XCTAssertEqual(response.choices[0].finish_reason, .stop)
    }

    func testXAIChatStream() async throws {
        MockURLProtocol.mockNetworkHandlers[OpenAI.ChatCompletionRequest.endpoint] = { request in
            return (.success(try OpenAI.ChatCompletionResponse(
                id: "xai-stream-id",
                object: "chat.completion.chunk",
                created: 0,
                model: "grok-2-1212",
                system_fingerprint: nil,
                choices: [.init(
                    index: 0,
                    message: nil,
                    finish_reason: nil,
                    delta: .init(
                        role: .assistant,
                        content: "Streaming from Grok",
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
            model: .grok,
            messages: [.init(role: .user, content: "Hi")],
            stream: true
        )

        for try await response in api.stream(request: request) {
            results.append(response)
        }

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].choices[0].delta?.content, "Streaming from Grok")
    }

    func testXAIModelVariants() {
        // Verify all XAI model variants are available
        let models: [XAIModel] = [
            .grok,
            .grokVision,
            .grokBeta
        ]

        for model in models {
            XCTAssertFalse(model.rawValue.isEmpty, "Model \(model) should have a valid raw value")
        }
    }

    func testXAIRequestValidation() {
        let validRequest = OpenAI.ChatCompletionRequest(
            model: .grok,
            messages: [.init(role: .user, content: "test")]
        )

        let isValid = XAI.requestValidators.contains { $0(validRequest) }
        XCTAssertTrue(isValid, "XAI request validator should accept XAI model requests")
    }

    func testGrokVisionModel() async throws {
        MockURLProtocol.mockNetworkHandlers[OpenAI.ChatCompletionRequest.endpoint] = { request in
            return (.success(try OpenAI.ChatCompletionResponse(
                id: "grok-vision-id",
                object: "chat.completion",
                created: 0,
                model: "grok-2-vision-1212",
                system_fingerprint: nil,
                choices: [.init(
                    index: 0,
                    message: .init(role: .assistant, content: "I can see the image"),
                    finish_reason: .stop,
                    delta: nil,
                    logprobs: nil)],
                usage: .init(prompt_tokens: 20, completion_tokens: 10, total_tokens: 30),
                service_tier: nil,
                choose: { _ in 0 }).data()), 200)
        }

        let request = OpenAI.ChatCompletionRequest(
            model: .grokVision,
            messages: [.init(role: .user, content: "Describe this image")]
        )
        let response = try await api.perform(request: request)

        XCTAssertEqual(response.id, "grok-vision-id")
        XCTAssertEqual(response.model, "grok-2-vision-1212")
    }
}

extension XAI {
    internal func configure(testURLSessionConfiguration: URLSessionConfiguration) -> Self {
        openAI.configure(testURLSessionConfiguration: testURLSessionConfiguration)
        return self
    }
}
