//
//  ToolCallHistoryReplayTests.swift
//  ChatTests
//

import Foundation
import LangTools
import OpenAI
import Anthropic
import Ollama
import ChatUI
import XCTest
@testable import Chat

final class ToolCallHistoryReplayTests: XCTestCase {

    private func message(text: String?, toolCalls: [ChatToolCall]) -> Message {
        Message(role: .assistant, contentType: text.map { .string($0) } ?? .null, toolCalls: toolCalls)
    }

    private func completed(_ name: String, id: String, args: String = "{}", result: String, failure: Bool = false) -> ChatToolCall {
        ChatToolCall(id: id, name: name, arguments: args, status: failure ? .failure : .success, result: result)
    }

    // MARK: - OpenAI

    func testOpenAIReplayExpandsCompletedToolCalls() {
        let msgs = [message(text: "Let me check.", toolCalls: [
            completed("calculate", id: "call-1", args: #"{"expression":"1+1"}"#, result: "2")
        ])].toOpenAIMessages()

        XCTAssertEqual(msgs.count, 2)
        XCTAssertEqual(msgs[0].role, .assistant)
        XCTAssertEqual(msgs[0].tool_calls?.count, 1)
        XCTAssertEqual(msgs[0].tool_calls?[0].id, "call-1")
        XCTAssertEqual(msgs[0].tool_calls?[0].function.name, "calculate")
        XCTAssertEqual(msgs[0].tool_calls?[0].function.arguments, #"{"expression":"1+1"}"#)
        XCTAssertEqual(msgs[1].role, .tool)
        XCTAssertEqual(msgs[1].tool_selection_id, "call-1")
    }

    func testOpenAIReplayMultipleCallsProduceOneAssistantPlusResults() {
        let msgs = [message(text: nil, toolCalls: [
            completed("current_date_time", id: "a", result: "noon"),
            completed("calculate", id: "b", result: "42")
        ])].toOpenAIMessages()

        XCTAssertEqual(msgs.count, 3)
        XCTAssertEqual(msgs[0].role, .assistant)
        XCTAssertEqual(msgs[0].tool_calls?.count, 2)
        XCTAssertEqual(msgs[1].role, .tool)
        XCTAssertEqual(msgs[2].role, .tool)
    }

    func testOpenAIReplaySkipsPendingToolCalls() {
        let msgs = [message(text: "thinking", toolCalls: [
            ChatToolCall(id: "p", name: "calculate", arguments: "{}", status: .pending, result: nil)
        ])].toOpenAIMessages()

        XCTAssertEqual(msgs.count, 1)
        XCTAssertNil(msgs[0].tool_calls)
    }

    func testOpenAIReplayNoToolCallsIsTextOnly() {
        let msgs = [Message(text: "hi", role: .assistant)].toOpenAIMessages()
        XCTAssertEqual(msgs.count, 1)
        XCTAssertNil(msgs[0].tool_calls)
    }

    // MARK: - Anthropic

    func testAnthropicReplayExpandsIntoAssistantToolUseAndUserToolResult() {
        let msgs = [message(text: "checking", toolCalls: [
            completed("calculate", id: "call-1", result: "2")
        ])].toAnthropicMessages()

        XCTAssertEqual(msgs.count, 2)
        XCTAssertEqual(msgs[0].role, .assistant)
        XCTAssertEqual(msgs[1].role, .user)
    }

    func testAnthropicReplayFiltersSystemMessages() {
        let msgs = [Message(text: "sys", role: .system), message(text: "ok", toolCalls: [
            completed("calculate", id: "c", result: "1")
        ])].toAnthropicMessages()

        XCTAssertEqual(msgs.count, 2)
    }

    // MARK: - Ollama

    func testOllamaReplayExpandsCompletedToolCalls() {
        let msgs = [message(text: "checking", toolCalls: [
            completed("calculate", id: "ollama", args: #"{"expression":"1+1"}"#, result: "2")
        ])].toOllamaMessages()

        XCTAssertEqual(msgs.count, 2)
        XCTAssertEqual(msgs[0].role, .assistant)
        XCTAssertEqual(msgs[0].tool_calls?.count, 1)
        XCTAssertEqual(msgs[0].tool_calls?[0].name, "calculate")
        XCTAssertEqual(msgs[1].role, .tool)
    }

    func testOllamaReplayPreservesMixedTypeArguments() throws {
        let msgs = [message(text: nil, toolCalls: [
            completed(
                "ask_user_question",
                id: "ollama",
                args: #"{"question":"Name?","multiSelect":false,"options":[],"limit":3}"#,
                result: "Reid"
            )
        ])].toOllamaMessages()

        let arguments = try XCTUnwrap(msgs[0].tool_calls?.first?.function.arguments)
        XCTAssertEqual(arguments["question"]?.stringValue, "Name?")
        XCTAssertEqual(arguments["multiSelect"]?.boolValue, false)
        XCTAssertEqual(arguments["options"]?.arrayValue?.count, 0)
        XCTAssertEqual(arguments["limit"]?.intValue, 3)
    }
}