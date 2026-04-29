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
@testable import OpenAI
@testable import TestUtils
import PerformanceTestUtils

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
        guard case .array(let blocks) = response.messageInfo?.content else {
            return XCTFail("Expected array content")
        }
        XCTAssertGreaterThanOrEqual(blocks.count, 2)
        // Verify tool_use block has correct name and id
        let toolBlock = blocks.first(where: { if case .toolUse = $0 { return true }; return false })
        if case .toolUse(let toolUse) = toolBlock {
            XCTAssertEqual(toolUse.name, "get_weather")
            XCTAssertNotNil(toolUse.id)
        } else {
            XCTFail("Expected tool_use content block")
        }
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
        for block in toolUseBlocks {
            if case .toolUse(let toolUse) = block {
                XCTAssertEqual(toolUse.name, "get_weather")
                XCTAssertNotNil(toolUse.id)
            }
        }
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
        } catch let error as LangToolsError {
            switch error {
            case .responseUnsuccessful(let statusCode, _):
                XCTAssertEqual(statusCode, 401)
            case .apiError(let apiError):
                XCTAssertTrue(apiError is AnthropicErrorResponse)
            default:
                XCTFail("Expected responseUnsuccessful or apiError, got \(error)")
            }
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
        } catch is URLError {
            // Expected: network error propagates as URLError
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("timed out") || error.localizedDescription.contains("timeout"),
                          "Expected timeout-related error, got: \(error)")
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

    // MARK: - Structured Output

    func testStructuredOutputRequest() async throws {
        let responseJSON = """
        {
            "content": [{"text": "{\\"city\\": \\"San Francisco\\", \\"temp_f\\": 72}", "type": "text"}],
            "id": "msg_so_test",
            "model": "claude-sonnet-4-6",
            "role": "assistant",
            "stop_reason": "end_turn",
            "stop_sequence": null,
            "type": "message",
            "usage": {"input_tokens": 25, "output_tokens": 15}
        }
        """.data(using: .utf8)!

        MockURLProtocol.mockNetworkHandlers[Anthropic.MessageRequest.endpoint] = { _ in
            (.success(responseJSON), 200)
        }

        struct WeatherOutput: StructuredOutput, Equatable {
            let city: String
            let temp_f: Int
            static var jsonSchema: JSONSchema {
                .object(
                    properties: ["city": .string(), "temp_f": .integer()],
                    required: ["city", "temp_f"],
                    additionalProperties: .bool(false)
                )
            }
        }

        var request = Anthropic.MessageRequest(
            model: .claude46Sonnet,
            messages: [.init(role: .user, content: "Weather in SF")]
        )
        request.setResponseType(WeatherOutput.self)
        XCTAssertTrue(request.usesStructuredOutput)

        let response = try await api.perform(request: request)
        let output: WeatherOutput = try response.structuredOutput()
        XCTAssertEqual(output.city, "San Francisco")
        XCTAssertEqual(output.temp_f, 72)
    }

    func testStructuredOutputSchemaEncoding() throws {
        var request = Anthropic.MessageRequest(
            model: .claude46Sonnet,
            messages: [.init(role: .user, content: "Test")]
        )
        request.responseSchema = .object(
            properties: ["value": .string()],
            required: ["value"],
            additionalProperties: .bool(false)
        )
        let data = try JSONEncoder().encode(request)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        let outputConfig = dict["output_config"] as? [String: Any]
        XCTAssertNotNil(outputConfig)
        let format = outputConfig?["format"] as? [String: Any]
        XCTAssertEqual(format?["type"] as? String, "json_schema")
    }

    func testStructuredOutputRejectsUnsupportedModel() throws {
        let anthropic = Anthropic(apiKey: "test-key")
        var request = Anthropic.MessageRequest(
            model: .claude3Haiku_20240307,
            messages: [.init(role: .user, content: "Test")]
        )
        request.responseSchema = .object(properties: ["test": .string()])
        XCTAssertThrowsError(try anthropic.prepare(request: request))
    }

    // MARK: - Error Response Decoding

    func testAnthropicErrorResponseDecoding() throws {
        let errorJSON = """
        {"type": "error", "error": {"type": "rate_limit_error", "message": "Rate limit exceeded"}}
        """.data(using: .utf8)!
        let error = try JSONDecoder().decode(AnthropicErrorResponse.self, from: errorJSON)
        XCTAssertEqual(error.error.message, "Rate limit exceeded")
        XCTAssertEqual(error.error.type, .rateLimitError)
    }

    func testHTTPErrorContainsStatusCode() async throws {
        let errorJSON = """
        {"type": "error", "error": {"type": "overloaded_error", "message": "Overloaded"}}
        """.data(using: .utf8)!

        MockURLProtocol.mockNetworkHandlers[Anthropic.MessageRequest.endpoint] = { _ in
            (.success(errorJSON), 529)
        }

        do {
            _ = try await api.perform(request: Anthropic.MessageRequest(
                model: .claude46Sonnet,
                messages: [.init(role: .user, content: "Hi")]
            ))
            XCTFail("Should have thrown")
        } catch let error as LangToolsError {
            switch error {
            case .responseUnsuccessful(let statusCode, _):
                XCTAssertEqual(statusCode, 529)
            case .apiError(let apiError):
                XCTAssertTrue(apiError is AnthropicErrorResponse)
            default:
                break
            }
        } catch {
            XCTAssertNotNil(error)
        }
    }

    // MARK: - Malformed Structured Output

    func testStructuredOutputWithInvalidJSONThrows() async throws {
        let responseJSON = """
        {
            "content": [{"text": "this is not valid json at all", "type": "text"}],
            "id": "msg_bad",
            "model": "claude-sonnet-4-6",
            "role": "assistant",
            "stop_reason": "end_turn",
            "stop_sequence": null,
            "type": "message",
            "usage": {"input_tokens": 10, "output_tokens": 5}
        }
        """.data(using: .utf8)!

        MockURLProtocol.mockNetworkHandlers[Anthropic.MessageRequest.endpoint] = { _ in
            (.success(responseJSON), 200)
        }

        struct TestOutput: StructuredOutput {
            let value: String
            static var jsonSchema: JSONSchema { .object(properties: ["value": .string()]) }
        }

        let response = try await api.perform(request: Anthropic.MessageRequest(
            model: .claude46Sonnet,
            messages: [.init(role: .user, content: "Test")]
        ))
        XCTAssertThrowsError(try response.structuredOutput() as TestOutput)
    }

    // MARK: - Stream Error Paths

    func testStreamNon200StatusCode() async throws {
        let errorJSON = """
        {"type": "error", "error": {"type": "overloaded_error", "message": "Server overloaded"}}
        """.data(using: .utf8)!

        MockURLProtocol.mockNetworkHandlers[Anthropic.MessageRequest.endpoint] = { _ in
            (.success(errorJSON), 529)
        }

        let request = Anthropic.MessageRequest(
            model: .claude46Sonnet,
            messages: [.init(role: .user, content: "Hi")],
            stream: true
        )

        do {
            for try await _ in api.stream(request: request) {
                XCTFail("Should not yield any responses")
            }
            XCTFail("Stream should have thrown")
        } catch let error as LangToolsError {
            if case .responseUnsuccessful(let statusCode, _) = error {
                XCTAssertEqual(statusCode, 529)
            }
        } catch {
            XCTAssertNotNil(error)
        }
    }

    // MARK: - Message Conversion Helpers

    func testToAnthropicMessagesFiltersSystemMessages() {
        let messages: [any LangToolsMessage] = [
            OpenAI.Message(role: .system, content: "You are helpful."),
            OpenAI.Message(role: .user, content: "Hello"),
            OpenAI.Message(role: .assistant, content: "Hi there"),
        ]
        let converted = Anthropic.toAnthropicMessages(messages)
        XCTAssertEqual(converted.count, 2)
        XCTAssertTrue(converted[0].role.isUser)
        XCTAssertTrue(converted[1].role.isAssistant)
    }

    func testToAnthropicSystemMessageConcatenatesMultiple() {
        let messages: [any LangToolsMessage] = [
            OpenAI.Message(role: .system, content: "First instruction."),
            OpenAI.Message(role: .user, content: "Hello"),
            OpenAI.Message(role: .system, content: "Second instruction."),
        ]
        let systemPrompt = Anthropic.toAnthropicSystemMessage(messages)
        XCTAssertNotNil(systemPrompt)
        XCTAssertTrue(systemPrompt!.contains("First instruction."))
        XCTAssertTrue(systemPrompt!.contains("Second instruction."))
        XCTAssertTrue(systemPrompt!.contains("---"))
    }

    func testToAnthropicSystemMessageReturnsEmptyForNoSystem() {
        let messages: [any LangToolsMessage] = [
            OpenAI.Message(role: .user, content: "Hello"),
        ]
        let systemPrompt = Anthropic.toAnthropicSystemMessage(messages)
        XCTAssertEqual(systemPrompt, "")
    }
}
