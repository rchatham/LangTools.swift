//
//  AnthropicIntegrationTests.swift
//  LangTools
//
//  Integration tests for Anthropic provider: full request/response flows,
//  error handling, streaming, tool calling, structured output, and edge cases.
//

import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LangTools
@testable import Anthropic
@testable import TestUtils

final class AnthropicIntegrationTests: XCTestCase {

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

    // MARK: - Basic Message Request

    func testPerformMessageRequest() async throws {
        MockURLProtocol.mockNetworkHandlers[Anthropic.MessageRequest.endpoint] = { _ in
            let data = PerformanceFixtures.anthropicMessageResponseJSON()
            return (.success(data), 200)
        }
        let request = Anthropic.MessageRequest(
            model: .claude46Sonnet,
            messages: [.init(role: .user, content: "Hello")]
        )
        let response = try await api.perform(request: request)

        XCTAssertNotNil(response.messageInfo)
        XCTAssertEqual(response.messageInfo?.id, "msg_perf_test_001")
        XCTAssertEqual(response.messageInfo?.role, .assistant)
        XCTAssertNotNil(response.message?.content.string)
        XCTAssertNotNil(response.usage.input_tokens)
    }

    func testPerformMessageRequestWithSystemPrompt() async throws {
        MockURLProtocol.mockNetworkHandlers[Anthropic.MessageRequest.endpoint] = { request in
            // Verify system prompt is in the request body
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            XCTAssertEqual(body["system"] as? String, "You are a helpful assistant.")
            let data = PerformanceFixtures.anthropicMessageResponseJSON()
            return (.success(data), 200)
        }
        let request = Anthropic.MessageRequest(
            model: .claude46Sonnet,
            messages: [.init(role: .user, content: "Hello")],
            system: "You are a helpful assistant."
        )
        let response = try await api.perform(request: request)
        XCTAssertNotNil(response.message)
    }

    // MARK: - Streaming

    func testStreamMessageRequest() async throws {
        let streamData = PerformanceFixtures.anthropicStreamData(chunkCount: 5)
        MockURLProtocol.mockNetworkHandlers[Anthropic.MessageRequest.endpoint] = { _ in
            (.success(streamData), 200)
        }
        let request = Anthropic.MessageRequest(
            model: .claude46Sonnet,
            messages: [.init(role: .user, content: "Hello")],
            stream: true
        )
        var results: [Anthropic.MessageResponse] = []
        for try await response in api.stream(request: request) {
            results.append(response)
        }

        XCTAssertGreaterThan(results.count, 1)
        // First result should have message_start with role
        XCTAssertEqual(results[0].message?.role, .assistant)
    }

    func testStreamAccumulatesContent() async throws {
        let streamData = PerformanceFixtures.anthropicStreamData(chunkCount: 8)
        MockURLProtocol.mockNetworkHandlers[Anthropic.MessageRequest.endpoint] = { _ in
            (.success(streamData), 200)
        }
        let request = Anthropic.MessageRequest(
            model: .claude46Sonnet,
            messages: [.init(role: .user, content: "Hello")],
            stream: true
        )
        var allText = ""
        for try await response in api.stream(request: request) {
            allText += response.stream?.delta?.text ?? ""
        }
        for i in 0..<8 {
            XCTAssertTrue(allText.contains("word\(i)"), "Missing word\(i) in stream content")
        }
    }

    func testStreamStopReason() async throws {
        let streamData = PerformanceFixtures.anthropicStreamData(chunkCount: 3)
        MockURLProtocol.mockNetworkHandlers[Anthropic.MessageRequest.endpoint] = { _ in
            (.success(streamData), 200)
        }
        let request = Anthropic.MessageRequest(
            model: .claude46Sonnet,
            messages: [.init(role: .user, content: "Hello")],
            stream: true
        )
        var lastStopReason: Anthropic.MessageResponse.StopReason?
        for try await response in api.stream(request: request) {
            if let stop = response.stream?.delta?.stop_reason {
                lastStopReason = stop
            }
        }
        XCTAssertEqual(lastStopReason, .end_turn)
    }

    // MARK: - Tool Calling

    func testToolCallResponse() async throws {
        let data = PerformanceFixtures.anthropicMessageResponseWithToolsJSON(toolCount: 1)
        MockURLProtocol.mockNetworkHandlers[Anthropic.MessageRequest.endpoint] = { _ in
            (.success(data), 200)
        }
        let request = Anthropic.MessageRequest(
            model: .claude46Sonnet,
            messages: [.init(role: .user, content: "What's the weather?")],
            tools: [.init(
                name: "get_weather",
                description: "Get weather",
                tool_schema: .init(
                    properties: ["location": .init(type: "string")],
                    required: ["location"]
                )
            )]
        )
        let response = try await api.perform(request: request)

        XCTAssertNotNil(response.messageInfo)
        XCTAssertEqual(response.messageInfo?.stop_reason, .tool_use)
        // Content should have text and tool_use blocks
        guard case .array(let blocks) = response.messageInfo?.content else {
            return XCTFail("Expected array content")
        }
        XCTAssertGreaterThanOrEqual(blocks.count, 2)
    }

