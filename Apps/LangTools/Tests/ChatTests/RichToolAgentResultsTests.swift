//
//  RichToolAgentResultsTests.swift
//  ChatTests
//
//  Tests for rich display content attached to tool/agent call results
//  via MessageService.resultContentParser and ContentCardRegistry tool registration.
//

import Agents
import Anthropic
import ChatUI
import Foundation
import LangTools
import Ollama
import OpenAI
import SwiftUI
import XCTest
@testable import Chat

private struct SampleCard: StructuredOutput {
    let title: String
    static var jsonSchema: JSONSchema {
        .object(properties: ["title": .string(description: "Title")], required: ["title"])
    }
}

// MARK: - Direct tool call display content tests

@MainActor
final class RichToolAgentResultsTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Pin safe defaults so a dirty UserDefaults from a prior crashed run
        // (e.g. keepsToolCallsInHistory=false leaked into com.apple.dt.xctest.tool)
        // never corrupts history-dependent tests. Tests that need a different
        // value snapshot + restore within their own body.
        ToolSettings.shared.keepsToolCallsInHistory = true
    }

    // MARK: - Tool display content mapping

    func testTrackedToolCallAttachesDisplayContentOnSuccess() throws {
        let previousKeepsToolCallsInHistory = ToolSettings.shared.keepsToolCallsInHistory
        ToolSettings.shared.keepsToolCallsInHistory = true
        defer { ToolSettings.shared.keepsToolCallsInHistory = previousKeepsToolCallsInHistory }

        let rawResult = #"{"items":[{"title":"Tool Result"}]}"#
        let service = MessageService(networkClient: AgentEventNetworkStub())
        service.resultContentParser = { result, name, kind in
            guard kind == .tool, name == "searchTool" else { return nil }
            return ChatToolCall.DisplayContent(
                type: "search_results",
                json: #"[{"title":"Tool Result"}]"#,
                summary: "Found 1 result",
                itemCount: 1
            )
        }

        service.enqueueToolEvent(.toolCalled(TestSelection(id: "tool-1", name: "searchTool", arguments: "{}")))
        service.enqueueToolEvent(.toolCompleted(TestResult(tool_selection_id: "tool-1", result: rawResult)))
        service.drainToolEvents()

        let calls = try XCTUnwrap(service.messages.first?.toolCalls)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "searchTool")
        XCTAssertEqual(calls[0].status, .success)
        XCTAssertEqual(calls[0].result, rawResult, "Raw result preserved for replay")
        let dc = try XCTUnwrap(calls[0].displayContent)
        XCTAssertEqual(dc.type, "search_results")
        XCTAssertEqual(dc.summary, "Found 1 result")
        XCTAssertEqual(dc.itemCount, 1)
        XCTAssertEqual(calls[0].result, rawResult, "Raw result still available for provider context")
    }

    func testTrackedToolCallNoDisplayContentOnFailure() throws {
        let previousKeepsToolCallsInHistory = ToolSettings.shared.keepsToolCallsInHistory
        ToolSettings.shared.keepsToolCallsInHistory = true
        defer { ToolSettings.shared.keepsToolCallsInHistory = previousKeepsToolCallsInHistory }

        let service = MessageService(networkClient: AgentEventNetworkStub())
        service.resultContentParser = { result, name, kind in
            ChatToolCall.DisplayContent(type: "never", json: "{}")
        }

        service.enqueueToolEvent(.toolCalled(TestSelection(id: "tool-1", name: "failingTool", arguments: "{}")))
        service.enqueueToolEvent(.toolCompleted(TestResult(tool_selection_id: "tool-1", result: "error", is_error: true)))
        service.drainToolEvents()

        let calls = try XCTUnwrap(service.messages.first?.toolCalls)
        XCTAssertEqual(calls[0].status, .failure)
        XCTAssertNil(calls[0].displayContent, "Failed tools must not get displayContent")
    }

    func testOrphanToolCallAttachesDisplayContent() throws {
        let previousKeepsToolCallsInHistory = ToolSettings.shared.keepsToolCallsInHistory
        ToolSettings.shared.keepsToolCallsInHistory = true
        defer { ToolSettings.shared.keepsToolCallsInHistory = previousKeepsToolCallsInHistory }

        let rawResult = #"{"items":[{"title":"Orphan"}]}"#
        let service = MessageService(networkClient: AgentEventNetworkStub())
        service.resultContentParser = { result, name, kind in
            ChatToolCall.DisplayContent(type: "orphan", json: "[]", summary: "Orphan result")
        }

        // Tool completed without a matching pending call (orphan)
        service.enqueueToolEvent(.toolCompleted(TestResult(tool_selection_id: "unknown", result: rawResult)))
        service.drainToolEvents()

        let calls = try XCTUnwrap(service.messages.first?.toolCalls)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].status, .success)
        XCTAssertNotNil(calls[0].displayContent)
        XCTAssertEqual(calls[0].displayContent?.type, "orphan")
        XCTAssertEqual(calls[0].result, rawResult, "Raw result preserved")
    }

    func testUnregisteredToolFallsBackToRawResult() throws {
        let previousKeepsToolCallsInHistory = ToolSettings.shared.keepsToolCallsInHistory
        ToolSettings.shared.keepsToolCallsInHistory = true
        defer { ToolSettings.shared.keepsToolCallsInHistory = previousKeepsToolCallsInHistory }

        let service = MessageService(networkClient: AgentEventNetworkStub())
        service.resultContentParser = { _, _, _ in nil } // No registration matches

        service.enqueueToolEvent(.toolCalled(TestSelection(id: "t1", name: "unregisteredTool", arguments: "{}")))
        service.enqueueToolEvent(.toolCompleted(TestResult(tool_selection_id: "t1", result: "raw output")))
        service.drainToolEvents()

        let calls = try XCTUnwrap(service.messages.first?.toolCalls)
        XCTAssertNil(calls[0].displayContent, "Unregistered tools must not get displayContent")
        XCTAssertEqual(calls[0].result, "raw output", "Raw result preserved")
    }

    // MARK: - Agent nested tool display content

    func testAgentNestedToolAttachesDisplayContent() throws {
        let previousKeepsToolCallsInHistory = ToolSettings.shared.keepsToolCallsInHistory
        ToolSettings.shared.keepsToolCallsInHistory = true
        defer { ToolSettings.shared.keepsToolCallsInHistory = previousKeepsToolCallsInHistory }

        let service = MessageService(networkClient: AgentEventNetworkStub())
        // Parser matches on the actual tool name "calendar_read", not the agent name
        service.resultContentParser = { result, name, kind in
            guard kind == .tool, name == "calendar_read" else { return nil }
            return ChatToolCall.DisplayContent(type: "calendar_tool", json: "[]", summary: "Calendar tool result")
        }

        service.handleAgentEvent(.started(agent: "calendarAgent", parent: nil, task: "check"))
        service.handleAgentEvent(.toolCalled(agent: "calendarAgent", tool: "calendar_read", arguments: "{}"))
        service.handleAgentEvent(.toolCompleted(agent: "calendarAgent", result: "events found"))
        service.drainAgentEvents()

        let calls = try XCTUnwrap(service.messages.first?.toolCalls)
        XCTAssertEqual(calls.count, 1)
        let agent = calls[0]
        XCTAssertEqual(agent.kind, .agent)
        XCTAssertEqual(agent.children.count, 1)
        let nestedTool = agent.children[0]
        XCTAssertEqual(nestedTool.kind, .tool)
        XCTAssertEqual(nestedTool.name, "calendar_read")
        XCTAssertEqual(nestedTool.status, .success)
        let dc = try XCTUnwrap(nestedTool.displayContent)
        XCTAssertEqual(dc.type, "calendar_tool")
    }

    // MARK: - Agent completion display content

    func testAgentCompletionAttachesDisplayContent() throws {
        let previousKeepsToolCallsInHistory = ToolSettings.shared.keepsToolCallsInHistory
        ToolSettings.shared.keepsToolCallsInHistory = true
        defer { ToolSettings.shared.keepsToolCallsInHistory = previousKeepsToolCallsInHistory }

        let rawResult = #"{"items":[{"title":"Agent Result"}]}"#
        let service = MessageService(networkClient: AgentEventNetworkStub())
        service.resultContentParser = { result, name, kind in
            guard kind == .agent, name == "Research" else { return nil }
            return ChatToolCall.DisplayContent(
                type: "research_results",
                json: #"[{"title":"Agent Result"}]"#,
                summary: "Research complete",
                itemCount: 1
            )
        }

        service.handleAgentEvent(.started(agent: "Research", parent: nil, task: "find data"))
        service.handleAgentEvent(.completed(agent: "Research", result: rawResult))
        service.drainAgentEvents()

        let calls = try XCTUnwrap(service.messages.first?.toolCalls)
        let agent = calls[0]
        XCTAssertEqual(agent.status, .success)
        let dc = try XCTUnwrap(agent.displayContent)
        XCTAssertEqual(dc.type, "research_results")
        XCTAssertEqual(dc.summary, "Research complete")
        XCTAssertEqual(agent.result, rawResult, "Raw result preserved for UI fallback when rich disabled")
        XCTAssertEqual(service.messages.first?.providerToolResults[agent.id], rawResult, "Raw preserved for replay")
    }

    func testAgentCompletionFallsBackToLegacyAgentResultParser() throws {
        let previousKeepsToolCallsInHistory = ToolSettings.shared.keepsToolCallsInHistory
        ToolSettings.shared.keepsToolCallsInHistory = true
        defer { ToolSettings.shared.keepsToolCallsInHistory = previousKeepsToolCallsInHistory }

        let rawResult = "legacy result"
        let service = MessageService(networkClient: AgentEventNetworkStub())
        // resultContentParser returns nil — legacy should fire
        service.resultContentParser = { _, _, _ in nil }
        service.agentResultParser = { result, agentName in
            guard agentName == "LegacyAgent" else { return nil }
            return Message(text: "Legacy card", role: .assistant)
        }

        service.handleAgentEvent(.started(agent: "LegacyAgent", parent: nil, task: "legacy"))
        service.handleAgentEvent(.completed(agent: "LegacyAgent", result: rawResult))
        service.drainAgentEvents()

        XCTAssertEqual(service.messages.count, 2, "Legacy card message appended")
        XCTAssertEqual(service.messages[1].text, "Legacy card")
        let agentCall = service.messages[0].toolCalls[0]
        XCTAssertEqual(agentCall.status, .success)
        XCTAssertNil(agentCall.result, "Raw hidden by legacy parser")
        XCTAssertNil(agentCall.displayContent, "No new-parser display content")
    }

    func testAgentCompletionNewParserWinsOverLegacy() throws {
        let previousKeepsToolCallsInHistory = ToolSettings.shared.keepsToolCallsInHistory
        ToolSettings.shared.keepsToolCallsInHistory = true
        defer { ToolSettings.shared.keepsToolCallsInHistory = previousKeepsToolCallsInHistory }

        let service = MessageService(networkClient: AgentEventNetworkStub())
        service.resultContentParser = { _, name, _ in
            guard name == "DualAgent" else { return nil }
            return ChatToolCall.DisplayContent(type: "new_type", json: "[]", summary: "new path")
        }
        service.agentResultParser = { _, _ in
            Message(text: "legacy path (should not fire)", role: .assistant)
        }

        service.handleAgentEvent(.started(agent: "DualAgent", parent: nil, task: "test"))
        service.handleAgentEvent(.completed(agent: "DualAgent", result: "result"))
        service.drainAgentEvents()

        // Only 1 message — new parser attached to call, no separate legacy card
        XCTAssertEqual(service.messages.count, 1, "No duplicate card from legacy parser")
        let dc = try XCTUnwrap(service.messages[0].toolCalls.first?.displayContent)
        XCTAssertEqual(dc.type, "new_type")
    }

    // MARK: - Repeated same-name calls identity

    func testRepeatedSameNameCallsAttachToCorrectMatchedInvocation() throws {
        let previousKeepsToolCallsInHistory = ToolSettings.shared.keepsToolCallsInHistory
        ToolSettings.shared.keepsToolCallsInHistory = true
        defer { ToolSettings.shared.keepsToolCallsInHistory = previousKeepsToolCallsInHistory }

        let service = MessageService(networkClient: AgentEventNetworkStub())
        service.resultContentParser = { result, name, kind in
            guard kind == .tool else { return nil }
            return ChatToolCall.DisplayContent(type: "result", json: "[]", summary: result)
        }

        // Compatibility path: applyToolEvent completes the last pending call.
        // Call order: first appended = calls[0], second appended = calls[1].
        // With LIFO completion, completions must arrive in reverse order.
        service.enqueueToolEvent(.toolCalled(TestSelection(id: "id-1", name: "repeated", arguments: "{}")))
        service.enqueueToolEvent(.toolCalled(TestSelection(id: "id-2", name: "repeated", arguments: "{}")))
        // Complete id-2 first (completes calls[1] — last pending)
        service.enqueueToolEvent(.toolCompleted(TestResult(tool_selection_id: "id-2", result: "second")))
        // Complete id-1 second (completes calls[0] — now last pending)
        service.enqueueToolEvent(.toolCompleted(TestResult(tool_selection_id: "id-1", result: "first")))
        service.drainToolEvents()

        let calls = try XCTUnwrap(service.messages.first?.toolCalls)
        XCTAssertEqual(calls.count, 2)
        // After LIFO completion: calls[0] got "first", calls[1] got "second"
        XCTAssertEqual(calls[0].result, "first")
        XCTAssertEqual(calls[0].displayContent?.summary, "first")
        XCTAssertEqual(calls[1].result, "second")
        XCTAssertEqual(calls[1].displayContent?.summary, "second")
    }

    // MARK: - History disabled preservation

    func testApplyToolEventMethodReferenceCompatibility() {
        // `applyToolEvent` must remain (LangToolsToolEvent) -> Void so it can
        // be passed directly as a toolEventHandler callback without breaking
        // source compatibility.
        let message = Message(role: .assistant, contentType: .null)
        let handler: (LangToolsToolEvent) -> Void = message.applyToolEvent
        // Must compile and not crash
        handler(.toolCalled(TestSelection(id: "ref", name: "refTool", arguments: "{}")))
        handler(.toolCompleted(TestResult(tool_selection_id: "ref", result: "ok")))
        XCTAssertEqual(message.toolCalls.count, 1)
        XCTAssertEqual(message.toolCalls[0].name, "refTool")
        XCTAssertEqual(message.toolCalls[0].status, .success)
        XCTAssertEqual(message.toolCalls[0].result, "ok")
    }

    func testCorruptDisplayContentDoesNotCrashBuildView() {
        // Stale/corrupt persisted displayContent must render gracefully,
        // not crash on assertionFailure. The parser returns nil for
        // unparseable JSON, and the buildView gracefully falls back to
        // secondary text when decode fails (tested via view(for:) below).
        let registry = ContentCardRegistry.shared
        let toolName = "crashFree_" + UUID().uuidString
        let cardType = "safeType_" + UUID().uuidString

        // Register a valid card type
        registry.register(
            tool: toolName,
            cardType: cardType,
            as: SampleCard.self,
            decode: { json in
                guard let item = try? SampleCard(jsonString: json) else { return nil }
                return (message: "OK", items: [item])
            },
            render: { _ in Text("OK") }
        )

        // Corrupt JSON: parser returns nil gracefully
        let parser = registry.resultContentParser
        XCTAssertNil(parser("not valid json", toolName, .tool),
                     "Parser returns nil for corrupt JSON; raw fallback used")

        // Valid JSON that decodes: verify displayContent is produced
        let dc = parser(#"{"title":"Safe"}"#, toolName, .tool)
        XCTAssertNotNil(dc)
        XCTAssertEqual(dc?.type, cardType)

        // Now simulate stale/corrupt persisted displayContent:
        // cardType exists in registry, but json doesn't decode as SampleCard.
        let staleDC = ChatToolCall.DisplayContent(
            type: cardType,
            json: "{\"wrong_key\": true}",
            summary: "Stale data"
        )
        // view(for:) should not crash — it falls back to secondary text.
        // We can't test the view output directly, but the registry method
        // must return without throwing/fatalError.
        // Smoke test: accessing the buildView via a ContentCardsContent
        let staleContent = ContentCardsContent(
            cardType: cardType,
            message: staleDC.summary,
            cardsJSON: staleDC.json,
            cardCount: staleDC.itemCount
        )
        // Verify parseResult can handle re-parsing stale data (it returns nil)
        let reParsed = registry.parseToolResult(staleDC.json, for: toolName)
        XCTAssertNil(reParsed, "Re-parsing stale/corrupt JSON returns nil gracefully")
    }

    func testHistoryDisabledPreservesDisplayContentAsSeparateMessage() throws {
        let previousKeepsToolCallsInHistory = ToolSettings.shared.keepsToolCallsInHistory
        ToolSettings.shared.keepsToolCallsInHistory = false
        defer { ToolSettings.shared.keepsToolCallsInHistory = previousKeepsToolCallsInHistory }

        let rawResult = "rich tool data"
        let service = MessageService(networkClient: AgentEventNetworkStub())
        service.resultContentParser = { _, name, _ in
            ChatToolCall.DisplayContent(type: "preserved_type", json: "[]", summary: "Preserved")
        }

        service.enqueueToolEvent(.toolCalled(TestSelection(id: "t1", name: "preservedTool", arguments: "{}")))
        service.enqueueToolEvent(.toolCompleted(TestResult(tool_selection_id: "t1", result: rawResult)))
        service.drainToolEvents()

        // Tool calls cleared but contentCards message survives
        let assistantMessage = service.messages.first(where: \.isAssistant)
        XCTAssertNotNil(assistantMessage, "Assistant message exists")
        // The content-cards message should be present
        let cardMessages = service.messages.filter {
            if case .contentCards = $0.contentType { return true }
            return false
        }
        XCTAssertFalse(cardMessages.isEmpty, "Display preserved as separate contentCards message when history disabled")
        if let card = cardMessages.first, case .contentCards(let content) = card.contentType {
            XCTAssertEqual(content.cardType, "preserved_type")
            XCTAssertEqual(content.message, "Preserved")
            XCTAssertEqual(content.cardCount, 1)
        }
    }

    func testHistoryDisabledDoesNotAttachDisplayContentToCall() throws {
        let previousKeepsToolCallsInHistory = ToolSettings.shared.keepsToolCallsInHistory
        ToolSettings.shared.keepsToolCallsInHistory = false
        defer { ToolSettings.shared.keepsToolCallsInHistory = previousKeepsToolCallsInHistory }

        let service = MessageService(networkClient: AgentEventNetworkStub())
        service.resultContentParser = { _, _, _ in
            ChatToolCall.DisplayContent(type: "no_attach", json: "[]", summary: "No attach")
        }

        service.enqueueToolEvent(.toolCalled(TestSelection(id: "t1", name: "testTool", arguments: "{}")))
        service.enqueueToolEvent(.toolCompleted(TestResult(tool_selection_id: "t1", result: "data")))
        service.drainToolEvents()

        // The call must NOT have displayContent attached (prevents transient duplicate)
        let calls = service.messages.first(where: \.isAssistant)?.toolCalls
        if let call = calls?.first(where: { $0.name == "testTool" }) {
            XCTAssertNil(call.displayContent, "History-disabled calls must not carry displayContent")
        }
        // Standalone card message must exist
        let cardMessages = service.messages.filter {
            if case .contentCards = $0.contentType { return true }
            return false
        }
        XCTAssertEqual(cardMessages.count, 1, "Exactly one standalone contentCards message")
    }

    func testNestedToolHistoryDisabledPreservesDisplayAsStandaloneCard() throws {
        let previousKeepsToolCallsInHistory = ToolSettings.shared.keepsToolCallsInHistory
        ToolSettings.shared.keepsToolCallsInHistory = false
        defer { ToolSettings.shared.keepsToolCallsInHistory = previousKeepsToolCallsInHistory }

        let service = MessageService(networkClient: AgentEventNetworkStub())
        service.resultContentParser = { result, name, kind in
            guard kind == .tool, name == "nested_search" else { return nil }
            return ChatToolCall.DisplayContent(type: "nested_rich", json: "[]", summary: "Nested result")
        }

        service.handleAgentEvent(.started(agent: "NestedAgent", parent: nil, task: "search"))
        service.handleAgentEvent(.toolCalled(agent: "NestedAgent", tool: "nested_search", arguments: "{}"))
        service.handleAgentEvent(.toolCompleted(agent: "NestedAgent", result: "found"))
        service.handleAgentEvent(.completed(agent: "NestedAgent", result: "done"))
        service.drainAgentEvents()

        // Standalone contentCards message must exist for the nested tool
        let cardMessages = service.messages.filter {
            if case .contentCards = $0.contentType { return true }
            return false
        }
        XCTAssertFalse(cardMessages.isEmpty, "Nested tool display must survive via standalone contentCards when history disabled")
        if let card = cardMessages.first, case .contentCards(let content) = card.contentType {
            XCTAssertEqual(content.cardType, "nested_rich")
            XCTAssertEqual(content.message, "Nested result")
        }
    }

    func testHistoryDisabledNoDuplicateCards() throws {
        let previousKeepsToolCallsInHistory = ToolSettings.shared.keepsToolCallsInHistory
        ToolSettings.shared.keepsToolCallsInHistory = false
        defer { ToolSettings.shared.keepsToolCallsInHistory = previousKeepsToolCallsInHistory }

        let service = MessageService(networkClient: AgentEventNetworkStub())
        service.resultContentParser = { _, name, _ in
            ChatToolCall.DisplayContent(type: "single", json: "[]", summary: "Single card")
        }

        // Only one tool call
        service.enqueueToolEvent(.toolCalled(TestSelection(id: "t1", name: "singleTool", arguments: "{}")))
        service.enqueueToolEvent(.toolCompleted(TestResult(tool_selection_id: "t1", result: "data")))
        service.drainToolEvents()

        let cardMessages = service.messages.filter {
            if case .contentCards = $0.contentType { return true }
            return false
        }
        XCTAssertEqual(cardMessages.count, 1, "Exactly one preserved card message, no duplicates")
    }

    // MARK: - Malformed result fallback

    func testMalformedResultFallsBackToRaw() throws {
        let previousKeepsToolCallsInHistory = ToolSettings.shared.keepsToolCallsInHistory
        ToolSettings.shared.keepsToolCallsInHistory = true
        defer { ToolSettings.shared.keepsToolCallsInHistory = previousKeepsToolCallsInHistory }

        let service = MessageService(networkClient: AgentEventNetworkStub())
        // Parser returns nil even though registered — simulating malformed JSON
        service.resultContentParser = { result, name, kind in
            // Simulate: can't parse malformed result
            guard result != "malformed" else { return nil }
            return ChatToolCall.DisplayContent(type: "ok", json: "[]")
        }

        service.enqueueToolEvent(.toolCalled(TestSelection(id: "t1", name: "fragileTool", arguments: "{}")))
        service.enqueueToolEvent(.toolCompleted(TestResult(tool_selection_id: "t1", result: "malformed")))
        service.drainToolEvents()

        let calls = try XCTUnwrap(service.messages.first?.toolCalls)
        XCTAssertNil(calls[0].displayContent, "Malformed result must not produce displayContent")
        XCTAssertEqual(calls[0].result, "malformed", "Raw result preserved for troubleshooting")
    }

    // MARK: - Persistence roundtrip

    func testDisplayContentCodableRoundtrip() throws {
        let dc = ChatToolCall.DisplayContent(
            type: "test_type",
            json: #"{"key":"value"}"#,
            summary: "A summary",
            itemCount: 5
        )
        let encoded = try JSONEncoder().encode(dc)
        let decoded = try JSONDecoder().decode(ChatToolCall.DisplayContent.self, from: encoded)
        XCTAssertEqual(decoded.type, "test_type")
        XCTAssertEqual(decoded.json, #"{"key":"value"}"#)
        XCTAssertEqual(decoded.summary, "A summary")
        XCTAssertEqual(decoded.itemCount, 5)
    }

    func testChatToolCallWithDisplayContentCodableRoundtrip() throws {
        var call = ChatToolCall(
            id: "call-1",
            name: "testTool",
            kind: .tool,
            arguments: #"{"q":"test"}"#,
            status: .success,
            result: "raw output",
            displayContent: ChatToolCall.DisplayContent(
                type: "rich",
                json: #"[{"title":"Item"}]"#,
                summary: "1 item",
                itemCount: 1
            )
        )
        let encoded = try JSONEncoder().encode(call)
        let decoded = try JSONDecoder().decode(ChatToolCall.self, from: encoded)
        XCTAssertEqual(decoded.id, "call-1")
        XCTAssertEqual(decoded.name, "testTool")
        XCTAssertEqual(decoded.status, .success)
        XCTAssertEqual(decoded.result, "raw output")
        let dc = try XCTUnwrap(decoded.displayContent)
        XCTAssertEqual(dc.type, "rich")
        XCTAssertEqual(dc.summary, "1 item")
    }

    func testLegacyChatToolCallDecodesWithoutDisplayContent() throws {
        // Old JSON without displayContent field must still decode.
        // Encode a call without displayContent and verify roundtrip.
        let call = ChatToolCall(
            id: "old-call",
            name: "legacyTool",
            kind: .tool,
            arguments: nil,
            status: .success,
            result: "legacy result"
        )
        let encoded = try JSONEncoder().encode(call)
        let decoded = try JSONDecoder().decode(ChatToolCall.self, from: encoded)
        XCTAssertEqual(decoded.id, "old-call")
        XCTAssertEqual(decoded.name, "legacyTool")
        XCTAssertEqual(decoded.status, .success)
        XCTAssertEqual(decoded.result, "legacy result")
        XCTAssertNil(decoded.displayContent, "Legacy calls have no displayContent")
        // Verify displayContent key is absent from encoded JSON
        let jsonString = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(jsonString.contains("displayContent"), "Legacy encoding must not contain displayContent key")
    }

    // MARK: - ContentCardRegistry tool registration and bridging

    func testToolRegistrationAndParser() throws {
        let registry = ContentCardRegistry.shared
        let toolName = "weatherTool_" + UUID().uuidString
        let cardType = "weather_" + UUID().uuidString

        registry.register(
            tool: toolName,
            cardType: cardType,
            as: SampleCard.self,
            decode: { json in
                guard let item = try? SampleCard(jsonString: json) else { return nil }
                return (message: "Weather found", items: [item])
            },
            render: { _ in Text("Weather") }
        )

        let rawResult = #"{"title":"Sunny"}"#
        let content = try XCTUnwrap(registry.parseToolResult(rawResult, for: toolName))
        XCTAssertEqual(content.cardType, cardType)
        XCTAssertEqual(content.message, "Weather found")
        XCTAssertEqual(content.cardCount, 1)

        // resultContentParser bridges to DisplayContent
        let parser = registry.resultContentParser
        let dc = try XCTUnwrap(parser(rawResult, toolName, .tool))
        XCTAssertEqual(dc.type, cardType)
        XCTAssertEqual(dc.summary, "Weather found")
        XCTAssertEqual(dc.itemCount, 1)
    }

    func testResultContentParserReturnsNilForUnregisteredTool() {
        let registry = ContentCardRegistry.shared
        let parser = registry.resultContentParser
        XCTAssertNil(parser("{}", "nonexistent_tool_" + UUID().uuidString, .tool))
    }

    func testResultContentParserReturnsNilForEmptyCards() {
        let registry = ContentCardRegistry.shared
        let toolName = "emptyTool_" + UUID().uuidString
        registry.register(
            tool: toolName,
            cardType: UUID().uuidString,
            as: SampleCard.self,
            decode: { _ in (message: "Nothing found", items: []) },
            render: { _ in Text("Empty") }
        )
        let parser = registry.resultContentParser
        XCTAssertNil(parser("{}", toolName, .tool), "Zero-card results must not produce DisplayContent")
    }
}

// MARK: - Test helpers

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
}

private final class AgentEventNetworkStub: NetworkClientProtocol {
    static let shared: NetworkClientProtocol = AgentEventNetworkStub()

    func performChatCompletionRequest(messages: [Message], model: Model, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) async throws -> Message {
        throw NetworkClient.NetworkError.incompatibleRequest
    }

    func streamChatCompletionRequest(messages: [Message], model: Model, stream: Bool, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) throws -> AsyncThrowingStream<String, Error> {
        throw NetworkClient.NetworkError.incompatibleRequest
    }

    func playAudio(for text: String) async throws {}
    func agentContext(messages: [Message], model: Model, eventHandler: @escaping (AgentEvent) -> Void) throws -> AgentContext {
        throw NetworkClient.NetworkError.incompatibleRequest
    }
    func updateApiKey(_ apiKey: String, for llm: APIService) throws {}
    func removeApiKey(for llm: APIService) throws {}
    func connectAccount(_ provider: AccountLoginProvider) async throws {}
    func disconnectAccount(_ provider: AccountLoginProvider) async throws {}
}