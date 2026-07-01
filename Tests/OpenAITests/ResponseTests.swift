//
//  ResponseTests.swift
//  OpenAITests
//
//  Tests for the OpenAI Responses API.
//

import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import TestUtils
@testable import OpenAI
@testable import LangTools

final class ResponseTests: XCTestCase {

    var api: OpenAI!

    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(MockURLProtocol.self)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        api = OpenAI(apiKey: "").configure(testURLSessionConfiguration: config)
    }

    override func tearDown() {
        MockURLProtocol.mockNetworkHandlers.removeAll()
        URLProtocol.unregisterClass(MockURLProtocol.self)
        super.tearDown()
    }

    // MARK: - Encoding

    func testRequestEncoding() throws {
        let request = OpenAI.ResponseRequest(
            model: .gpt4o_mini,
            messages: [OpenAI.Item(role: .user, content: "Hi")],
            instructions: "Be nice",
            tools: [.function(.init(
                name: "getWeather",
                description: "Get the weather",
                parameters: .init(properties: ["location": .init(type: "string")], required: ["location"])))],
            temperature: 0.5,
            max_output_tokens: 256)

        let json = try JSONSerialization.jsonObject(with: request.data()) as! [String: Any]
        XCTAssertEqual(json["model"] as? String, "gpt-4o-mini")
        XCTAssertEqual(json["instructions"] as? String, "Be nice")
        XCTAssertEqual(json["temperature"] as? Double, 0.5)
        XCTAssertEqual(json["max_output_tokens"] as? Int, 256)

        let input = json["input"] as! [[String: Any]]
        XCTAssertEqual(input.count, 1)
        XCTAssertEqual(input[0]["role"] as? String, "user")
        XCTAssertEqual(input[0]["content"] as? String, "Hi")

        let tools = json["tools"] as! [[String: Any]]
        XCTAssertEqual(tools[0]["type"] as? String, "function")
        XCTAssertEqual(tools[0]["name"] as? String, "getWeather")
        XCTAssertEqual(tools[0]["description"] as? String, "Get the weather")
        XCTAssertNotNil(tools[0]["parameters"])
    }

    func testToolCallAndResultFlattenedToInputItems() throws {
        let assistant = OpenAI.Item(tool_selection: [
            .init(index: 0, id: "call_9", type: .function, function: .init(name: "getWeather", arguments: "{\"location\":\"NYC\"}"))
        ])
        let toolResult = OpenAI.Item(tool_selection_id: "call_9", result: "sunny")
        let request = OpenAI.ResponseRequest(
            model: .gpt4o_mini,
            messages: [.init(role: .user, content: "weather?"), assistant, toolResult])

        let json = try JSONSerialization.jsonObject(with: request.data()) as! [String: Any]
        let input = json["input"] as! [[String: Any]]
        XCTAssertEqual(input.count, 3)

        XCTAssertEqual(input[0]["role"] as? String, "user")

        XCTAssertEqual(input[1]["type"] as? String, "function_call")
        XCTAssertEqual(input[1]["call_id"] as? String, "call_9")
        XCTAssertEqual(input[1]["name"] as? String, "getWeather")
        XCTAssertEqual(input[1]["arguments"] as? String, "{\"location\":\"NYC\"}")

        XCTAssertEqual(input[2]["type"] as? String, "function_call_output")
        XCTAssertEqual(input[2]["call_id"] as? String, "call_9")
        XCTAssertEqual(input[2]["output"] as? String, "sunny")
    }

    func testInitPreservesTextAndToolCallsFromMixedMessage() throws {
        let source = try OpenAI.Message(
            role: .assistant,
            content: .string("Checking now."),
            tool_calls: [.init(index: 0, id: "call_7", type: .function, function: .init(name: "lookup", arguments: "{}"))])
        let item = OpenAI.Item(source)
        XCTAssertEqual(item.content.string, "Checking now.")
        XCTAssertEqual(item.tool_calls?.first?.id, "call_7")
        XCTAssertEqual(item.tool_calls?.first?.name, "lookup")
    }

    func testEncodingItemWithTextAndToolCallDirectlyThrows() throws {
        let mixed = OpenAI.Item(
            role: .assistant,
            content: .string("text"),
            tool_calls: [.init(index: 0, id: "c1", type: .function, function: .init(name: "f", arguments: "{}"))])
        XCTAssertThrowsError(try JSONEncoder().encode(mixed))
    }

    func testAssistantTextAndToolCallsFlattenedToInputItems() throws {
        let assistant = OpenAI.Item(
            role: .assistant,
            content: .string("Let me check the weather."),
            tool_calls: [.init(index: 0, id: "call_3", type: .function, function: .init(name: "getWeather", arguments: "{}"))])
        let request = OpenAI.ResponseRequest(
            model: .gpt4o_mini,
            messages: [.init(role: .user, content: "weather?"), assistant])

        let json = try JSONSerialization.jsonObject(with: request.data()) as! [String: Any]
        let input = json["input"] as! [[String: Any]]
        // user message, assistant text message, function_call
        XCTAssertEqual(input.count, 3)
        XCTAssertEqual(input[1]["role"] as? String, "assistant")
        XCTAssertEqual(input[1]["content"] as? String, "Let me check the weather.")
        XCTAssertEqual(input[2]["type"] as? String, "function_call")
        XCTAssertEqual(input[2]["name"] as? String, "getWeather")
    }

    func testStructuredOutputEncoding() throws {
        var request = OpenAI.ResponseRequest(model: .gpt4o_mini, messages: [.init(role: .user, content: "Hi")])
        request.responseSchema = JSONSchema.object(
            properties: ["name": .string(), "age": .integer()],
            required: ["name", "age"],
            additionalProperties: .bool(false))

        XCTAssertTrue(request.usesStructuredOutput)

        let json = try JSONSerialization.jsonObject(with: request.data()) as! [String: Any]
        let text = json["text"] as! [String: Any]
        let format = text["format"] as! [String: Any]
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertEqual(format["strict"] as? Bool, true)
        XCTAssertNotNil(format["name"])
        XCTAssertNotNil(format["schema"])
    }

    func testReasoningEncoding() throws {
        let request = OpenAI.ResponseRequest(
            model: .o4_mini,
            messages: [OpenAI.Item(role: .user, content: "Think")],
            reasoning: .init(effort: .high, summary: .auto))
        let json = try JSONSerialization.jsonObject(with: request.data()) as! [String: Any]
        let reasoning = json["reasoning"] as! [String: Any]
        XCTAssertEqual(reasoning["effort"] as? String, "high")
        XCTAssertEqual(reasoning["summary"] as? String, "auto")
    }

    // MARK: - Response decoding

    func testResponseDecoding() throws {
        let data = try getData(filename: "response_create")!
        let response: OpenAI.ResponseResponse = try OpenAI.decodeResponse(data: data)
        XCTAssertEqual(response.id, "resp_abc123")
        XCTAssertEqual(response.status, "completed")
        XCTAssertEqual(response.outputText, "Hello there! How can I help you today?")
        XCTAssertEqual(response.message?.content.text, "Hello there! How can I help you today?")
        XCTAssertEqual(response.usage?.total_tokens, 19)
        XCTAssertEqual(response.usage?.input_tokens, 8)
        XCTAssertEqual(response.usage?.output_tokens, 11)
    }

    func testPerformResponse() async throws {
        MockURLProtocol.mockNetworkHandlers[OpenAI.ResponseRequest.endpoint] = { _ in
            return (.success(try self.getData(filename: "response_create")!), 200)
        }
        let response = try await api.perform(request: OpenAI.ResponseRequest(
            model: .gpt4o_mini,
            messages: [.init(role: .user, content: "Hi")]))
        XCTAssertEqual(response.outputText, "Hello there! How can I help you today?")
        XCTAssertEqual(response.usage?.total_tokens, 19)
    }

    // MARK: - Streaming

    func testResponseStream() async throws {
        MockURLProtocol.mockNetworkHandlers[OpenAI.ResponseRequest.endpoint] = { _ in
            return (.success(try self.getData(filename: "response_stream", fileExtension: "txt")!), 200)
        }
        var results: [OpenAI.ResponseResponse] = []
        for try await response in api.stream(request: OpenAI.ResponseRequest(
            model: .gpt4o_mini,
            messages: [OpenAI.Item(role: .user, content: "Hi")],
            stream: true)) {
            results.append(response)
        }
        let text = results.reduce("") { $0 + ($1.delta?.content ?? "") }
        XCTAssertEqual(text, "Hello, world!")
        XCTAssertEqual(results.last?.usage?.total_tokens, 15)
        XCTAssertEqual(results.last?.status, "completed")
    }

    func testFailedResponseStreamSurfacesError() async throws {
        // The `response.failed` payload omits `output`, exercising the tolerant decode.
        MockURLProtocol.mockNetworkHandlers[OpenAI.ResponseRequest.endpoint] = { _ in
            return (.success(try self.getData(filename: "response_failed_stream", fileExtension: "txt")!), 200)
        }
        var combined = OpenAI.ResponseResponse.empty
        for try await response in api.stream(request: OpenAI.ResponseRequest(
            model: .gpt4o_mini,
            messages: [OpenAI.Item(role: .user, content: "Hi")],
            stream: true)) {
            combined = combined.combining(with: response)
        }
        XCTAssertEqual(combined.status, "failed")
        XCTAssertEqual(combined.error?.code, "server_error")
        XCTAssertEqual(combined.error?.message, "boom")
    }

    func testToolCallStream() async throws {
        MockURLProtocol.mockNetworkHandlers[OpenAI.ResponseRequest.endpoint] = { _ in
            return (.success(try self.getData(filename: "response_tool_call_stream", fileExtension: "txt")!), 200)
        }
        let request = OpenAI.ResponseRequest(
            model: .gpt4o_mini,
            messages: [OpenAI.Item(role: .user, content: "weather?")],
            tools: [.function(.init(
                name: "getCurrentWeather",
                description: "Get the current weather",
                parameters: .init(properties: ["location": .init(type: "string")], required: ["location"])))],
            stream: true)

        var combined = OpenAI.ResponseResponse.empty
        for try await response in api.stream(request: request) {
            combined = combined.combining(with: response)
        }

        let call = combined.message?.tool_selection?.first
        XCTAssertEqual(call?.name, "getCurrentWeather")
        XCTAssertEqual(call?.id, "call_1")
        XCTAssertEqual(call?.arguments, "{\"location\":\"Bangkok\"}")
    }

    func testToolCallWithCallbackStream() async throws {
        let tools: [OpenAI.ResponseRequest.Tool] = [.function(.init(
            name: "getCurrentWeather",
            description: "Get the current weather",
            parameters: .init(properties: ["location": .init(type: "string")], required: ["location"]),
            callback: { _, _ in
                MockURLProtocol.mockNetworkHandlers[OpenAI.ResponseRequest.endpoint] = { _ in
                    return (.success(try self.getData(filename: "response_tool_call_stream_response", fileExtension: "txt")!), 200)
                }
                return "27"
            }))]

        MockURLProtocol.mockNetworkHandlers[OpenAI.ResponseRequest.endpoint] = { _ in
            return (.success(try self.getData(filename: "response_tool_call_stream", fileExtension: "txt")!), 200)
        }

        let request = OpenAI.ResponseRequest(
            model: .gpt4o_mini,
            messages: [OpenAI.Item(role: .user, content: "weather?")],
            tools: tools,
            stream: true)

        var results: [OpenAI.ResponseResponse] = []
        for try await response in api.stream(request: request) {
            results.append(response)
        }
        let text = results.reduce("") { $0 + ($1.delta?.content ?? "") }
        XCTAssertEqual(text, "It's 27°C in Bangkok.")
    }
}
