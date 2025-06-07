//
//  AnthropicTests.swift
//  AnthropicTests
//
//  Created by Reid Chatham on 12/6/23.
//

import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import TestUtils
@testable import Anthropic

class AnthropicTests: XCTestCase {

    var api: Anthropic!

    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(MockURLProtocol.self)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        api = Anthropic(apiKey: "").configure(testURLSessionConfiguration: config)
    }

    override func tearDown() {
        MockURLProtocol.mockNetworkHandlers.removeAll()
        URLProtocol.unregisterClass(MockURLProtocol.self)
        super.tearDown()
    }

    func testChat() async throws {
        MockURLProtocol.mockNetworkHandlers[Anthropic.MessageRequest.endpoint] = { _ in
            return (.success(try Anthropic.MessageResponse(
                content: .string("Hi! My name is Claude."),
                id: "",
                model: "",
                role: .assistant,
                stop_reason: .end_turn,
                stop_sequence: nil,
                type: .message,
                usage: .init(input_tokens: 10, output_tokens: 25)).data()), 200)
        }
        let messages = [Anthropic.Message(role: .user, content: "Hey!")]
        let response = try await api.perform(request: Anthropic.MessageRequest(model: .claude35Sonnet_20240620, messages: messages))
        guard case .string(let str) = response.message?.content, str == "Hi! My name is Claude." else { return XCTFail("Failed to decode content") }
    }

    func testChatStream() async throws {
        MockURLProtocol.mockNetworkHandlers[Anthropic.MessageRequest.endpoint] = { _ in
            return (.success(try Anthropic.MessageResponse(
                content: .string("Hi! My name is Claude."),
                id: "testid",
                model: "",
                role: .assistant,
                stop_reason: .end_turn,
                stop_sequence: nil,
                type: .message,
                usage: .init(input_tokens: 10, output_tokens: 25)).streamData()), 200)
        }
        let messages = [Anthropic.Message(role: .user, content: "Hey!")]
        var results: [Anthropic.MessageResponse] = []
        for try await response in api.stream(request: Anthropic.MessageRequest(model: .claude35Sonnet_20240620, messages: messages)) {
            results.append(response)
        }
        guard let content = results.first?.message?.content.string else { return XCTFail("Failed to decode content") }
        XCTAssertEqual(results[0].messageInfo?.id, "testid")
        XCTAssertEqual(content, "Hi! My name is Claude.")
    }

    func testChatStreamResponse() async throws {
        MockURLProtocol.mockNetworkHandlers[Anthropic.MessageRequest.endpoint] = { request in
            return (.success(try self.getData(filename: "message_stream_response", fileExtension: "txt")!), 200)
        }
        var results: [Anthropic.MessageResponse] = []
        for try await response in api.stream(request: Anthropic.MessageRequest(model: .claude35Sonnet_20240620, messages: [.init(role: .user, content: "Hi")], stream: true)) {
            results.append(response)
        }
        let content = results.reduce("") { $0 + ($1.message?.content.string ?? $1.stream?.delta?.text ?? "") }
        XCTAssertEqual(results[0].message?.role, .assistant)
        XCTAssertEqual(content, "Hello!")
        XCTAssertEqual(results[6].stream?.delta?.stop_reason, .end_turn)
    }

    func testToolCallStreamResponse() async throws {
        MockURLProtocol.mockNetworkHandlers[Anthropic.MessageRequest.endpoint] = { request in
            return (.success(try self.getData(filename: "message_stream_tool_use_response", fileExtension: "txt")!), 200)
        }
        let request = Anthropic.MessageRequest(model: .claude35Sonnet_20240620, messages: [.init(role: .user, content: "Hi")], stream: true)
        var results: [Anthropic.MessageResponse] = []
        for try await response in api.stream(request: request) {
            results.append(response)
        }
        XCTAssertEqual(results[0].message?.role, .assistant)
        XCTAssertEqual(results[17].stream?.delta?.name, "get_weather")
        let arguments = results.reduce("") { $0 + ($1.stream?.delta?.partial_json ?? "") }
        XCTAssertEqual(arguments, "{\"location\": \"San Francisco, CA\", \"unit\": \"fahrenheit\"}")
        XCTAssertEqual(results[28].stream?.delta?.stop_reason, .tool_use)
    }

    func testToolCallWithFunctionCallbackStreamResponse() async throws {
        MockURLProtocol.mockNetworkHandlers[Anthropic.MessageRequest.endpoint] = { request in
            return (.success(try self.getData(filename: "message_stream_tool_use_response", fileExtension: "txt")!), 200)
        }
        let tools: [Anthropic.Tool] = [.init(
            name: "get_weather",
            description: "Get the current weather",
            tool_schema: .init(
                properties: [
                    "location": .init(
                        type: "string",
                        description: "The city and state, e.g. San Francisco, CA"),
                    "unit": .init(
                        type: "string",
                        enumValues: ["celsius", "fahrenheit"],
                        description: "The temperature unit to use. Infer this from the users location.")
                ],
                required: ["location", "unit"]),
            callback: { _ in
                MockURLProtocol.mockNetworkHandlers[Anthropic.MessageRequest.endpoint] = { request in
                    return (.success(try self.getData(filename: "message_stream_response", fileExtension: "txt")!), 200)
                }
                return "27"
            })]
        let request = Anthropic.MessageRequest(model: .claude35Sonnet_20240620, messages: [.init(role: .user, content: "Hi")], stream: true, tools: tools)
        var results: [Anthropic.MessageResponse] = []
        for try await response in api.stream(request: request) {
            results.append(response)
        }
        XCTAssertEqual(results[0].message?.role, .assistant)
        XCTAssertEqual(results[17].stream?.delta?.name, "get_weather")
        let arguments = results.reduce("") { $0 + ($1.stream?.delta?.partial_json ?? "") }
        XCTAssertEqual(arguments, "{\"location\": \"San Francisco, CA\", \"unit\": \"fahrenheit\"}")
        XCTAssertEqual(results[28].stream?.delta?.stop_reason, .tool_use)
        let content = results.reduce("") { $0 + ($1.stream?.delta?.text ?? "") }
        XCTAssertEqual(content, "Okay, let's check the weather for San Francisco, CA:Hello!")
    }
}

