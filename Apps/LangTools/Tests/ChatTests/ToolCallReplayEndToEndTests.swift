//
//  ToolCallReplayEndToEndTests.swift
//  ChatTests
//

import Foundation
import LangTools
import OpenAI
import Ollama
import ChatUI
import XCTest
@testable import Chat

/// End-to-end replay coverage: a content-card message whose retained tool calls
/// have completed must survive the provider `chatRequest` conversion and the
/// account-proxy wire encoding with its card context, tool calls, and tool
/// results intact.
final class ToolCallReplayEndToEndTests: XCTestCase {

    // MARK: - Fixtures

    private let cardsJSON = #"[{"title":"Team sync","startDate":"2026-06-01T09:00:00Z"}]"#

    private func cardsContent() -> ContentCardsContent {
        ContentCardsContent(cardType: "calendarEvent", message: "Found 1 event", cardsJSON: cardsJSON, cardCount: 1)
    }

    private func completedToolCall(name: String = "calculate", id: String = "call-1", result: String = "2") -> ChatToolCall {
        ChatToolCall(id: id, name: name, arguments: #"{"expression":"1+1"}"#, status: .success, result: result)
    }

    private func cardsToolMessage() -> Message {
        Message(role: .assistant, contentType: .contentCards(cardsContent()), toolCalls: [completedToolCall()])
    }

    // MARK: - OpenAI chatRequest

    func testOpenAIChatRequestPreservesRetainedToolCallsAndCardContext() throws {
        let replayed = [cardsToolMessage()].toOpenAIMessages()
        XCTAssertEqual(replayed.count, 2)

        let request = try OpenAI.chatRequest(
            model: OpenAI.Model.gpt4o,
            messages: replayed,
            tools: nil,
            responseSchema: nil,
            toolEventHandler: { _ in }
        )
        let chatRequest = try XCTUnwrap(request as? OpenAI.ChatCompletionRequest)

        XCTAssertEqual(chatRequest.messages.count, 2)
        XCTAssertEqual(chatRequest.messages.map(\.role), [.assistant, .tool])
        XCTAssertEqual(chatRequest.messages[0].tool_calls?.count, 1)
        XCTAssertEqual(chatRequest.messages[0].tool_calls?[0].id, "call-1")
        XCTAssertEqual(chatRequest.messages[0].tool_calls?[0].function.name, "calculate")
        XCTAssertEqual(chatRequest.messages[0].tool_calls?[0].function.arguments, #"{"expression":"1+1"}"#)
        XCTAssertEqual(chatRequest.messages[0].content.string, cardsToolMessage().providerContext)
        XCTAssertTrue(chatRequest.messages[0].content.string?.contains("Team sync") ?? false)
        XCTAssertEqual(chatRequest.messages[1].tool_call_id, "call-1")
        guard case .toolResult(let toolResult) = chatRequest.messages[1].content.array?.first else {
            return XCTFail("Expected OpenAI tool result")
        }
        XCTAssertEqual(toolResult.result, "2")
    }

    func testOpenAIReasoningModelChatRequestPreservesToolCallsAndConvertsSystemRole() throws {
        let system = Message(text: "You are a helpful assistant.", role: .system)
        let replayed = ([system] + [cardsToolMessage()]).toOpenAIMessages()
        XCTAssertEqual(replayed.count, 3)

        let request = try OpenAI.chatRequest(
            model: OpenAI.Model.o3,
            messages: replayed,
            tools: nil,
            responseSchema: nil,
            toolEventHandler: { _ in }
        )
        let chatRequest = try XCTUnwrap(request as? OpenAI.ChatCompletionRequest)

        XCTAssertEqual(chatRequest.messages.count, 3)

        // Reasoning models translate system → developer without losing content.
        XCTAssertEqual(chatRequest.messages[0].role, OpenAI.Message.Role.developer)
        XCTAssertEqual(chatRequest.messages[0].content.string, "You are a helpful assistant.")

        // Retained tool calls and card context survive the reasoning conversion.
        XCTAssertEqual(chatRequest.messages[1].role, .assistant)
        XCTAssertEqual(chatRequest.messages[1].tool_calls?.count, 1)
        XCTAssertEqual(chatRequest.messages[1].tool_calls?[0].id, "call-1")
        XCTAssertEqual(chatRequest.messages[1].content.string, cardsToolMessage().providerContext)
        XCTAssertTrue(chatRequest.messages[1].content.string?.contains("Team sync") ?? false)

        // Tool-result identity survives too.
        XCTAssertEqual(chatRequest.messages[2].role, .tool)
        XCTAssertEqual(chatRequest.messages[2].tool_call_id, "call-1")
        guard case .toolResult(let toolResult) = chatRequest.messages[2].content.array?.first else {
            return XCTFail("Expected OpenAI tool result")
        }
        XCTAssertEqual(toolResult.result, "2")
    }

    func testOpenAIReasoningModelPreservesSystemMessageName() throws {
        let namedSystem = try OpenAI.Message(role: .system, content: .string("sys"), name: "instructor")
        let request = try OpenAI.chatRequest(
            model: OpenAI.Model.o4_mini,
            messages: [namedSystem],
            tools: nil,
            responseSchema: nil,
            toolEventHandler: { _ in }
        )
        let chatRequest = try XCTUnwrap(request as? OpenAI.ChatCompletionRequest)
        XCTAssertEqual(chatRequest.messages.count, 1)
        XCTAssertEqual(chatRequest.messages[0].role, OpenAI.Message.Role.developer)
        XCTAssertEqual(chatRequest.messages[0].name, "instructor")
        XCTAssertEqual(chatRequest.messages[0].content.string, "sys")
    }

    // MARK: - Ollama chatRequest

    func testOllamaChatRequestPreservesRetainedToolCallsAndCardContext() throws {
        let replayed = [cardsToolMessage()].toOllamaMessages()
        XCTAssertEqual(replayed.count, 2)

        let request = try Ollama.chatRequest(
            model: OllamaModel(rawValue: "llama3.2")!,
            messages: replayed,
            tools: nil,
            responseSchema: nil,
            toolEventHandler: { _ in }
        )
        let chatRequest = try XCTUnwrap(request as? Ollama.ChatRequest)

        XCTAssertEqual(chatRequest.messages.count, 2)
        XCTAssertEqual(chatRequest.messages.map(\.role), [.assistant, .tool])
        XCTAssertEqual(chatRequest.messages[0].tool_calls?.count, 1)
        XCTAssertEqual(chatRequest.messages[0].tool_calls?[0].name, "calculate")
        XCTAssertEqual(chatRequest.messages[0].tool_calls?[0].function.arguments, ["expression": "1+1"])
        XCTAssertEqual(chatRequest.messages[0].content.text, cardsToolMessage().providerContext)
        XCTAssertTrue(chatRequest.messages[0].content.text.contains("Team sync"))
        XCTAssertEqual(chatRequest.messages[1].content.text, "2")
    }

    // MARK: - Account proxy wire bodies

    func testAccountProxyNonStreamingBodyCarriesCardContextAndToolCalls() async throws {
        let captured = try await captureProxyBody(
            stream: false,
            respond: #"{"content":"ok"}"#
        )

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: captured) as? [String: Any])
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 3)

