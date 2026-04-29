//
//  OpenAIIntegrationTests.swift
//  LangTools
//
//  Integration tests for OpenAI provider: full request/response flows,
//  error handling, streaming, tool calling, structured output, and edge cases.
//

import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LangTools
@testable import OpenAI
@testable import TestUtils
import PerformanceTestUtils

final class OpenAIIntegrationTests: XCTestCase {

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

    // MARK: - Basic Chat Completion

    func testPerformChatCompletion() async throws {
        MockURLProtocol.mockNetworkHandlers[OpenAI.ChatCompletionRequest.endpoint] = { _ in
            let data = PerformanceFixtures.openAIChatCompletionResponseJSON(choiceCount: 1)
            return (.success(data), 200)
        }
        let request = OpenAI.ChatCompletionRequest(
            model: .gpt4o,
            messages: [.init(role: .user, content: "Hello")]
        )
        let response = try await api.perform(request: request)

        XCTAssertEqual(response.id, "chatcmpl-perf-test-1")
        XCTAssertEqual(response.object, "chat.completion")
        XCTAssertEqual(response.choices.count, 1)
        XCTAssertEqual(response.choices[0].finish_reason, .stop)
        XCTAssertNotNil(response.choices[0].message?.content.string)
        XCTAssertEqual(response.usage?.prompt_tokens, 50)
        XCTAssertEqual(response.usage?.total_tokens, 150)
    }

    func testPerformChatCompletionWithMultipleChoices() async throws {
        MockURLProtocol.mockNetworkHandlers[OpenAI.ChatCompletionRequest.endpoint] = { _ in
            let data = PerformanceFixtures.openAIChatCompletionResponseJSON(choiceCount: 3)
            return (.success(data), 200)
        }
        let request = OpenAI.ChatCompletionRequest(
            model: .gpt4o,
            messages: [.init(role: .user, content: "Hello")],
            n: 3
        )
        let response = try await api.perform(request: request)

        XCTAssertEqual(response.choices.count, 3)
        for i in 0..<3 {
            XCTAssertEqual(response.choices[i].index, i)
            XCTAssertNotNil(response.choices[i].message)
        }
    }

    // MARK: - Streaming Chat Completion

    func testStreamChatCompletion() async throws {
        let streamData = PerformanceFixtures.openAIStreamChunksData(chunkCount: 5)
        MockURLProtocol.mockNetworkHandlers[OpenAI.ChatCompletionRequest.endpoint] = { _ in
            (.success(streamData), 200)
        }
        let request = OpenAI.ChatCompletionRequest(
            model: .gpt4o,
            messages: [.init(role: .user, content: "Hello")],
            stream: true
        )
        var results: [OpenAI.ChatCompletionResponse] = []
        for try await response in api.stream(request: request) {
            results.append(response)
        }

        XCTAssertGreaterThan(results.count, 1)
        // First chunk should have role
        XCTAssertEqual(results[0].choices[0].delta?.role, .assistant)
        // Last content chunk should have finish_reason
        let lastWithChoices = results.last(where: { !$0.choices.isEmpty })
        XCTAssertNotNil(lastWithChoices)
    }

    func testStreamChatCompletionAccumulatesContent() async throws {
        let streamData = PerformanceFixtures.openAIStreamChunksData(chunkCount: 10)
        MockURLProtocol.mockNetworkHandlers[OpenAI.ChatCompletionRequest.endpoint] = { _ in
            (.success(streamData), 200)
        }
        let request = OpenAI.ChatCompletionRequest(
            model: .gpt4o,
            messages: [.init(role: .user, content: "Hello")],
            stream: true
        )
        var content = ""
        for try await response in api.stream(request: request) {
            content += response.choices.first?.delta?.content ?? ""
        }
        // Should have accumulated all word chunks
        for i in 0..<10 {
            XCTAssertTrue(content.contains("word\(i)"), "Missing word\(i) in accumulated content")
        }
    }

    // MARK: - Tool Calling

