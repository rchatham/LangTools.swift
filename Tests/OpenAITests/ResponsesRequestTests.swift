import XCTest
@testable import LangTools
@testable import OpenAI

final class ResponsesRequestTests: XCTestCase {
    func testResponsesRequestEncodesInputToolsAndStructuredOutput() throws {
        var request = OpenAI.ResponsesRequest(
            model: .gpt4o_mini,
            messages: [
                .init(role: .system, content: "Be concise."),
                .init(role: .user, content: "What is the weather?")
            ],
            tools: [
                .function(.init(
                    name: "get_weather",
                    description: "Get weather",
                    parameters: .init(
                        properties: ["location": .init(type: "string")],
                        required: ["location"]
                    )
                ))
            ]
        )
        request.responseSchema = .object(
            properties: ["answer": .string()],
            required: ["answer"],
            additionalProperties: .bool(false)
        )

        let data = try JSONEncoder().encode(request)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["model"] as? String, OpenAI.Model.gpt4o_mini.rawValue)
        XCTAssertEqual(json["instructions"] as? String, "Be concise.")

        let input = try XCTUnwrap(json["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 1)
        XCTAssertEqual(input[0]["type"] as? String, "message")
        XCTAssertEqual(input[0]["role"] as? String, "user")
        let content = try XCTUnwrap(input[0]["content"] as? [[String: Any]])
        XCTAssertEqual(content[0]["type"] as? String, "input_text")
        XCTAssertEqual(content[0]["text"] as? String, "What is the weather?")

        let tools = try XCTUnwrap(json["tools"] as? [[String: Any]])
        XCTAssertEqual(tools[0]["type"] as? String, "function")
        XCTAssertEqual(tools[0]["name"] as? String, "get_weather")
        XCTAssertNotNil(tools[0]["parameters"])
        XCTAssertNil(tools[0]["function"], "Responses API tools should use flattened function schema")

        let text = try XCTUnwrap(json["text"] as? [String: Any])
        let format = try XCTUnwrap(text["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertEqual(format["strict"] as? Bool, true)
    }

    func testResponsesRequestEncodesForcedToolChoiceFlattened() throws {
        let request = OpenAI.ResponsesRequest(
            model: .gpt4o_mini,
            messages: [.init(role: .user, content: "Use a tool")],
            tool_choice: .tool("get_weather")
        )

        let data = try JSONEncoder().encode(request)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let toolChoice = try XCTUnwrap(json["tool_choice"] as? [String: Any])

        XCTAssertEqual(toolChoice["type"] as? String, "function")
        XCTAssertEqual(toolChoice["name"] as? String, "get_weather")
        XCTAssertNil(toolChoice["function"], "Responses API forced tool choice should be flattened")
    }

    func testResponsesRequestEncodesToolCallRoundTripMessages() throws {
        let toolCall = OpenAI.Message.ToolCall(
            index: 0,
            id: "call_123",
            type: .function,
            function: .init(name: "get_weather", arguments: "{\"location\":\"Bangkok\"}")
        )
        let request = OpenAI.ResponsesRequest(
            model: .gpt4o_mini,
            messages: [
                .init(tool_selection: [toolCall]),
                .init(tool_selection_id: "call_123", result: "Sunny")
            ]
        )

        let data = try JSONEncoder().encode(request)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let input = try XCTUnwrap(json["input"] as? [[String: Any]])

        XCTAssertEqual(input[0]["type"] as? String, "function_call")
        XCTAssertEqual(input[0]["call_id"] as? String, "call_123")
        XCTAssertEqual(input[0]["name"] as? String, "get_weather")
        XCTAssertEqual(input[1]["type"] as? String, "function_call_output")
        XCTAssertEqual(input[1]["call_id"] as? String, "call_123")
        XCTAssertEqual(input[1]["output"] as? String, "Sunny")
    }

    func testResponsesResponseDecodesTextAndToolCalls() throws {
        let data = Data("""
        {
          "id": "resp_123",
          "object": "response",
          "created_at": 1710000000,
          "status": "completed",
          "model": "gpt-4o-mini",
          "output": [
            {
              "id": "msg_123",
              "type": "message",
              "role": "assistant",
              "content": [{"type":"output_text","text":"Hello"}]
            },
            {
              "id": "fc_123",
              "type": "function_call",
              "call_id": "call_123",
              "name": "get_weather",
              "arguments": "{\\\"location\\\":\\\"Bangkok\\\"}"
            }
          ],
          "usage": {"input_tokens": 5, "output_tokens": 7, "total_tokens": 12}
        }
        """.utf8)

        let response = try JSONDecoder().decode(OpenAI.ResponsesResponse.self, from: data)

        XCTAssertEqual(response.id, "resp_123")
        XCTAssertEqual(response.message?.content.string, "Hello")
        XCTAssertEqual(response.message?.tool_selection?.first?.id, "call_123")
        XCTAssertEqual(response.message?.tool_selection?.first?.name, "get_weather")
        XCTAssertEqual(response.usage?.total_tokens, 12)
    }

    func testResponsesResponseDecodesRefusalContent() throws {
        let data = Data("""
        {
          "id": "resp_refusal",
          "object": "response",
          "status": "completed",
          "model": "gpt-4o-mini",
          "output": [
            {
              "id": "msg_refusal",
              "type": "message",
              "role": "assistant",
              "content": [{"type":"refusal","refusal":"I can’t help with that."}]
            }
          ]
        }
        """.utf8)

        let response = try JSONDecoder().decode(OpenAI.ResponsesResponse.self, from: data)

        XCTAssertEqual(response.message?.refusal, "I can’t help with that.")
        XCTAssertNil(response.message?.content.string)
    }

    func testResponsesStreamAccumulation() throws {
        let lines = [
            "event: response.output_item.added",
            "data: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[]}}",
            "event: response.output_text.delta",
            "data: {\"type\":\"response.output_text.delta\",\"output_index\":0,\"content_index\":0,\"delta\":\"Hel\"}",
            "data: {\"type\":\"response.output_text.delta\",\"output_index\":0,\"content_index\":0,\"delta\":\"lo\"}",
            "event: response.output_item.added",
            "data: {\"type\":\"response.output_item.added\",\"output_index\":1,\"item\":{\"type\":\"function_call\",\"call_id\":\"call_123\",\"name\":\"get_weather\",\"arguments\":\"\"}}",
            "data: {\"type\":\"response.function_call_arguments.delta\",\"output_index\":1,\"delta\":\"{\\\"location\\\"\"}",
            "data: {\"type\":\"response.function_call_arguments.delta\",\"output_index\":1,\"delta\":\":\\\"Bangkok\\\"}\"}",
            "data: [DONE]"
        ]

        var combined = OpenAI.ResponsesResponse.empty
        var decodedCount = 0
        var deltas: [OpenAI.Message.Delta] = []
        for line in lines {
            let response: OpenAI.ResponsesResponse? = try OpenAI.decodeStream(line)
            if let response {
                decodedCount += 1
                if let delta = response.delta { deltas.append(delta) }
                combined = combined.combining(with: response)
            }
        }

        XCTAssertEqual(decodedCount, 6)
        XCTAssertEqual(deltas.first(where: { $0.tool_calls?.first?.id == "call_123" })?.tool_calls?.first?.name, "get_weather")
        XCTAssertEqual(combined.message?.content.string, "Hello")
        XCTAssertEqual(combined.message?.tool_selection?.first?.id, "call_123")
        XCTAssertEqual(combined.message?.tool_selection?.first?.arguments, "{\"location\":\"Bangkok\"}")
    }

    func testResponsesStreamRefusalDeltaPreservesRefusal() throws {
        let lines = [
            "data: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[]}}",
            "data: {\"type\":\"response.refusal.delta\",\"output_index\":0,\"content_index\":0,\"delta\":\"I can’t\"}",
            "data: {\"type\":\"response.refusal.delta\",\"output_index\":0,\"content_index\":0,\"delta\":\" help.\"}"
        ]

        var combined = OpenAI.ResponsesResponse.empty
        var deltas: [OpenAI.Message.Delta] = []
        for line in lines {
            let response: OpenAI.ResponsesResponse? = try OpenAI.decodeStream(line)
            if let response {
                if let delta = response.delta { deltas.append(delta) }
                combined = combined.combining(with: response)
            }
        }

        XCTAssertEqual(deltas.compactMap(\.refusal).joined(), "I can’t help.")
        XCTAssertEqual(combined.message?.refusal, "I can’t help.")
        XCTAssertNil(combined.message?.content.string)
    }

    func testResponsesStreamIgnoresOutOfRangeIndexes() throws {
        let lines = [
            "data: {\"type\":\"response.output_item.added\",\"output_index\":999999,\"item\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[]}}",
            "data: {\"type\":\"response.output_text.delta\",\"output_index\":999999,\"content_index\":0,\"delta\":\"ignored\"}",
            "data: {\"type\":\"response.output_text.delta\",\"output_index\":0,\"content_index\":999999,\"delta\":\"ignored\"}",
            "data: {\"type\":\"response.function_call_arguments.delta\",\"output_index\":999999,\"delta\":\"ignored\"}"
        ]

        var combined = OpenAI.ResponsesResponse.empty
        for line in lines {
            let response: OpenAI.ResponsesResponse? = try OpenAI.decodeStream(line)
            if let response {
                combined = combined.combining(with: response)
            }
        }

        XCTAssertNil(combined.message)
        XCTAssertTrue(combined.output.isEmpty)
    }

    func testResponsesStreamSkipsEmptyFunctionCallPlaceholders() throws {
        let lines = [
            "data: {\"type\":\"response.output_text.delta\",\"output_index\":1,\"content_index\":0,\"delta\":\"Hello\"}"
        ]

        var combined = OpenAI.ResponsesResponse.empty
        for line in lines {
            let response: OpenAI.ResponsesResponse? = try OpenAI.decodeStream(line)
            if let response {
                combined = combined.combining(with: response)
            }
        }

        XCTAssertEqual(combined.message?.content.string, "Hello")
        XCTAssertNil(firstToolCall(in: combined))
    }

    private func firstToolCall(in response: OpenAI.ResponsesResponse) -> OpenAI.Message.ToolCall? {
        response.message?.tool_selection?.first
    }
}
