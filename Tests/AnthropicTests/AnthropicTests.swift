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
        let response = try await api.perform(request: Anthropic.MessageRequest(model: .claude46Sonnet, messages: messages))
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
        for try await response in api.stream(request: Anthropic.MessageRequest(model: .claude46Sonnet, messages: messages)) {
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
        for try await response in api.stream(request: Anthropic.MessageRequest(model: .claude46Sonnet, messages: [.init(role: .user, content: "Hi")], stream: true)) {
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
        let request = Anthropic.MessageRequest(model: .claude46Sonnet, messages: [.init(role: .user, content: "Hi")], stream: true)
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
        let request = Anthropic.MessageRequest(model: .claude46Sonnet, messages: [.init(role: .user, content: "Hi")], stream: true, tools: tools)
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

        // Test Claude 4.6 models
        XCTAssertTrue(allModels.contains(.claude46Opus))
        XCTAssertTrue(allModels.contains(.claude46Sonnet))

        // Test Claude 4.5 models
        XCTAssertTrue(allModels.contains(.claude45Opus_20251101))
        XCTAssertTrue(allModels.contains(.claude45Sonnet_20250929))
        XCTAssertTrue(allModels.contains(.claude45Haiku_20251001))

        // Test Claude 4.1 Opus
        XCTAssertTrue(allModels.contains(.claude41Opus_20250805))
    }

    func testNewClaude4ModelsEncodable() throws {
        // Test that new models can be encoded to correct string values
        let encoder = JSONEncoder()

        // Claude 4.6 Opus
        let opus46 = try encoder.encode(Anthropic.Model.claude46Opus)
        XCTAssertEqual(String(data: opus46, encoding: .utf8), "\"claude-opus-4-6\"")

        // Claude 4.6 Sonnet
        let sonnet46 = try encoder.encode(Anthropic.Model.claude46Sonnet)
        XCTAssertEqual(String(data: sonnet46, encoding: .utf8), "\"claude-sonnet-4-6\"")

        // Claude 4.5 Haiku
        let haiku45Dated = try encoder.encode(Anthropic.Model.claude45Haiku_20251001)
        XCTAssertEqual(String(data: haiku45Dated, encoding: .utf8), "\"claude-haiku-4-5-20251001\"")
    }

    func testNewClaude4ModelsDecodable() throws {
        // Test that new models can be decoded from string values
        let decoder = JSONDecoder()

        // Claude 4.6 Opus
        let opus46Data = "\"claude-opus-4-6\"".data(using: .utf8)!
        let opus46 = try decoder.decode(Anthropic.Model.self, from: opus46Data)
        XCTAssertEqual(opus46, .claude46Opus)

        // Claude 4.6 Sonnet
        let sonnet46Data = "\"claude-sonnet-4-6\"".data(using: .utf8)!
        let sonnet46 = try decoder.decode(Anthropic.Model.self, from: sonnet46Data)
        XCTAssertEqual(sonnet46, .claude46Sonnet)

        // Claude 4.5 Haiku
        let haiku45Data = "\"claude-haiku-4-5-20251001\"".data(using: .utf8)!
        let haiku45 = try decoder.decode(Anthropic.Model.self, from: haiku45Data)
        XCTAssertEqual(haiku45, .claude45Haiku_20251001)
    }

    func testIsDeprecatedProperty() throws {
        // Deprecated models should return true
        XCTAssertTrue(Anthropic.Model.claude3Haiku_20240307.isDeprecated)

        // Active models should return false
        XCTAssertFalse(Anthropic.Model.claude46Opus.isDeprecated)
        XCTAssertFalse(Anthropic.Model.claude46Sonnet.isDeprecated)
        XCTAssertFalse(Anthropic.Model.claude45Haiku_20251001.isDeprecated)

        // Retired models are not "deprecated" (they are retired)
        XCTAssertFalse(Anthropic.Model.claude37Sonnet_20250219.isDeprecated)
        XCTAssertFalse(Anthropic.Model.claude3Opus_20240229.isDeprecated)
    }

    func testIsRetiredProperty() throws {
        // Retired models should return true
        XCTAssertTrue(Anthropic.Model.claude37Sonnet_20250219.isRetired)
        XCTAssertTrue(Anthropic.Model.claude35Haiku_20241022.isRetired)
        XCTAssertTrue(Anthropic.Model.claude35Sonnet_20241022.isRetired)
        XCTAssertTrue(Anthropic.Model.claude35Sonnet_20240620.isRetired)
        XCTAssertTrue(Anthropic.Model.claude3Opus_20240229.isRetired)
        XCTAssertTrue(Anthropic.Model.claude3Sonnet_20240229.isRetired)

        // Active models should return false
        XCTAssertFalse(Anthropic.Model.claude46Opus.isRetired)
        XCTAssertFalse(Anthropic.Model.claude46Sonnet.isRetired)

        // Deprecated (but not yet retired) models should return false
        XCTAssertFalse(Anthropic.Model.claude3Haiku_20240307.isRetired)
    }
}

