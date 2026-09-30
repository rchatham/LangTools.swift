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

    private func message(text: String?, toolCalls: [ChatToolCall], providerToolResults: [String: String] = [:]) -> Message {
        Message(
            role: .assistant,
            contentType: text.map { .string($0) } ?? .null,
            toolCalls: toolCalls,
            providerToolResults: providerToolResults
        )
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

    func testStructuredAgentResultOverrideReplaysWithoutVisibleCardResult() {
        let rawResult = #"{"items":[{"title":"Result"}]}"#
        let agentCall = ChatToolCall(
            id: "agent-1",
            name: "Research",
            kind: .agent,
            arguments: "{}",
            status: .success,
            result: nil
        )
        let message = message(
            text: nil,
            toolCalls: [agentCall],
            providerToolResults: [agentCall.id: rawResult]
        )

        let openAIMessages = [message].toOpenAIMessages()
        guard case .toolResult(let openAIResult) = openAIMessages[1].content.array?.first else {
            return XCTFail("Expected OpenAI tool result")
        }
        XCTAssertEqual(openAIResult.result, rawResult)

        let anthropicMessages = [message].toAnthropicMessages()
        guard case .array(let anthropicBlocks) = anthropicMessages[1].content,
              case .toolResult(let anthropicResult) = anthropicBlocks.first
        else {
            return XCTFail("Expected Anthropic tool result")
        }
        XCTAssertEqual(anthropicResult.result, rawResult)

        let ollamaMessages = [message].toOllamaMessages()
        XCTAssertEqual(ollamaMessages[1].content.text, rawResult)
        XCTAssertNil(message.toolCalls[0].result)
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

    // MARK: - Cross-provider replay policy

    private func structuredAgentMessage() -> Message {
        let msg = Message(
            role: .assistant,
            contentType: .null,
            toolCalls: [completed("calendarAgent", id: "agent-1", result: "")],
            providerToolResults: ["agent-1": #"{"events":[{"id":"evt-9","time":"10:00"}]}"#]
        )
        msg.providerToolResultServices = ["agent-1": .ollama]
        return msg
    }

    func testReplayFilterKeepsRawResultOnSameOriginService() {
        let filtered = structuredAgentMessage().replayFiltered(targetService: .ollama, allowCrossProvider: false)
        XCTAssertEqual(filtered.providerToolResults["agent-1"], #"{"events":[{"id":"evt-9","time":"10:00"}]}"#)
    }

    func testReplayFilterDropsRawResultForDifferentServiceWhenDisabled() {
        let filtered = structuredAgentMessage().replayFiltered(targetService: .openAI, allowCrossProvider: false)
        XCTAssertNil(filtered.providerToolResults["agent-1"])
        XCTAssertNil(filtered.providerToolResultServices["agent-1"])
    }

    func testReplayFilterKeepsRawResultForDifferentServiceWhenEnabled() {
        let filtered = structuredAgentMessage().replayFiltered(targetService: .openAI, allowCrossProvider: true)
        XCTAssertEqual(filtered.providerToolResults, structuredAgentMessage().providerToolResults)
        XCTAssertEqual(filtered.providerToolResultServices, ["agent-1": .ollama])
    }

    func testReplayFilterKeepsLegacyResultsWithoutRecordedOrigin() {
        let legacy = Message(
            role: .assistant,
            contentType: .null,
            toolCalls: [completed("calendarAgent", id: "legacy-1", result: "")],
            providerToolResults: ["legacy-1": #"{"legacy":true}"#]
        )
        let filtered = legacy.replayFiltered(targetService: .openAI, allowCrossProvider: false)
        XCTAssertEqual(filtered.providerToolResults["legacy-1"], #"{"legacy":true}"#)
    }

    func testReplayFilterKeepsMixedOriginResultsForMatchingServiceOnly() {
        let openAICall = completed("researchAgent", id: "openai-agent", result: "")
        let msg = Message(
            role: .assistant,
            contentType: .null,
            toolCalls: [openAICall, completed("calendarAgent", id: "ollama-agent", result: "")],
            providerToolResults: [
                "openai-agent": #"{"origin":"openai"}"#,
                "ollama-agent": #"{"origin":"ollama"}"#
            ]
        )
        msg.providerToolResultServices = ["openai-agent": .openAI, "ollama-agent": .ollama]

        let filtered = [msg].replayFiltered(targetService: .openAI, allowCrossProvider: false)
        XCTAssertEqual(filtered[0].providerToolResults, ["openai-agent": #"{"origin":"openai"}"#])
    }

    func testCrossProviderReplayFilteringIsIdentityWhenAllowed() {
        let original = structuredAgentMessage()
        let filtered = original.replayFiltered(targetService: .anthropic, allowCrossProvider: true)
        XCTAssertTrue(filtered === original)
    }
}