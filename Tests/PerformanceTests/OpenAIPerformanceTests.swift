//
//  OpenAIPerformanceTests.swift
//  LangTools
//
//  Performance tests for OpenAI request encoding, response decoding,
//  streaming throughput, and request preparation.
//

import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LangTools
@testable import OpenAI
@testable import TestUtils

final class OpenAIPerformanceTests: XCTestCase {

    var api: OpenAI!

    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(MockURLProtocol.self)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        api = OpenAI(apiKey: "test-key").configure(testURLSessionConfiguration: config)
    }

    override func tearDown() {
        MockURLProtocol.mockNetworkHandlers.removeAll()
        URLProtocol.unregisterClass(MockURLProtocol.self)
        super.tearDown()
    }

    // MARK: - Request Encoding Performance

    func testRequestEncodingPerformance_SmallMessage() {
        let request = PerformanceFixtures.openAIChatCompletionRequest(messageCount: 2)
        let encoder = JSONEncoder()
        measure {
            for _ in 0..<100 {
                _ = try! encoder.encode(request)
            }
        }
    }

    func testRequestEncodingPerformance_MediumConversation() {
        let request = PerformanceFixtures.openAIChatCompletionRequest(messageCount: 20)
        let encoder = JSONEncoder()
        measure {
            for _ in 0..<100 {
                _ = try! encoder.encode(request)
            }
        }
    }

    func testRequestEncodingPerformance_LargeConversation() {
        let request = PerformanceFixtures.openAIChatCompletionRequest(messageCount: 100)
        let encoder = JSONEncoder()
        measure {
            for _ in 0..<50 {
                _ = try! encoder.encode(request)
            }
        }
    }

    func testRequestEncodingPerformance_WithTools() {
        let tools: [OpenAI.Tool] = (0..<10).map { i in
            .function(.init(
                name: "tool_\(i)",
                description: "Test tool number \(i) for performance testing",
                parameters: .init(
                    properties: [
                        "param1": .init(type: "string", description: "First parameter"),
                        "param2": .init(type: "integer", description: "Second parameter"),
                        "param3": .init(type: "boolean", description: "Third parameter"),
                    ],
                    required: ["param1"]
                )
            ))
        }
        let request = OpenAI.ChatCompletionRequest(
            model: .gpt4o,
            messages: [.init(role: .user, content: "Test")],
            tools: tools
        )
        let encoder = JSONEncoder()
        measure {
            for _ in 0..<100 {
                _ = try! encoder.encode(request)
            }
        }
    }

    // MARK: - Response Decoding Performance

    func testResponseDecodingPerformance_SingleChoice() {
        let data = PerformanceFixtures.openAIChatCompletionResponseJSON(choiceCount: 1)
        let decoder = JSONDecoder()
        measure {
            for _ in 0..<500 {
                _ = try! decoder.decode(OpenAI.ChatCompletionResponse.self, from: data)
            }
        }
    }

    func testResponseDecodingPerformance_MultipleChoices() {
        let data = PerformanceFixtures.openAIChatCompletionResponseJSON(choiceCount: 5)
        let decoder = JSONDecoder()
        measure {
            for _ in 0..<200 {
                _ = try! decoder.decode(OpenAI.ChatCompletionResponse.self, from: data)
            }
        }
    }

    func testResponseDecodingPerformance_ManyChoices() {
        let data = PerformanceFixtures.openAIChatCompletionResponseJSON(choiceCount: 20)
        let decoder = JSONDecoder()
        measure {
            for _ in 0..<100 {
                _ = try! decoder.decode(OpenAI.ChatCompletionResponse.self, from: data)
            }
        }
    }

    // MARK: - Streaming Performance

    func testStreamingThroughput_SmallStream() async throws {
        let streamData = PerformanceFixtures.openAIStreamChunksData(chunkCount: 10)
        measure {
            let exp = expectation(description: "stream")
            Task {
                MockURLProtocol.mockNetworkHandlers[OpenAI.ChatCompletionRequest.endpoint] = { _ in
                    (.success(streamData), 200)
                }
                var count = 0
                for try await _ in self.api.stream(request: OpenAI.ChatCompletionRequest(model: .gpt4o, messages: [.init(role: .user, content: "Hi")], stream: true)) {
                    count += 1
                }
                XCTAssertGreaterThan(count, 0)
                exp.fulfill()
            }
            wait(for: [exp], timeout: 10.0)
        }
    }

    func testStreamingThroughput_MediumStream() async throws {
        let streamData = PerformanceFixtures.openAIStreamChunksData(chunkCount: 50)
        measure {
            let exp = expectation(description: "stream")
            Task {
                MockURLProtocol.mockNetworkHandlers[OpenAI.ChatCompletionRequest.endpoint] = { _ in
                    (.success(streamData), 200)
                }
                var count = 0
                for try await _ in self.api.stream(request: OpenAI.ChatCompletionRequest(model: .gpt4o, messages: [.init(role: .user, content: "Hi")], stream: true)) {
                    count += 1
                }
                XCTAssertGreaterThan(count, 0)
                exp.fulfill()
            }
            wait(for: [exp], timeout: 10.0)
        }
    }

    // MARK: - Response Combining Performance

    func testResponseCombiningPerformance() {
        let decoder = JSONDecoder()
        let singleData = PerformanceFixtures.openAIChatCompletionResponseJSON(choiceCount: 1)
        let response = try! decoder.decode(OpenAI.ChatCompletionResponse.self, from: singleData)

        measure {
            for _ in 0..<500 {
                var combined = OpenAI.ChatCompletionResponse.empty
                for _ in 0..<50 {
                    combined = combined.combining(with: response)
                }
            }
        }
    }

    // MARK: - Request Preparation Performance

    func testRequestPreparationPerformance() throws {
        let request = PerformanceFixtures.openAIChatCompletionRequest(messageCount: 10)
        measure {
            for _ in 0..<500 {
                _ = try! self.api.prepare(request: request)
            }
        }
    }

    // MARK: - Message Construction Performance

    func testMessageConstructionPerformance_TextMessages() {
        measure {
            for _ in 0..<1000 {
                _ = OpenAI.Message(role: .user, content: "Hello, how are you doing today?")
                _ = OpenAI.Message(role: .assistant, content: "I'm doing well, thank you for asking!")
                _ = OpenAI.Message(role: .system, content: "You are a helpful assistant.")
            }
        }
    }

    func testMessageConstructionPerformance_ImageMessages() {
        measure {
            for _ in 0..<500 {
                _ = OpenAI.Message(
                    role: .user,
                    content: .array([
                        .text(.init(text: "What's in this image?")),
                        .image(.init(image_url: .init(url: "https://example.com/image.png", detail: .auto)))
                    ])
                )
            }
        }
    }

    // MARK: - Model Validation Performance

    func testModelValidationPerformance() {
        let request = OpenAI.ChatCompletionRequest(model: .gpt4o, messages: [.init(role: .user, content: "Hi")])
        measure {
            for _ in 0..<10000 {
                let validators = OpenAI.requestValidators
                _ = validators.contains(where: { $0(request) })
            }
        }
    }

    // MARK: - Encode-Decode Round Trip Performance

    func testEncodeDecodeRoundTripPerformance() {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let request = PerformanceFixtures.openAIChatCompletionRequest(messageCount: 10)
        measure {
            for _ in 0..<100 {
                let data = try! encoder.encode(request)
                _ = try! decoder.decode(OpenAI.ChatCompletionRequest.self, from: data)
            }
        }
    }
}
