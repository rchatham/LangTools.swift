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

    func testNewClaude4ModelsAvailable() throws {
        // Test that new Claude 4.x models are available in the enum
        let allModels = Anthropic.Model.allCases
        
        // Test Claude 4.1 Opus models
        XCTAssertTrue(allModels.contains(.claude41Opus_latest))
        XCTAssertTrue(allModels.contains(.claude41Opus_20250805))
        
        // Test Claude 4.5 Sonnet models
        XCTAssertTrue(allModels.contains(.claude45Sonnet_latest))
        XCTAssertTrue(allModels.contains(.claude45Sonnet_20250929))
        
        // Test Claude 4.5 Haiku models
        XCTAssertTrue(allModels.contains(.claude45Haiku_latest))
        XCTAssertTrue(allModels.contains(.claude45Haiku_20251001))
    }
    
    func testNewClaude4ModelsEncodable() throws {
        // Test that new models can be encoded to correct string values
        let encoder = JSONEncoder()
        
        // Claude 4.1 Opus
        let opus41Latest = try encoder.encode(Anthropic.Model.claude41Opus_latest)
        XCTAssertEqual(String(data: opus41Latest, encoding: .utf8), "\"claude-4-1-opus-latest\"")
        
        let opus41Dated = try encoder.encode(Anthropic.Model.claude41Opus_20250805)
        XCTAssertEqual(String(data: opus41Dated, encoding: .utf8), "\"claude-4-1-opus-20250805\"")
        
        // Claude 4.5 Sonnet
        let sonnet45Latest = try encoder.encode(Anthropic.Model.claude45Sonnet_latest)
        XCTAssertEqual(String(data: sonnet45Latest, encoding: .utf8), "\"claude-4-5-sonnet-latest\"")
        
        let sonnet45Dated = try encoder.encode(Anthropic.Model.claude45Sonnet_20250929)
        XCTAssertEqual(String(data: sonnet45Dated, encoding: .utf8), "\"claude-4-5-sonnet-20250929\"")
        
        // Claude 4.5 Haiku
        let haiku45Latest = try encoder.encode(Anthropic.Model.claude45Haiku_latest)
        XCTAssertEqual(String(data: haiku45Latest, encoding: .utf8), "\"claude-4-5-haiku-latest\"")
        
        let haiku45Dated = try encoder.encode(Anthropic.Model.claude45Haiku_20251001)
        XCTAssertEqual(String(data: haiku45Dated, encoding: .utf8), "\"claude-4-5-haiku-20251001\"")
    }
    
    func testNewClaude4ModelsDecodable() throws {
        // Test that new models can be decoded from string values
        let decoder = JSONDecoder()
        
        // Claude 4.1 Opus
        let opus41LatestData = "\"claude-4-1-opus-latest\"".data(using: .utf8)!
        let opus41Latest = try decoder.decode(Anthropic.Model.self, from: opus41LatestData)
        XCTAssertEqual(opus41Latest, .claude41Opus_latest)
        
        // Claude 4.5 Sonnet
        let sonnet45LatestData = "\"claude-4-5-sonnet-latest\"".data(using: .utf8)!
        let sonnet45Latest = try decoder.decode(Anthropic.Model.self, from: sonnet45LatestData)
        XCTAssertEqual(sonnet45Latest, .claude45Sonnet_latest)
        
        // Claude 4.5 Haiku
        let haiku45LatestData = "\"claude-4-5-haiku-latest\"".data(using: .utf8)!
        let haiku45Latest = try decoder.decode(Anthropic.Model.self, from: haiku45LatestData)
        XCTAssertEqual(haiku45Latest, .claude45Haiku_latest)
    }
}