    func testStreamToolCalling() async throws {
        let streamData = PerformanceFixtures.openAIToolCallStreamData(toolCount: 1)
        MockURLProtocol.mockNetworkHandlers[OpenAI.ChatCompletionRequest.endpoint] = { _ in
            (.success(streamData), 200)
        }
        let request = OpenAI.ChatCompletionRequest(
            model: .gpt4o,
            messages: [.init(role: .user, content: "What's the weather?")],
            stream: true,
            tools: [.function(.init(
                name: "get_weather",
                description: "Get weather",
                parameters: .init(
                    properties: ["location": .init(type: "string")],
                    required: ["location"]
                )
            ))]
        )
        var results: [OpenAI.ChatCompletionResponse] = []
        for try await response in api.stream(request: request) {
            results.append(response)
        }

        XCTAssertEqual(results[0].choices[0].delta?.role, .assistant)
        let toolCallChunks = results.filter { $0.choices.first?.delta?.tool_calls != nil }
        XCTAssertGreaterThan(toolCallChunks.count, 0)
        // Verify tool name from first tool call chunk
        let firstToolChunk = toolCallChunks[0]
        XCTAssertEqual(firstToolChunk.choices[0].delta?.tool_calls?[0].function.name, "get_weather")
        // Accumulate and verify argument JSON
        let arguments = results.reduce("") { $0 + (!$1.choices.isEmpty ? ($1.choices[0].delta?.tool_calls?[0].function.arguments ?? "") : "") }
        XCTAssertTrue(arguments.contains("City0"), "Arguments should contain location City0")
        // Final chunk should have tool_calls finish reason
        let finishChunk = results.first(where: { $0.choices.first?.finish_reason == .tool_calls })
        XCTAssertNotNil(finishChunk)
    }

    func testToolCallWithCallbackCompletesFullFlow() async throws {
        // First response: tool call
        let toolStreamData = PerformanceFixtures.openAIToolCallStreamData(toolCount: 1)
        // Second response: final text response after tool execution
        let finalStreamData = PerformanceFixtures.openAIStreamChunksData(chunkCount: 3)

        var callCount = 0
        MockURLProtocol.mockNetworkHandlers[OpenAI.ChatCompletionRequest.endpoint] = { _ in
            callCount += 1
            return (.success(toolStreamData), 200)
        }

        var toolWasCalled = false
        let tools: [OpenAI.Tool] = [.function(.init(
            name: "get_weather",
            description: "Get weather",
            parameters: .init(
                properties: ["location": .init(type: "string")],
                required: ["location"]
            ),
            callback: { _, args in
                toolWasCalled = true
                MockURLProtocol.mockNetworkHandlers[OpenAI.ChatCompletionRequest.endpoint] = { _ in
                    (.success(finalStreamData), 200)
                }
                return "72°F and sunny"
            }
        ))]
        let request = OpenAI.ChatCompletionRequest(
            model: .gpt4o,
            messages: [.init(role: .user, content: "Weather in SF?")],
            stream: true,
            tools: tools
        )

        var results: [OpenAI.ChatCompletionResponse] = []
        for try await response in api.stream(request: request) {
            results.append(response)
        }

        XCTAssertTrue(toolWasCalled)
        XCTAssertGreaterThan(results.count, 1)
    }

    // MARK: - Error Handling