    func testToolCallWithCallbackCompletesFullFlow() async throws {
        let toolResponseData = PerformanceFixtures.anthropicMessageResponseWithToolsJSON(toolCount: 1)
        let finalResponseData = PerformanceFixtures.anthropicStreamData(chunkCount: 3)

        MockURLProtocol.mockNetworkHandlers[Anthropic.MessageRequest.endpoint] = { _ in
            (.success(toolResponseData), 200)
        }

        var toolWasCalled = false
        let tools: [Anthropic.Tool] = [.init(
            name: "get_weather",
            description: "Get weather",
            tool_schema: .init(
                properties: ["location": .init(type: "string")],
                required: ["location"]
            ),
            callback: { _ in
                toolWasCalled = true
                MockURLProtocol.mockNetworkHandlers[Anthropic.MessageRequest.endpoint] = { _ in
                    (.success(finalResponseData), 200)
                }
                return "72°F and sunny"
            }
        )]
        let request = Anthropic.MessageRequest(
            model: .claude46Sonnet,
            messages: [.init(role: .user, content: "Weather in SF?")],
            stream: true,
            tools: tools
        )

        var results: [Anthropic.MessageResponse] = []
        for try await response in api.stream(request: request) {
            results.append(response)
        }

        XCTAssertTrue(toolWasCalled)
    }

    func testMultipleToolCalls() async throws {
        let data = PerformanceFixtures.anthropicMessageResponseWithToolsJSON(toolCount: 3)
        MockURLProtocol.mockNetworkHandlers[Anthropic.MessageRequest.endpoint] = { _ in
            (.success(data), 200)
        }
        let request = Anthropic.MessageRequest(
            model: .claude46Sonnet,
            messages: [.init(role: .user, content: "Weather in 3 cities")],
            tools: [.init(
                name: "get_weather",
                description: "Get weather",
                tool_schema: .init(
                    properties: ["location": .init(type: "string")],
                    required: ["location"]
                )
            )]
        )
        let response = try await api.perform(request: request)

        guard case .array(let blocks) = response.messageInfo?.content else {
            return XCTFail("Expected array content")
        }
        let toolUseBlocks = blocks.filter {
            if case .toolUse = $0 { return true }
            return false
        }
        XCTAssertEqual(toolUseBlocks.count, 3)
    }

    // MARK: - Error Handling

    func testHandlesHTTPErrorResponse() async throws {
        let errorJSON = """
        {"type": "error", "error": {"type": "authentication_error", "message": "Invalid API key"}}
        """.data(using: .utf8)!

        MockURLProtocol.mockNetworkHandlers[Anthropic.MessageRequest.endpoint] = { _ in
            (.success(errorJSON), 401)
        }
        let request = Anthropic.MessageRequest(
            model: .claude46Sonnet,
            messages: [.init(role: .user, content: "Hello")]
        )

        do {
            _ = try await api.perform(request: request)
            XCTFail("Should have thrown an error")
        } catch {
            XCTAssertNotNil(error)
        }
    }

    func testHandlesNetworkError() async throws {
        let networkError = URLError(.timedOut)
        MockURLProtocol.mockNetworkHandlers[Anthropic.MessageRequest.endpoint] = { _ in
            (.failure(networkError), nil)
        }
        let request = Anthropic.MessageRequest(
            model: .claude46Sonnet,
            messages: [.init(role: .user, content: "Hello")]
        )

        do {
            _ = try await api.perform(request: request)
            XCTFail("Should have thrown an error")
        } catch {
            XCTAssertNotNil(error)
        }
    }

    // MARK: - Request Configuration