        // Leading user message stays plain text.
        XCTAssertEqual(messages[0]["role"] as? String, "user")
        XCTAssertEqual(messages[0]["content"] as? String, "Hello")

        // Card assistant message carries context + tool_calls.
        XCTAssertEqual(messages[1]["role"] as? String, "assistant")
        XCTAssertEqual(messages[1]["content"] as? String, cardsToolMessage().providerContext)
        let toolCalls = try XCTUnwrap(messages[1]["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(toolCalls.count, 1)
        XCTAssertEqual(toolCalls[0]["id"] as? String, "call-1")
        XCTAssertEqual(toolCalls[0]["type"] as? String, "function")
        let function = try XCTUnwrap(toolCalls[0]["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, "calculate")
        XCTAssertEqual(function["arguments"] as? String, #"{"expression":"1+1"}"#)

        // Trailing tool result message carries tool_call_id + result.
        XCTAssertEqual(messages[2]["role"] as? String, "tool")
        XCTAssertEqual(messages[2]["tool_call_id"] as? String, "call-1")
        XCTAssertEqual(messages[2]["content"] as? String, "2")
    }

    func testAccountProxyStreamingBodyCarriesCardContextAndToolCalls() async throws {
        let ndjson = """
        {"type":"delta","delta":"ok","content":null,"error":null}
        {"type":"complete","delta":null,"content":"ok","error":null}

        """
        let captured = try await captureProxyBody(stream: true, respond: ndjson)

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: captured) as? [String: Any])
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages[1]["role"] as? String, "assistant")
        XCTAssertEqual(messages[1]["content"] as? String, cardsToolMessage().providerContext)
        let toolCalls = try XCTUnwrap(messages[1]["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(toolCalls.count, 1)
        XCTAssertEqual(toolCalls[0]["id"] as? String, "call-1")
        XCTAssertEqual(messages[2]["role"] as? String, "tool")
        XCTAssertEqual(messages[2]["tool_call_id"] as? String, "call-1")
        XCTAssertEqual(messages[2]["content"] as? String, "2")
    }

    // MARK: - Helpers

    private func captureProxyBody(stream: Bool, respond responseBody: String) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ToolCallReplayProxyURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        var capturedBody: Data?
        ToolCallReplayProxyURLProtocol.requestHandler = { request in
            capturedBody = try ToolCallReplayProxyURLProtocol.requestBody(request)
            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(responseBody.utf8))
        }
        defer { ToolCallReplayProxyURLProtocol.requestHandler = nil }

        let transport = AccountProxyTransport(
            configuration: AccountBackendConfiguration(
                codexHelperBaseURL: URL(string: "http://127.0.0.1:9999")!,
                codexHelperToken: "helper-token"
            ),
            urlSession: urlSession
        )
        let session = AccountSession(
            provider: .openAI,
            accountIdentifier: "openai-user",
            accessToken: CodexSessionMarker.value,
            accessibleModelIDs: ["gpt-5.5"]
        )
        let messages: [Message] = [Message(text: "Hello", role: .user), cardsToolMessage()]

        if stream {
            let stream = try transport.streamChatCompletionRequest(
                messages: messages,
                model: .codex(.gpt5_5),
                session: session,
                stream: true,
                tools: nil,
                toolChoice: nil
            )
            for try await _ in stream {}
        } else {
            _ = try await transport.performChatCompletionRequest(
                messages: messages,
                model: .codex(.gpt5_5),
                session: session,
                tools: nil,
                toolChoice: nil
            )
        }

        return try XCTUnwrap(capturedBody)
    }
}

private final class ToolCallReplayProxyURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.requestHandler)
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func requestBody(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
            if count == 0 { break }
            body.append(buffer, count: count)
        }
        return body
    }
}