    func testHandlesHTTPErrorResponse() async throws {
        let errorJSON = """
        {"error": {"message": "Invalid API key", "type": "authentication_error", "param": null, "code": "invalid_api_key"}}
        """.data(using: .utf8)!

        MockURLProtocol.mockNetworkHandlers[OpenAI.ChatCompletionRequest.endpoint] = { _ in
            (.success(errorJSON), 401)
        }
        let request = OpenAI.ChatCompletionRequest(
            model: .gpt4o,
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
                XCTAssertTrue(apiError is OpenAIErrorResponse)
            default:
                XCTFail("Expected responseUnsuccessful or apiError, got \(error)")
            }
        }
    }

    func testHandlesNetworkError() async throws {
        let networkError = URLError(.notConnectedToInternet)
        MockURLProtocol.mockNetworkHandlers[OpenAI.ChatCompletionRequest.endpoint] = { _ in
            (.failure(networkError), nil)
        }
        let request = OpenAI.ChatCompletionRequest(
            model: .gpt4o,
            messages: [.init(role: .user, content: "Hello")]
        )

        do {
            _ = try await api.perform(request: request)
            XCTFail("Should have thrown an error")
        } catch is URLError {
            // Expected: network error propagates as URLError
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Internet") || error.localizedDescription.contains("network"),
                          "Expected network-related error, got: \(error)")
        }
    }

    // MARK: - Message Types

    func testSystemMessageInConversation() async throws {
        MockURLProtocol.mockNetworkHandlers[OpenAI.ChatCompletionRequest.endpoint] = { _ in
            let data = PerformanceFixtures.openAIChatCompletionResponseJSON(choiceCount: 1)
            return (.success(data), 200)
        }
        let request = OpenAI.ChatCompletionRequest(
            model: .gpt4o,
            messages: [
                .init(role: .system, content: "You are a helpful assistant."),
                .init(role: .user, content: "Hello"),
            ]
        )
        let response = try await api.perform(request: request)
        XCTAssertNotNil(response.choices.first?.message)
    }

    func testDeveloperRoleMessage() throws {
        let message = OpenAI.Message(role: .developer, content: "Developer instructions here")
        XCTAssertFalse(message.role.isUser)
        XCTAssertFalse(message.role.isAssistant)
    }

    // MARK: - Request Configuration

    func testRequestWithAllParameters() throws {
        let request = OpenAI.ChatCompletionRequest(
            model: .gpt4o,
            messages: [.init(role: .user, content: "Hi")],
            temperature: 0.7,
            top_p: 0.9,
            n: 2,
            max_completion_tokens: 1000,
            presence_penalty: 0.5,
            frequency_penalty: 0.3,
            seed: 42
        )
        let data = try JSONEncoder().encode(request)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(dict["temperature"] as? Double, 0.7)
        XCTAssertEqual(dict["top_p"] as? Double, 0.9)
        XCTAssertEqual(dict["n"] as? Int, 2)
        XCTAssertEqual(dict["max_completion_tokens"] as? Int, 1000)
        XCTAssertEqual(dict["presence_penalty"] as? Double, 0.5)
        XCTAssertEqual(dict["frequency_penalty"] as? Double, 0.3)
        XCTAssertEqual(dict["seed"] as? Int, 42)
    }

    func testRequestPreparationSetsCorrectHeaders() throws {
        let request = OpenAI.ChatCompletionRequest(
            model: .gpt4o,
            messages: [.init(role: .user, content: "Hi")]
        )
        let urlRequest = try api.prepare(request: request)

        XCTAssertTrue(urlRequest.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") ?? false)
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(urlRequest.httpMethod, "POST")
        XCTAssertTrue(urlRequest.url?.absoluteString.contains("chat/completions") ?? false)
    }

    // MARK: - Logprobs

    func testResponseWithLogprobs() async throws {
        let data = PerformanceFixtures.openAIChatCompletionResponseJSON(choiceCount: 1)
        MockURLProtocol.mockNetworkHandlers[OpenAI.ChatCompletionRequest.endpoint] = { _ in
            (.success(data), 200)
        }
        let request = OpenAI.ChatCompletionRequest(
            model: .gpt4o,
            messages: [.init(role: .user, content: "Hi")],
            logprobs: true,
            top_logprobs: 2
        )
        let response = try await api.perform(request: request)

        let logprobs = response.choices[0].logprobs
        XCTAssertNotNil(logprobs)
        XCTAssertNotNil(logprobs?.content)
        XCTAssertGreaterThan(logprobs?.content?.count ?? 0, 0)
    }

    // MARK: - Usage Tracking

    func testUsageStatistics() async throws {
        let data = PerformanceFixtures.openAIChatCompletionResponseJSON(choiceCount: 1)
        MockURLProtocol.mockNetworkHandlers[OpenAI.ChatCompletionRequest.endpoint] = { _ in
            (.success(data), 200)
        }
        let response = try await api.perform(request: OpenAI.ChatCompletionRequest(
            model: .gpt4o,
            messages: [.init(role: .user, content: "Hi")]
        ))

        XCTAssertNotNil(response.usage)
        XCTAssertEqual(response.usage?.prompt_tokens, 50)
        XCTAssertEqual(response.usage?.completion_tokens, 100)
        XCTAssertEqual(response.usage?.total_tokens, 150)
    }

    // MARK: - Large Conversation Handling

    func testLargeConversationHistory() async throws {
        MockURLProtocol.mockNetworkHandlers[OpenAI.ChatCompletionRequest.endpoint] = { _ in
            let data = PerformanceFixtures.openAIChatCompletionResponseJSON(choiceCount: 1)
            return (.success(data), 200)
        }
        var messages: [OpenAI.Message] = [.init(role: .system, content: "You are helpful.")]
        for i in 0..<50 {
            messages.append(.init(role: .user, content: "User message \(i) with some content."))
            messages.append(.init(role: .assistant, content: "Assistant response \(i) with details."))
        }
        messages.append(.init(role: .user, content: "Final question"))

        let request = OpenAI.ChatCompletionRequest(model: .gpt4o, messages: messages)
        let response = try await api.perform(request: request)
        XCTAssertNotNil(response.choices.first?.message)
    }

    // MARK: - Sequential Requests

    func testSequentialRequestsReuseProvider() async throws {
        for i in 0..<3 {
            MockURLProtocol.mockNetworkHandlers[OpenAI.ChatCompletionRequest.endpoint] = { _ in
                let data = PerformanceFixtures.openAIChatCompletionResponseJSON(choiceCount: 1)
                return (.success(data), 200)
            }

            let request = OpenAI.ChatCompletionRequest(
                model: .gpt4o,
                messages: [.init(role: .user, content: "Request \(i)")]
            )
            let response = try await api.perform(request: request)
            XCTAssertNotNil(response.choices.first?.message)
            XCTAssertEqual(response.choices.count, 1)
        }
    }

    // MARK: - Custom Base URL

    func testCustomBaseURL() throws {
        let customAPI = OpenAI(baseURL: URL(string: "https://custom-api.example.com/v2/")!, apiKey: "test-key")
        let request = OpenAI.ChatCompletionRequest(
            model: .gpt4o,
            messages: [.init(role: .user, content: "Hi")]
        )
        let urlRequest = try customAPI.prepare(request: request)
        XCTAssertTrue(urlRequest.url?.absoluteString.hasPrefix("https://custom-api.example.com/v2/") ?? false)
    }

    // MARK: - Structured Output

    func testStructuredOutputRequest() async throws {
        let responseJSON = """
        {
            "id": "chatcmpl-so",
            "object": "chat.completion",
            "created": 1700000000,
            "model": "gpt-4o",
            "choices": [{
                "index": 0,
                "message": {"role": "assistant", "content": "{\\"name\\": \\"San Francisco\\", \\"temperature\\": 72.0}"},
                "finish_reason": "stop"
            }],
            "usage": {"prompt_tokens": 25, "completion_tokens": 15, "total_tokens": 40}
        }
        """.data(using: .utf8)!

        MockURLProtocol.mockNetworkHandlers[OpenAI.ChatCompletionRequest.endpoint] = { _ in
            (.success(responseJSON), 200)
        }

        struct WeatherOutput: StructuredOutput, Equatable {
            let name: String
            let temperature: Double
            static var jsonSchema: JSONSchema {
                .object(
                    properties: ["name": .string(), "temperature": .number()],
                    required: ["name", "temperature"],
                    additionalProperties: .bool(false)
                )
            }
        }

        var request = OpenAI.ChatCompletionRequest(
            model: .gpt4o,
            messages: [.init(role: .user, content: "Weather in SF")]
        )
        request.setResponseType(WeatherOutput.self)
        XCTAssertTrue(request.usesStructuredOutput)

        let response = try await api.perform(request: request)
        let output: WeatherOutput = try response.structuredOutput()
        XCTAssertEqual(output.name, "San Francisco")
        XCTAssertEqual(output.temperature, 72.0)
    }

    func testStructuredOutputSchemaEncoding() throws {
        var request = OpenAI.ChatCompletionRequest(
            model: .gpt4o,
            messages: [.init(role: .user, content: "Test")]
        )
        request.responseSchema = .object(
            properties: ["value": .string()],
            required: ["value"],
            additionalProperties: .bool(false)
        )
        let data = try JSONEncoder().encode(request)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        let responseFormat = dict["response_format"] as? [String: Any]
        XCTAssertNotNil(responseFormat)
        XCTAssertEqual(responseFormat?["type"] as? String, "json_schema")
    }

    // MARK: - Error Response Decoding

    func testOpenAIErrorResponseDecoding() throws {
        let errorJSON = """
        {"error": {"message": "Rate limit exceeded", "type": "rate_limit_error", "param": null, "code": "rate_limit_exceeded"}}
        """.data(using: .utf8)!
        let error = try JSONDecoder().decode(OpenAIErrorResponse.self, from: errorJSON)
        XCTAssertEqual(error.error.message, "Rate limit exceeded")
        XCTAssertEqual(error.error.type, "rate_limit_error")
    }

    func testHTTPErrorContainsStatusCode() async throws {
        let errorJSON = """
        {"error": {"message": "Model not found", "type": "invalid_request_error", "param": "model", "code": "model_not_found"}}
        """.data(using: .utf8)!

        MockURLProtocol.mockNetworkHandlers[OpenAI.ChatCompletionRequest.endpoint] = { _ in
            (.success(errorJSON), 404)
        }

        do {
            _ = try await api.perform(request: OpenAI.ChatCompletionRequest(
                model: .gpt4o,
                messages: [.init(role: .user, content: "Hi")]
            ))
            XCTFail("Should have thrown")
        } catch let error as LangToolsError {
            switch error {
            case .responseUnsuccessful(let statusCode, _):
                XCTAssertEqual(statusCode, 404)
            case .apiError(let apiError):
                XCTAssertTrue(apiError is OpenAIErrorResponse)
            default:
                break // Other LangToolsError variants are also acceptable
            }
        } catch {
            XCTAssertNotNil(error)
        }
    }

    // MARK: - Malformed Structured Output

    func testStructuredOutputWithInvalidJSONThrows() async throws {
        let responseJSON = """
        {
            "id": "chatcmpl-bad",
            "object": "chat.completion",
            "created": 1700000000,
            "model": "gpt-4o",
            "choices": [{
                "index": 0,
                "message": {"role": "assistant", "content": "this is not valid json at all"},
                "finish_reason": "stop"
            }],
            "usage": {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15}
        }
        """.data(using: .utf8)!

        MockURLProtocol.mockNetworkHandlers[OpenAI.ChatCompletionRequest.endpoint] = { _ in
            (.success(responseJSON), 200)
        }

        struct TestOutput: StructuredOutput {
            let value: String
            static var jsonSchema: JSONSchema { .object(properties: ["value": .string()]) }
        }

        let response = try await api.perform(request: OpenAI.ChatCompletionRequest(
            model: .gpt4o,
            messages: [.init(role: .user, content: "Test")]
        ))
        XCTAssertThrowsError(try response.structuredOutput() as TestOutput)
    }

    // MARK: - Tool Callback Error Handling

    func testToolCallbackErrorReturnsErrorResult() async throws {
        let toolStreamData = PerformanceFixtures.openAIToolCallStreamData(toolCount: 1)
        let finalStreamData = PerformanceFixtures.openAIStreamChunksData(chunkCount: 2)

        MockURLProtocol.mockNetworkHandlers[OpenAI.ChatCompletionRequest.endpoint] = { _ in
            (.success(toolStreamData), 200)
        }

        struct ToolError: Error, LocalizedError {
            var errorDescription: String? { "Tool execution failed" }
        }

        var errorEventFired = false
        let tools: [OpenAI.Tool] = [.function(.init(
            name: "get_weather",
            description: "Get weather",
            parameters: .init(
                properties: ["location": .init(type: "string")],
                required: ["location"]
            ),
            callback: { _, _ in
                MockURLProtocol.mockNetworkHandlers[OpenAI.ChatCompletionRequest.endpoint] = { _ in
                    (.success(finalStreamData), 200)
                }
                throw ToolError()
            }
        ))]
        let request = OpenAI.ChatCompletionRequest(
            model: .gpt4o,
            messages: [.init(role: .user, content: "Weather?")],
            stream: true,
            tools: tools,
            toolEventHandler: { event in
                if case .toolCompleted(let result) = event, result?.is_error == true {
                    errorEventFired = true
                }
            }
        )
        var results: [OpenAI.ChatCompletionResponse] = []
        for try await response in api.stream(request: request) {
            results.append(response)
        }
        XCTAssertTrue(errorEventFired, "Tool error event should have fired")
    }

    // MARK: - Stream Error Paths

    func testStreamNon200StatusCode() async throws {
        let errorJSON = """
        {"error": {"message": "Server error", "type": "server_error", "param": null, "code": null}}
        """.data(using: .utf8)!

        MockURLProtocol.mockNetworkHandlers[OpenAI.ChatCompletionRequest.endpoint] = { _ in
            (.success(errorJSON), 500)
        }

        let request = OpenAI.ChatCompletionRequest(
            model: .gpt4o,
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
                XCTAssertEqual(statusCode, 500)
            }
        } catch {
            XCTAssertNotNil(error)
        }
    }
}