    func testRequestPreparationSetsCorrectHeaders() throws {
        let request = Anthropic.MessageRequest(
            model: .claude46Sonnet,
            messages: [.init(role: .user, content: "Hi")]
        )
        let urlRequest = try api.prepare(request: request)

        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "x-api-key"), "test-key")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "content-type"), "application/json")
        XCTAssertEqual(urlRequest.httpMethod, "POST")
        XCTAssertTrue(urlRequest.url?.absoluteString.contains("messages") ?? false)
    }

    func testRequestWithAllParameters() throws {
        let request = Anthropic.MessageRequest(
            model: .claude46Sonnet,
            messages: [.init(role: .user, content: "Hi")],
            max_tokens: 2048,
            stop_sequences: ["STOP"],
            temperature: 0.5,
            top_k: 40,
            top_p: 0.9
        )
        let data = try JSONEncoder().encode(request)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(dict["max_tokens"] as? Int, 2048)
        XCTAssertEqual(dict["temperature"] as? Double, 0.5)
        XCTAssertEqual(dict["top_k"] as? Int, 40)
        XCTAssertEqual(dict["top_p"] as? Double, 0.9)
    }

    // MARK: - Message Types

    func testContentBlockTypes() {
        // Text content
        let textMessage = Anthropic.Message(role: .user, content: "Hello")
        guard case .string(let text) = textMessage.content else {
            return XCTFail("Expected string content")
        }
        XCTAssertEqual(text, "Hello")

        // Array content with text block
        let arrayMessage = Anthropic.Message(
            role: .user,
            content: .array([.text(.init(text: "What's this?"))])
        )
        guard case .array(let blocks) = arrayMessage.content else {
            return XCTFail("Expected array content")
        }
        XCTAssertEqual(blocks.count, 1)
    }

    func testImageContentBlock() {
        let message = Anthropic.Message(
            role: .user,
            content: .array([
                .text(.init(text: "Describe this image")),
                .image(.init(source: .init(data: "base64data", media_type: .png)))
            ])
        )
        guard case .array(let blocks) = message.content else {
            return XCTFail("Expected array content")
        }
        XCTAssertEqual(blocks.count, 2)
    }

    // MARK: - Model Properties

    func testModelStructuredOutputSupport() {
        // Claude 4.x+ models should support structured output
        XCTAssertTrue(Anthropic.Model.claude46Opus.supportsStructuredOutput)
        XCTAssertTrue(Anthropic.Model.claude46Sonnet.supportsStructuredOutput)
        XCTAssertTrue(Anthropic.Model.claude45Sonnet_20250929.supportsStructuredOutput)
    }

    func testModelDeprecationStatus() {
        XCTAssertFalse(Anthropic.Model.claude46Sonnet.isDeprecated)
        XCTAssertFalse(Anthropic.Model.claude46Opus.isDeprecated)
        XCTAssertTrue(Anthropic.Model.claude3Haiku_20240307.isDeprecated)
    }

    // MARK: - Usage Tracking

    func testUsageStatistics() async throws {
        let data = PerformanceFixtures.anthropicMessageResponseJSON()
        MockURLProtocol.mockNetworkHandlers[Anthropic.MessageRequest.endpoint] = { _ in
            (.success(data), 200)
        }
        let response = try await api.perform(request: Anthropic.MessageRequest(
            model: .claude46Sonnet,
            messages: [.init(role: .user, content: "Hi")]
        ))

        XCTAssertEqual(response.usage.input_tokens, 50)
        XCTAssertEqual(response.usage.output_tokens, 100)
    }

    // MARK: - Large Conversation Handling

    func testLargeConversationHistory() async throws {
        MockURLProtocol.mockNetworkHandlers[Anthropic.MessageRequest.endpoint] = { _ in
            let data = PerformanceFixtures.anthropicMessageResponseJSON()
            return (.success(data), 200)
        }
        var messages: [Anthropic.Message] = []
        for i in 0..<50 {
            messages.append(.init(role: .user, content: "User message \(i) with content."))
            messages.append(.init(role: .assistant, content: "Assistant response \(i) with details."))
        }
        messages.append(.init(role: .user, content: "Final question"))

        let request = Anthropic.MessageRequest(model: .claude46Sonnet, messages: messages)
        let response = try await api.perform(request: request)
        XCTAssertNotNil(response.message)
    }

    // MARK: - Custom Base URL

    func testCustomBaseURL() throws {
        let customAPI = Anthropic(baseURL: URL(string: "https://custom-api.example.com/v2/")!, apiKey: "test-key")
        let request = Anthropic.MessageRequest(
            model: .claude46Sonnet,
            messages: [.init(role: .user, content: "Hi")]
        )
        let urlRequest = try customAPI.prepare(request: request)
        XCTAssertTrue(urlRequest.url?.absoluteString.hasPrefix("https://custom-api.example.com/v2/") ?? false)
    }

    // MARK: - Stream Decode

    func testStreamDecodeSkipsEventLines() throws {
        let eventLine = "event: message_start"
        let result: Anthropic.MessageResponse? = try Anthropic.decodeStream(eventLine)
        XCTAssertNil(result)
    }

    func testStreamDecodesParsesDataLines() throws {
        let dataLine = "data: {\"type\": \"message_start\", \"message\": {\"id\": \"msg_test\", \"type\": \"message\", \"role\": \"assistant\", \"content\": [], \"model\": \"claude-sonnet-4-6\", \"stop_reason\": null, \"stop_sequence\": null, \"usage\": {\"input_tokens\": 10, \"output_tokens\": 1}}}"
        let result: Anthropic.MessageResponse? = try Anthropic.decodeStream(dataLine)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.type, .message_start)
    }

    func testStreamDecodeSkipsPingEvents() throws {
        let pingLine = "data: {\"type\": \"ping\"}"
        let result: Anthropic.MessageResponse? = try Anthropic.decodeStream(pingLine)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.type, .ping)
    }
}
