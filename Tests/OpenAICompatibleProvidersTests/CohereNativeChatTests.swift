//
//  CohereNativeChatTests.swift
//  OpenAICompatibleProvidersTests
//

import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LangTools
@testable import TestUtils
import OpenAI
import OpenAICompatible
import Cohere

final class CohereNativeChatTests: MockSessionTestCase {



    private let weatherTool = OpenAI.Tool(
        name: "get_weather",
        description: "Current weather",
        tool_schema: .init(properties: ["city": .init(type: "string")], required: ["city"]),
        callback: { _, args in "Sunny in \(args["city"]?.stringValue ?? "?")" }
    )

    // MARK: - Requests

    func testNativeRequestTargetsV2ChatWithDocumentsAndCohereOptions() throws {
        var request = Cohere.ChatRequest(
            model: "command-a-03-2025",
            messages: [.init(role: .system, content: "Be brief."), .init(role: .user, content: "Hi")],
            tool_choice: .required,
            documents: [.string("Paris is in France."), .object(["id": .string("doc-1"), "data": .object(["title": .string("T")])])],
            p: 0.9,
            k: 40,
            thinking: ["type": .string("enabled"), "token_budget": .number(1024)]
        )
        request.responseSchema = .object(properties: ["answer": .string()])

        let urlRequest = try Cohere(apiKey: "key").prepare(request: request)

        XCTAssertEqual(urlRequest.url?.absoluteString, "https://api.cohere.com/v2/chat")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Authorization"), "Bearer key")
        let body = try body(of: urlRequest)
        XCTAssertEqual(body["model"] as? String, "command-a-03-2025")
        XCTAssertEqual(body["tool_choice"] as? String, "REQUIRED")
        XCTAssertEqual((body["documents"] as? [Any])?.count, 2)
        XCTAssertEqual(body["k"] as? Int, 40)
        XCTAssertEqual((body["thinking"] as? [String: Any])?["token_budget"] as? Int, 1024)
        let format = try XCTUnwrap(body["response_format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_object")
        XCTAssertNotNil(format["json_schema"] as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["system", "user"])
        XCTAssertEqual(messages[1]["content"] as? String, "Hi")
    }

    func testToolTurnsEncodeInCohereShape() throws {
        let call = Cohere.ToolCall(id: "call_1", name: "get_weather", arguments: #"{"city":"Paris"}"#)
        let request = Cohere.ChatRequest(model: "command-a-03-2025", messages: [
            .init(role: .user, content: "Weather?"),
            .init(tool_selection: [call]),
        ] + Cohere.Message.messages(for: [.init(tool_selection_id: "call_1", result: "Sunny")]))

        let messages = try XCTUnwrap(body(of: Cohere(apiKey: "key").prepare(request: request))["messages"] as? [[String: Any]])

        XCTAssertNil(messages[1]["content"])
        let toolCalls = try XCTUnwrap(messages[1]["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(toolCalls.first?["type"] as? String, "function")
        XCTAssertEqual((toolCalls.first?["function"] as? [String: Any])?["name"] as? String, "get_weather")
        XCTAssertEqual(messages[2]["role"] as? String, "tool")
        XCTAssertEqual(messages[2]["tool_call_id"] as? String, "call_1")
        XCTAssertEqual(messages[2]["content"] as? String, "Sunny")
    }

    func testNativeAndCompatibleRequestsBothRouteToCohere() throws {
        var toolchain = LangToolchain()
        toolchain.register(OpenAI(apiKey: "openai"))
        toolchain.register(Cohere(apiKey: "cohere"))
        let native = try XCTUnwrap(Cohere.chatRequest(model: "command-a-03-2025" as Cohere.Model, messages: [OpenAI.Message(role: .user, content: "Hi")], tools: nil, responseSchema: nil, toolEventHandler: { _ in }) as? Cohere.ChatRequest)
        let compatible = OpenAI.ChatCompletionRequest(model: "command-a-03-2025" as Cohere.Model, messages: [.init(role: .user, content: "Hi")])

        XCTAssertTrue(Cohere(apiKey: "key").canHandleRequest(native))
        XCTAssertTrue(Cohere(apiKey: "key").canHandleRequest(compatible))
        XCTAssertFalse(OpenAI(apiKey: "key").canHandleRequest(compatible))
        XCTAssertEqual(try Cohere(apiKey: "key").prepare(request: compatible).url?.absoluteString, "https://api.cohere.com/compatibility/v1/chat/completions")
    }

    func testOpenAIHistoryConvertsWithToolCallsAndResults() throws {
        let call = OpenAI.Message.ToolCall(index: 0, id: "call_1", type: .function, function: .init(name: "get_weather", arguments: #"{"city":"Paris"}"#))
        let history = [OpenAI.Message(role: .user, content: "Weather?"), OpenAI.Message(tool_selection: [call]), OpenAI.Message(tool_selection_id: "call_1", result: "Sunny")]

        let messages = history.map { Cohere.Message($0) }

        XCTAssertEqual(messages.map(\.role), [.user, .assistant, .tool])
        XCTAssertEqual(messages[1].tool_calls?.first?.id, "call_1")
        XCTAssertEqual(messages[1].tool_calls?.first?.arguments, #"{"city":"Paris"}"#)
        XCTAssertEqual(messages[2].tool_call_id, "call_1")
        XCTAssertEqual(messages[2].content.text, "Sunny")
    }

    // MARK: - Responses

    func testCompleteResponseDecodesTextCitationsAndUsage() async throws {
        let response = """
        {"id":"r1","finish_reason":"COMPLETE","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"Paris is in France."}],"citations":[{"start":0,"end":5,"text":"Paris","sources":[{"type":"document","id":"doc-0"}]}]},"usage":{"billed_units":{"input_tokens":10,"output_tokens":5},"tokens":{"input_tokens":20,"output_tokens":5}}}
        """
        MockURLProtocol.setHandler(for: "v2/chat") { _ in (.success(Data(response.utf8)), 200) }

        let result = try await Cohere(apiKey: "key", session: session).perform(request: Cohere.ChatRequest(model: "command-a-03-2025", messages: [.init(role: .user, content: "Where is Paris?")]))

        XCTAssertEqual(result.message?.content.text, "Paris is in France.")
        XCTAssertEqual(result.message?.citations?.first?.text, "Paris")
        XCTAssertEqual(result.usage?["billed_units"]?["output_tokens"]?.intValue, 5)
        XCTAssertEqual(result.finish_reason, "COMPLETE")
    }

    func testStreamAccumulatesTextToolPlanAndToolCalls() async throws {
        let stream = """
        event: message-start
        data: {"id":"r1","type":"message-start","delta":{"message":{"role":"assistant","content":[],"tool_plan":"","tool_calls":[],"citations":[]}}}

        data: {"type":"tool-plan-delta","delta":{"message":{"tool_plan":"I will look up "}}}

        data: {"type":"tool-plan-delta","delta":{"message":{"tool_plan":"the weather."}}}

        data: {"type":"tool-call-start","index":0,"delta":{"message":{"tool_calls":{"id":"call_1","type":"function","function":{"name":"get_weather","arguments":""}}}}}

        data: {"type":"tool-call-delta","index":0,"delta":{"message":{"tool_calls":{"function":{"arguments":"{\\"city\\":"}}}}}

        data: {"type":"tool-call-delta","index":0,"delta":{"message":{"tool_calls":{"function":{"arguments":"\\"Paris\\"}"}}}}}

        data: {"type":"tool-call-end","index":0}

        data: {"type":"message-end","delta":{"finish_reason":"TOOL_CALL","usage":{"billed_units":{"input_tokens":3,"output_tokens":4}}}}

        """
        MockURLProtocol.setHandler(for: "v2/chat") { _ in (.success(Data(stream.utf8)), 200) }

        var accumulated = Cohere.ChatResponse.empty
        let request = Cohere.ChatRequest(model: "command-a-03-2025", messages: [.init(role: .user, content: "Weather?")], stream: true)
        for try await chunk in Cohere(apiKey: "key", session: session).stream(request: request) {
            accumulated = accumulated.combining(with: chunk)
        }

        XCTAssertEqual(accumulated.message?.tool_plan, "I will look up the weather.")
        let call = try XCTUnwrap(accumulated.message?.tool_calls?.first)
        XCTAssertEqual(call.id, "call_1")
        XCTAssertEqual(call.name, "get_weather")
        XCTAssertEqual(call.arguments, #"{"city":"Paris"}"#)
        XCTAssertEqual(accumulated.finish_reason, "TOOL_CALL")
    }

    func testStreamedToolCallRunsTheToolAndContinues() async throws {
        let toolCallStream = """
        data: {"id":"r1","type":"message-start","delta":{"message":{"role":"assistant"}}}

        data: {"type":"tool-call-start","index":0,"delta":{"message":{"tool_calls":{"id":"call_1","type":"function","function":{"name":"get_weather","arguments":"{\\"city\\":\\"Paris\\"}"}}}}}

        data: {"type":"message-end","delta":{"finish_reason":"TOOL_CALL"}}

        """
        let answerStream = """
        data: {"type":"content-delta","index":0,"delta":{"message":{"content":{"text":"Sunny [DONE] today."}}}}

        data: {"type":"message-end","delta":{"finish_reason":"COMPLETE"}}

        data: [DONE]

        """
        var secondBody: [String: Any]?
        MockURLProtocol.setHandler(for: "v2/chat") { _ in
            MockURLProtocol.setHandler(for: "v2/chat") { request in
                secondBody = try? JSONSerialization.jsonObject(with: request.bodyData ?? Data()) as? [String: Any]
                return (.success(Data(answerStream.utf8)), 200)
            }
            return (.success(Data(toolCallStream.utf8)), 200)
        }

        let request = Cohere.ChatRequest(model: "command-a-03-2025", messages: [.init(role: .user, content: "Weather in Paris?")], stream: true, tools: [weatherTool])
        var text = ""
        for try await chunk in Cohere(apiKey: "key", session: session).stream(request: request) {
            text += chunk.delta?.content ?? ""
        }

        // A chunk whose text contains "[DONE]" is not mistaken for the sentinel.
        XCTAssertEqual(text, "Sunny [DONE] today.")
        let messages = try XCTUnwrap(secondBody?["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.last?["role"] as? String, "tool")
        XCTAssertEqual(messages.last?["tool_call_id"] as? String, "call_1")
        XCTAssertEqual(messages.last?["content"] as? String, "Sunny in Paris")
    }

    func testStreamWithoutMessageEndIsIncomplete() async throws {
        let stream = """
        data: {"type":"content-delta","index":0,"delta":{"message":{"content":{"text":"Hel"}}}}

        """
        MockURLProtocol.setHandler(for: "v2/chat") { _ in (.success(Data(stream.utf8)), 200) }

        do {
            for try await _ in Cohere(apiKey: "key", session: session).stream(request: Cohere.ChatRequest(model: "command-a-03-2025", messages: [.init(role: .user, content: "Hi")], stream: true)) {}
            XCTFail("Expected an incomplete stream")
        } catch LangToolsError.incompleteStream {}
    }

    func testMessageEndErrorEndsTheStream() async throws {
        let stream = """
        data: {"type":"message-end","delta":{"finish_reason":"ERROR","error":"internal error"}}

        """
        MockURLProtocol.setHandler(for: "v2/chat") { _ in (.success(Data(stream.utf8)), 200) }

        do {
            for try await _ in Cohere(apiKey: "key", session: session).stream(request: Cohere.ChatRequest(model: "command-a-03-2025", messages: [.init(role: .user, content: "Hi")], stream: true)) {}
            XCTFail("Expected the error to throw")
        } catch LangToolsError.apiError(let error as OpenAICompatibleErrorResponse) {
            XCTAssertEqual(error.message, "internal error")
        }
    }

    func testNullArgumentsReadAsEmpty() throws {
        let call = try JSONDecoder().decode(Cohere.ToolCall.self, from: Data(#"{"id":"c","type":"function","function":{"name":"now","arguments":"null"}}"#.utf8))
        XCTAssertEqual(call.arguments, "")
    }

    func testHTTPErrorDecodesCohereMessage() async throws {
        MockURLProtocol.setHandler(for: "v2/chat") { _ in (.success(Data(#"{"message":"invalid api token"}"#.utf8)), 401) }

        do {
            _ = try await Cohere(apiKey: "key", session: session).perform(request: Cohere.ChatRequest(model: "command-a-03-2025", messages: [.init(role: .user, content: "Hi")]))
            XCTFail("Expected a 401")
        } catch LangToolsError.responseUnsuccessful(let status, let error as OpenAICompatibleErrorResponse) {
            XCTAssertEqual(status, 401)
            XCTAssertEqual(error.message, "invalid api token")
        }
    }
}
