//
//  ToolCallEventTests.swift
//  ChatTests
//

import Foundation
import LangTools
import OpenAI
import ChatUI
import XCTest
@testable import Chat

final class ToolCallEventTests: XCTestCase {

    // MARK: - Test event stubs

    private struct TestSelection: LangToolsToolSelection {
        let id: String?
        let name: String?
        let arguments: String
    }

    private struct TestResult: LangToolsToolSelectionResult {
        let tool_selection_id: String
        let result: String
        let is_error: Bool

        init(tool_selection_id: String, result: String, is_error: Bool = false) {
            self.tool_selection_id = tool_selection_id
            self.result = result
            self.is_error = is_error
        }

        init(tool_selection_id: String, result: String) {
            self.init(tool_selection_id: tool_selection_id, result: result, is_error: false)
        }
    }

    private func called(name: String, id: String? = nil, arguments: String = "{}") -> LangToolsToolEvent {
        .toolCalled(TestSelection(id: id, name: name, arguments: arguments))
    }

    private func completed(result: String, id: String = "call-1", isError: Bool = false) -> LangToolsToolEvent {
        .toolCompleted(TestResult(tool_selection_id: id, result: result, is_error: isError))
    }

    // MARK: - applyToolEvent

    func testToolCalledAppendsPendingCard() {
        let message = Message(role: .assistant, contentType: .string("thinking"))
        message.applyToolEvent(called(name: "calculate", arguments: #"{"expression":"1+1"}"#))

        XCTAssertEqual(message.toolCalls.count, 1)
        let call = message.toolCalls[0]
        XCTAssertEqual(call.name, "calculate")
        XCTAssertEqual(call.arguments, #"{"expression":"1+1"}"#)
        XCTAssertEqual(call.status, .pending)
        XCTAssertNil(call.result)
    }

    func testToolCompletedUpdatesPendingCardToSuccess() {
        let message = Message(role: .assistant, contentType: .string("thinking"))
        message.applyToolEvent(called(name: "calculate", id: "call-1"))
        message.applyToolEvent(completed(result: "2"))

        XCTAssertEqual(message.toolCalls.count, 1)
        XCTAssertEqual(message.toolCalls[0].status, .success)
        XCTAssertEqual(message.toolCalls[0].result, "2")
    }

    func testToolCompletedMarksFailure() {
        let message = Message(role: .assistant, contentType: .string("thinking"))
        message.applyToolEvent(called(name: "calculate", id: "call-1"))
        message.applyToolEvent(completed(result: "bad expression", isError: true))

        XCTAssertEqual(message.toolCalls.count, 1)
        XCTAssertEqual(message.toolCalls[0].status, .failure)
        XCTAssertEqual(message.toolCalls[0].result, "bad expression")
    }

    func testMultipleCallsStrictPairingRenderSeparately() {
        // LangTools fires events as strict (called, completed) pairs in arrival
        // order. Each completion must bind to the most recent pending card.
        let message = Message(role: .assistant, contentType: .null)
        message.applyToolEvent(called(name: "current_date_time", id: "a"))
        message.applyToolEvent(completed(result: "noon", id: "a"))
        message.applyToolEvent(called(name: "calculate", id: "b"))
        message.applyToolEvent(completed(result: "42", id: "b"))

        XCTAssertEqual(message.toolCalls.count, 2)
        XCTAssertEqual(message.toolCalls[0].name, "current_date_time")
        XCTAssertEqual(message.toolCalls[0].status, .success)
        XCTAssertEqual(message.toolCalls[0].result, "noon")
        XCTAssertEqual(message.toolCalls[1].name, "calculate")
        XCTAssertEqual(message.toolCalls[1].status, .success)
        XCTAssertEqual(message.toolCalls[1].result, "42")
    }

    func testOrphanToolCompletedAppendsCompletedCard() {
        let message = Message(role: .assistant, contentType: .null)
        // A completion with no preceding .toolCalled should still surface a card.
        message.applyToolEvent(completed(result: "orphan-result"))

        XCTAssertEqual(message.toolCalls.count, 1)
        XCTAssertEqual(message.toolCalls[0].status, .success)
        XCTAssertEqual(message.toolCalls[0].result, "orphan-result")
    }

    func testProviderReusedCallIdsStillRenderSeparately() {
        // Ollama reports the same id for every call. Cards must not be deduped.
        let message = Message(role: .assistant, contentType: .null)
        message.applyToolEvent(called(name: "calculate", id: "ollama", arguments: "1"))
        message.applyToolEvent(completed(result: "1", id: "ollama"))
        message.applyToolEvent(called(name: "calculate", id: "ollama", arguments: "2"))
        message.applyToolEvent(completed(result: "2", id: "ollama"))

        XCTAssertEqual(message.toolCalls.count, 2)
        XCTAssertEqual(message.toolCalls[0].result, "1")
        XCTAssertEqual(message.toolCalls[1].result, "2")
    }

    // MARK: - Codable round-trip

    func testMessageCodableRoundTripPreservesToolCalls() throws {
        let message = Message(
            role: .assistant,
            contentType: .string("done"),
            toolCalls: [
                ChatToolCall(id: "call-1", name: "calculate", arguments: "{}", status: .success, result: "2"),
                ChatToolCall(id: "call-2", name: "current_date_time", arguments: nil, status: .failure, result: "oops")
            ],
            providerToolResults: ["call-1": #"{"value":2}"#]
        )

        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(Message.self, from: data)

        XCTAssertEqual(decoded.toolCalls.count, 2)
        XCTAssertEqual(decoded.toolCalls[0].name, "calculate")
        XCTAssertEqual(decoded.toolCalls[0].status, .success)
        XCTAssertEqual(decoded.toolCalls[0].result, "2")
        XCTAssertEqual(decoded.toolCalls[1].name, "current_date_time")
        XCTAssertEqual(decoded.toolCalls[1].status, .failure)
        XCTAssertEqual(decoded.toolCalls[1].result, "oops")
        XCTAssertEqual(decoded.providerToolResults, ["call-1": #"{"value":2}"#])
    }

    func testMessageDecodedWithoutToolCallsKeyDefaultsToEmpty() throws {
        // Legacy payloads encoded before toolCalls existed must still decode.
        let legacyJSON = """
        {"uuid":"\(UUID().uuidString)","role":"assistant","contentType":{"type":"string","content":"hi"},"createdAt":0}
        """
        let message = try JSONDecoder().decode(Message.self, from: legacyJSON.data(using: .utf8)!)

        XCTAssertEqual(message.toolCalls, [])
        XCTAssertEqual(message.providerToolResults, [:])
        XCTAssertEqual(message.text, "hi")
    }
}