//
//  AnthropicPerformanceTests.swift
//  LangTools
//
//  Performance tests for Anthropic request encoding, response decoding,
//  streaming throughput, and request preparation.
//

import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LangTools
@testable import Anthropic
@testable import TestUtils

final class AnthropicPerformanceTests: XCTestCase {

    var api: Anthropic!

    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(MockURLProtocol.self)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        api = Anthropic(apiKey: "test-key").configure(testURLSessionConfiguration: config)
    }

    override func tearDown() {
        MockURLProtocol.mockNetworkHandlers.removeAll()
        URLProtocol.unregisterClass(MockURLProtocol.self)
        super.tearDown()
    }

    // MARK: - Request Encoding Performance

    func testRequestEncodingPerformance_SmallMessage() {
        let request = PerformanceFixtures.anthropicMessageRequest(messageCount: 2)
        let encoder = JSONEncoder()
        measure {
            for _ in 0..<100 {
                _ = try! encoder.encode(request)
            }
        }
    }

    func testRequestEncodingPerformance_MediumConversation() {
        let request = PerformanceFixtures.anthropicMessageRequest(messageCount: 20)
        let encoder = JSONEncoder()
        measure {
            for _ in 0..<100 {
                _ = try! encoder.encode(request)
            }
        }
    }

    func testRequestEncodingPerformance_LargeConversation() {
        let request = PerformanceFixtures.anthropicMessageRequest(messageCount: 100)
        let encoder = JSONEncoder()
        measure {
            for _ in 0..<50 {
                _ = try! encoder.encode(request)
            }
        }
    }

    func testRequestEncodingPerformance_WithTools() {
        let tools: [Anthropic.Tool] = (0..<10).map { i in
            .init(
                name: "tool_\(i)",
                description: "Test tool number \(i) for performance testing",
                tool_schema: .init(
                    properties: [
                        "param1": .init(type: "string", description: "First parameter"),
                        "param2": .init(type: "integer", description: "Second parameter"),
                        "param3": .init(type: "boolean", description: "Third parameter"),
                    ],
                    required: ["param1"]
                )
            )
        }
        let request = Anthropic.MessageRequest(
            model: .claude46Sonnet,
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

    func testResponseDecodingPerformance_SimpleMessage() {
        let data = PerformanceFixtures.anthropicMessageResponseJSON()
        let decoder = JSONDecoder()
        measure {
            for _ in 0..<500 {
                _ = try! decoder.decode(Anthropic.MessageResponse.self, from: data)
            }
        }
    }

    func testResponseDecodingPerformance_WithToolCalls() {
        let data = PerformanceFixtures.anthropicMessageResponseWithToolsJSON(toolCount: 3)
        let decoder = JSONDecoder()
        measure {
            for _ in 0..<200 {
                _ = try! decoder.decode(Anthropic.MessageResponse.self, from: data)
            }
        }
    }

    func testResponseDecodingPerformance_ManyToolCalls() {
        let data = PerformanceFixtures.anthropicMessageResponseWithToolsJSON(toolCount: 10)
        let decoder = JSONDecoder()
        measure {
            for _ in 0..<100 {
                _ = try! decoder.decode(Anthropic.MessageResponse.self, from: data)
            }
        }
    }

    // MARK: - Streaming Performance

    func testStreamingThroughput_SmallStream() async throws {
        let streamData = PerformanceFixtures.anthropicStreamData(chunkCount: 10)
        measure {
            let exp = expectation(description: "stream")
            Task {
                MockURLProtocol.mockNetworkHandlers[Anthropic.MessageRequest.endpoint] = { _ in
                    (.success(streamData), 200)
                }
                var count = 0
                for try await _ in self.api.stream(request: Anthropic.MessageRequest(model: .claude46Sonnet, messages: [.init(role: .user, content: "Hi")], stream: true)) {
                    count += 1
                }
                XCTAssertGreaterThan(count, 0)
                exp.fulfill()
            }
            wait(for: [exp], timeout: 10.0)
        }
    }

    func testStreamingThroughput_MediumStream() async throws {
        let streamData = PerformanceFixtures.anthropicStreamData(chunkCount: 50)
        measure {
            let exp = expectation(description: "stream")
            Task {
                MockURLProtocol.mockNetworkHandlers[Anthropic.MessageRequest.endpoint] = { _ in
                    (.success(streamData), 200)
                }
                var count = 0
                for try await _ in self.api.stream(request: Anthropic.MessageRequest(model: .claude46Sonnet, messages: [.init(role: .user, content: "Hi")], stream: true)) {
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
        let data = PerformanceFixtures.anthropicMessageResponseJSON()
        let response = try! decoder.decode(Anthropic.MessageResponse.self, from: data)

        measure {
            for _ in 0..<500 {
                var combined = Anthropic.MessageResponse.empty
                for _ in 0..<50 {
                    combined = combined.combining(with: response)
                }
            }
        }
    }

    // MARK: - Request Preparation Performance

    func testRequestPreparationPerformance() throws {
        let request = PerformanceFixtures.anthropicMessageRequest(messageCount: 10)
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
                _ = Anthropic.Message(role: .user, content: "Hello, how are you doing today?")
                _ = Anthropic.Message(role: .assistant, content: "I'm doing well, thank you for asking!")
            }
        }
    }

    func testMessageConstructionPerformance_ArrayContent() {
        measure {
            for _ in 0..<500 {
                _ = Anthropic.Message(
                    role: .user,
                    content: .array([
                        .text(.init(text: "What's in this image?")),
                        .image(.init(
                            source: .init(
                                data: String(repeating: "A", count: 100),
                                media_type: .png
                            )
                        ))
                    ])
                )
            }
        }
    }

    // MARK: - Model Validation Performance

    func testModelValidationPerformance() {
        let request = Anthropic.MessageRequest(model: .claude46Sonnet, messages: [.init(role: .user, content: "Hi")])
        measure {
            for _ in 0..<10000 {
                let validators = Anthropic.requestValidators
                _ = validators.contains(where: { $0(request) })
            }
        }
    }

    // MARK: - Stream Decode Function Performance

    func testStreamDecodeFunctionPerformance() {
        let line = "data: {\"type\": \"content_block_delta\", \"index\": 0, \"delta\": {\"type\": \"text_delta\", \"text\": \"Hello world this is a test\"}}"
        measure {
            for _ in 0..<1000 {
                let _: Anthropic.MessageResponse? = try! Anthropic.decodeStream(line)
            }
        }
    }

    // MARK: - Encode-Decode Round Trip Performance

    func testEncodeDecodeRoundTripPerformance() {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let request = PerformanceFixtures.anthropicMessageRequest(messageCount: 10)
        measure {
            for _ in 0..<100 {
                let data = try! encoder.encode(request)
                _ = try! decoder.decode(Anthropic.MessageRequest.self, from: data)
            }
        }
    }
}
