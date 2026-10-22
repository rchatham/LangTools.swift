//
//  AgentToolCallMappingTests.swift
//  ChatTests
//

import Agents
import Anthropic
import ChatUI
import Foundation
import LangTools
import Ollama
import OpenAI
import XCTest
@testable import Chat

@MainActor
final class AgentToolCallMappingTests: XCTestCase {

    private func makeService(keepsToolCallsInHistory: Bool = true) throws -> MessageService {
        let suiteName = "AgentToolCallMappingTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(keepsToolCallsInHistory, forKey: "keepsToolCallsInHistory")
        return MessageService(networkClient: AgentEventNetworkStub(), toolSettings: ToolSettings(defaults: defaults))
    }

    func testAgentStartedToolCallCompletedAndAgentCompleted() throws {
        var calls: [ChatToolCall] = []

        // .started(Research, parent: nil, task: "find weather")
        calls.append(ChatToolCall(id: "a1", name: "Research", kind: .agent, status: .pending, details: "started: find weather"))

        // .toolCalled(Research, "calculate", "{}")
        MessageService.appendChild(
            ChatToolCall(id: "t1", name: "calculate", kind: .tool, arguments: "{}", status: .pending),
            toAgent: "Research", in: &calls)

        // .toolCompleted(Research, "42")
        MessageService.completePendingChild(ofAgent: "Research", result: "42", status: .success, in: &calls)

        // .completed(Research, "42", false)
        MessageService.setAgentStatus("Research", status: .success, result: "42", in: &calls)

        XCTAssertEqual(calls.count, 1)
        let agent = (try calls.mappingElement(at: 0))
        XCTAssertEqual(agent.kind, .agent)
        XCTAssertEqual(agent.name, "Research")
        XCTAssertEqual(agent.status, .success)
        XCTAssertEqual(agent.result, "42")
        XCTAssertEqual(agent.children.count, 1)
        let tool = (try agent.children.mappingElement(at: 0))
        XCTAssertEqual(tool.kind, .tool)
        XCTAssertEqual(tool.name, "calculate")
        XCTAssertEqual(tool.status, .success)
        XCTAssertEqual(tool.result, "42")
    }

    func testAgentDelegationNestsAsAgentChild() throws {
        var calls: [ChatToolCall] = []
        calls.append(ChatToolCall(id: "main", name: "Main", kind: .agent, status: .pending, details: "started: task"))

        // Main delegates to Research
        MessageService.appendChild(
            ChatToolCall(id: "sub", name: "Research", kind: .agent, status: .pending, details: "delegated: because"),
            toAgent: "Main", in: &calls)

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual((try calls.mappingElement(at: 0)).children.count, 1)
        let sub = (try calls.mappingElement(at: 0).children.mappingElement(at: 0))
        XCTAssertEqual(sub.kind, .agent)
        XCTAssertEqual(sub.name, "Research")
        XCTAssertEqual(sub.details, "delegated: because")
    }

    func testSetAgentStatusOnlyAffectsMatchingAgent() throws {
        var calls: [ChatToolCall] = [
            ChatToolCall(id: "a", name: "A", kind: .agent, status: .pending),
            ChatToolCall(id: "b", name: "B", kind: .agent, status: .pending)
        ]
        MessageService.setAgentStatus("B", status: .failure, result: "oops", in: &calls)
        XCTAssertEqual((try calls.mappingElement(at: 0)).status, .pending)
        XCTAssertEqual((try calls.mappingElement(at: 1)).status, .failure)
        XCTAssertEqual((try calls.mappingElement(at: 1)).result, "oops")
    }

    func testAgentOnlyEventsWithoutPreambleCreateAssistantCard() throws {
        let service = try makeService(keepsToolCallsInHistory: true)

        service.handleAgentEvent(.started(agent: "Research", parent: nil, task: "find weather"))
        service.handleAgentEvent(.completed(agent: "Research", result: "sunny"))
        service.drainAgentEvents()

        let message = try XCTUnwrap(service.messages.first)
        XCTAssertTrue(message.isAssistant)
        XCTAssertNil(message.text)
        XCTAssertEqual(message.toolCalls.count, 1)
        XCTAssertEqual((try message.toolCalls.mappingElement(at: 0)).name, "Research")
        XCTAssertEqual((try message.toolCalls.mappingElement(at: 0)).status, .success)
        XCTAssertEqual((try message.toolCalls.mappingElement(at: 0)).result, "sunny")
    }

    func testAgentEventLifecyclePreservesReplayReasonsAcrossProviders() throws {
        let rootReason = "Find the \"quoted\" detail\non the next line"
        let delegatedReason = "Verify the \"source\"\nwithout changing it"
        let service = try makeService(keepsToolCallsInHistory: true)

        [
            AgentEvent.started(agent: "Research", parent: nil, task: rootReason),
            .agentTransfer(from: "Research", to: "Verifier", reason: delegatedReason),
            .started(agent: "Verifier", parent: "Research", task: delegatedReason),
            .completed(agent: "Verifier", result: "verified"),
            .completed(agent: "Research", result: "done")
        ].forEach(service.handleAgentEvent)
        service.drainAgentEvents()

        let message = try XCTUnwrap(service.messages.first)
        let rootCall = try XCTUnwrap(message.toolCalls.first)
        XCTAssertEqual(try replayReason(in: rootCall.arguments), rootReason)
        XCTAssertEqual(rootCall.children.count, 1, "Delegation and started events must share one child card")
        XCTAssertEqual(try replayReason(in: (try rootCall.children.mappingElement(at: 0)).arguments), delegatedReason)

        let openAIMessages = [message].toOpenAIMessages()
        XCTAssertEqual(
            try replayReason(in: openAIMessages.first?.tool_calls?.first?.function.arguments),
            rootReason
        )

        let anthropicMessages = [message].toAnthropicMessages()
        guard case .array(let anthropicBlocks) = anthropicMessages.first?.content,
              case .toolUse(let anthropicToolUse) = anthropicBlocks.first
        else {
            return XCTFail("Expected Anthropic agent tool use")
        }
        XCTAssertEqual(try replayReason(in: anthropicToolUse.input), rootReason)

        let ollamaMessages = [message].toOllamaMessages()
        XCTAssertEqual(
            ollamaMessages.first?.tool_calls?.first?.function.arguments["reason"]?.stringValue,
            rootReason
        )
    }

    func testIncrementalDelegationLifecyclePreservesNestedChronology() throws {
        let service = try makeService(keepsToolCallsInHistory: true)

        service.handleAgentEvent(.started(agent: "Main", parent: nil, task: "coordinate"))
        service.drainAgentEvents()
        var root = try XCTUnwrap(service.messages.first?.toolCalls.first)
        XCTAssertEqual(root.status, .pending)
        XCTAssertTrue(root.children.isEmpty)

        service.handleAgentEvent(.agentTransfer(from: "Main", to: "Research", reason: "investigate"))
        service.handleAgentEvent(.started(agent: "Research", parent: "Main", task: "investigate"))
        service.drainAgentEvents()
        root = try XCTUnwrap(service.messages.first?.toolCalls.first)
        XCTAssertEqual(root.children.count, 1)
        var delegated = (try root.children.mappingElement(at: 0))
        XCTAssertEqual(delegated.name, "Research")
        XCTAssertEqual(delegated.status, .pending)

        service.handleAgentEvent(.toolCalled(agent: "Research", tool: "search", arguments: "{}"))
        service.drainAgentEvents()
        delegated = try XCTUnwrap(service.messages.first?.toolCalls.first?.children.first)
        XCTAssertEqual(delegated.children.map(\.name), ["search"])
        XCTAssertEqual((try delegated.children.mappingElement(at: 0)).status, .pending)

        service.handleAgentEvent(.toolCompleted(agent: "Research", result: "source found"))
        service.drainAgentEvents()
        delegated = try XCTUnwrap(service.messages.first?.toolCalls.first?.children.first)
        XCTAssertEqual((try delegated.children.mappingElement(at: 0)).status, .success)
        XCTAssertEqual((try delegated.children.mappingElement(at: 0)).result, "source found")

        service.handleAgentEvent(.toolCalled(agent: "Research", tool: "verify", arguments: "{}"))
        service.handleAgentEvent(.error(agent: "Research", message: "verification failed"))
        service.drainAgentEvents()
        delegated = try XCTUnwrap(service.messages.first?.toolCalls.first?.children.first)
        XCTAssertEqual(delegated.status, .pending, "A tool error must not complete its owning agent")
        XCTAssertEqual(delegated.children.map(\.status), [.success, .failure])
        XCTAssertEqual((try delegated.children.mappingElement(at: 1)).result, "verification failed")

        service.handleAgentEvent(.completed(agent: "Research", result: "partial result"))
        service.drainAgentEvents()
        root = try XCTUnwrap(service.messages.first?.toolCalls.first)
        XCTAssertEqual(root.status, .pending)
        XCTAssertEqual((try root.children.mappingElement(at: 0)).status, .success)
        XCTAssertEqual((try root.children.mappingElement(at: 0)).result, "partial result")

        service.handleAgentEvent(.completed(agent: "Main", result: "final output"))
        service.drainAgentEvents()
        root = try XCTUnwrap(service.messages.first?.toolCalls.first)
        XCTAssertEqual(root.status, .success)
        XCTAssertEqual(root.result, "final output")
        XCTAssertEqual(root.children.count, 1)
        XCTAssertEqual((try root.children.mappingElement(at: 0)).name, "Research")
        XCTAssertEqual((try root.children.mappingElement(at: 0)).status, .success)
    }

    func testStructuredAgentResultIsHiddenFromCardAndRetainedForReplay() throws {
        let rawResult = #"{"items":[{"title":"Result"}]}"#
        let service = try makeService(keepsToolCallsInHistory: true)
        service.agentResultParser = { _, _ in Message(text: "Rendered cards", role: .assistant) }

        service.handleAgentEvent(.started(agent: "Research", parent: nil, task: "find data"))
        service.handleAgentEvent(.completed(agent: "Research", result: rawResult))
        service.drainAgentEvents()

        XCTAssertEqual(service.messages.count, 2)
        let eventMessage = (try service.messages.mappingElement(at: 0))
        let call = try XCTUnwrap(eventMessage.toolCalls.first)
        XCTAssertNil(call.result)
        XCTAssertEqual(eventMessage.providerToolResults[call.id], rawResult)
        XCTAssertEqual((try service.messages.mappingElement(at: 1)).text, "Rendered cards")
    }

    func testEveryHistoryDisabledPersistenceCallbackSanitizesRawAgentResults() throws {
        let emptyCardResult = #"{"private":"EMPTY_CARD_SENTINEL"}"#
        let parserNilResult = #"{"private":"PARSER_NIL_SENTINEL"}"#
        let errorResult = #"{"private":"ERROR_RESULT_SENTINEL"}"#
        let service = try makeService(keepsToolCallsInHistory: false)
        service.messages = [Message(text: "Visible preamble", role: .assistant)]
        service.agentResultParser = { result, _ in
            guard result == emptyCardResult else { return nil }
            return .contentCards(
                ContentCardsContent(
                    cardType: "empty-test-cards",
                    message: nil,
                    cardsJSON: "[]",
                    cardCount: 0
                )
            )
        }
        var encodedCallbacks: [String] = []
        service.messageUpdatedCallback = { message in
            do {
                let data = try JSONEncoder().encode(message)
                encodedCallbacks.append(String(decoding: data, as: UTF8.self))
            } catch {
                XCTFail("Failed to encode persistence callback: \(error)")
            }
        }

        let completions: [(agent: String, result: String, isError: Bool)] = [
            ("EmptyCardAgent", emptyCardResult, false),
            ("ParserNilAgent", parserNilResult, false),
            ("ErrorAgent", errorResult, true)
        ]
        for completion in completions {
            service.handleAgentEvent(.started(agent: completion.agent, parent: nil, task: "private task"))
            service.handleAgentEvent(
                .completed(
                    agent: completion.agent,
                    result: completion.result,
                    is_error: completion.isError
                )
            )
            service.drainAgentEvents()
        }

        XCTAssertEqual(
            encodedCallbacks.count,
            completions.count * 2 + 1,
            "Each started/completed transition and the empty content-card append must be captured"
        )
        for encoded in encodedCallbacks {
            let persisted = try JSONDecoder().decode(Message.self, from: Data(encoded.utf8))
            XCTAssertTrue(persisted.toolCalls.isEmpty)
            XCTAssertTrue(persisted.providerToolResults.isEmpty)
            XCTAssertFalse(encoded.contains("EMPTY_CARD_SENTINEL"))
            XCTAssertFalse(encoded.contains("PARSER_NIL_SENTINEL"))
            XCTAssertFalse(encoded.contains("ERROR_RESULT_SENTINEL"))
        }

        let liveCalls = service.messages.flatMap(\.toolCalls)
        XCTAssertEqual(liveCalls.map(\.name), completions.map(\.agent))
        XCTAssertEqual(liveCalls.map(\.result), [nil, parserNilResult, errorResult])
        XCTAssertTrue(service.messages.allSatisfy(\.providerToolResults.isEmpty))
        guard case .contentCards(let content) = (try service.messages.mappingElement(at: 1)).contentType else {
            return XCTFail("Expected the empty-card parser branch to append its content-card message")
        }
        XCTAssertEqual(content.cardCount, 0)
    }

    func testMixedToolAndAgentEventsPreserveFIFOOrder() throws {
        let service = try makeService(keepsToolCallsInHistory: true)
        service.enqueueToolEvent(.toolCalled(TestSelection(id: "tool-1", name: "calculate", arguments: "{}")))
        service.handleAgentEvent(.started(agent: "Research", parent: nil, task: "find weather"))
        service.enqueueToolEvent(.toolCompleted(TestResult(tool_selection_id: "tool-1", result: "42")))

        service.drainAgentEvents()

        let calls = try XCTUnwrap(service.messages.first).toolCalls
        XCTAssertEqual(calls.map(\.name), ["calculate", "Research"])
        XCTAssertEqual((try calls.mappingElement(at: 0)).status, .success)
        XCTAssertEqual((try calls.mappingElement(at: 0)).result, "42")
        XCTAssertEqual((try calls.mappingElement(at: 1)).status, .pending)
    }

    func testNilResultToolCompletionStillCompletesChild() throws {
        // toolCompleted may fire with a nil result; the child must still complete.
        var calls: [ChatToolCall] = [ChatToolCall(id: "a", name: "A", kind: .agent, status: .pending)]
        MessageService.appendChild(ChatToolCall(id: "t", name: "tool", kind: .tool, status: .pending), toAgent: "A", in: &calls)
        MessageService.completePendingChild(ofAgent: "A", result: "", status: .success, in: &calls)
        XCTAssertEqual((try calls.mappingElement(at: 0).children.mappingElement(at: 0)).status, .success)
        XCTAssertEqual((try calls.mappingElement(at: 0).children.mappingElement(at: 0)).result, "")
    }

    func testConcurrentToolCallsCompleteInCallOrder() throws {
        // toolCompleted carries no tool name, so completions match in call order (FIFO).
        var calls: [ChatToolCall] = [ChatToolCall(id: "a", name: "A", kind: .agent, status: .pending)]
        MessageService.appendChild(ChatToolCall(id: "t1", name: "toolA", kind: .tool, status: .pending), toAgent: "A", in: &calls)
        MessageService.appendChild(ChatToolCall(id: "t2", name: "toolB", kind: .tool, status: .pending), toAgent: "A", in: &calls)
        MessageService.completePendingChild(ofAgent: "A", result: "resA", status: .success, in: &calls)
        MessageService.completePendingChild(ofAgent: "A", result: "resB", status: .success, in: &calls)
        XCTAssertEqual((try calls.mappingElement(at: 0).children.mappingElement(at: 0)).name, "toolA")
        XCTAssertEqual((try calls.mappingElement(at: 0).children.mappingElement(at: 0)).result, "resA")
        XCTAssertEqual((try calls.mappingElement(at: 0).children.mappingElement(at: 0)).status, .success)
        XCTAssertEqual((try calls.mappingElement(at: 0).children.mappingElement(at: 1)).name, "toolB")
        XCTAssertEqual((try calls.mappingElement(at: 0).children.mappingElement(at: 1)).result, "resB")
        XCTAssertEqual((try calls.mappingElement(at: 0).children.mappingElement(at: 1)).status, .success)
    }

    func testDelegationDoesNotDuplicateAgentCard() throws {
        // agentTransfer then started(to, parent) must produce a single sub-agent card.
        var calls: [ChatToolCall] = [ChatToolCall(id: "main", name: "Main", kind: .agent, status: .pending)]
        // .agentTransfer(Main, to: Research, reason)
        MessageService.appendChild(ChatToolCall(id: "d", name: "Research", kind: .agent, status: .pending, details: "delegated: because"), toAgent: "Main", in: &calls)
        // .started(Research, parent: Main, task) -> should update existing, not duplicate
        let updated = MessageService.updateAgentChildDetails("Research", parent: "Main", append: "started: find", in: &calls)
        XCTAssertTrue(updated)
        XCTAssertEqual((try calls.mappingElement(at: 0)).children.count, 1)
        XCTAssertEqual((try calls.mappingElement(at: 0).children.mappingElement(at: 0)).name, "Research")
        XCTAssertTrue((try calls.mappingElement(at: 0).children.mappingElement(at: 0)).details?.contains("delegated") == true)
        XCTAssertTrue((try calls.mappingElement(at: 0).children.mappingElement(at: 0)).details?.contains("started") == true)
    }

    func testToolErrorCompletesPendingToolWithoutCompletingAgentChild() throws {
        var calls: [ChatToolCall] = [ChatToolCall(id: "a", name: "A", kind: .agent, status: .pending)]
        MessageService.appendChild(ChatToolCall(id: "sub", name: "Delegate", kind: .agent, status: .pending), toAgent: "A", in: &calls)
        MessageService.appendChild(ChatToolCall(id: "t", name: "tool", kind: .tool, status: .pending), toAgent: "A", in: &calls)
        MessageService.completePendingChild(ofAgent: "A", result: "boom", status: .failure, in: &calls)
        XCTAssertEqual((try calls.mappingElement(at: 0).children.mappingElement(at: 0)).status, .pending)
        XCTAssertNil((try calls.mappingElement(at: 0).children.mappingElement(at: 0)).result)
        XCTAssertEqual((try calls.mappingElement(at: 0).children.mappingElement(at: 1)).status, .failure)
        XCTAssertEqual((try calls.mappingElement(at: 0).children.mappingElement(at: 1)).result, "boom")
    }

    func testCompleteRemainingPendingClearsStuckChildrenAndPreservesFailures() throws {
        var calls: [ChatToolCall] = [ChatToolCall(id: "a", name: "A", kind: .agent, status: .pending, children: [
            ChatToolCall(id: "c1", name: "subagent", kind: .agent, status: .pending, children: [
                ChatToolCall(id: "g1", name: "failedTool", kind: .tool, status: .failure, result: "boom"),
                ChatToolCall(id: "g2", name: "pendingTool", kind: .tool, status: .pending)
            ]),
            ChatToolCall(id: "c2", name: "toolB", kind: .tool, status: .success, result: "ok")
        ])]
        MessageService.completeRemainingPending(ofAgent: "A", status: .success, in: &calls)
        XCTAssertEqual((try calls.mappingElement(at: 0).children.mappingElement(at: 0)).status, .success)
        XCTAssertEqual((try calls.mappingElement(at: 0).children.mappingElement(at: 0).children.mappingElement(at: 0)).status, .failure)
        XCTAssertEqual((try calls.mappingElement(at: 0).children.mappingElement(at: 0).children.mappingElement(at: 1)).status, .success)
        XCTAssertEqual((try calls.mappingElement(at: 0).children.mappingElement(at: 1)).status, .success)
    }

    func testFailedCalendarReadRetrySucceedsAsSeparateInvocation() throws {
        let calls = try runCalendarReadRetry(secondAttemptFails: false)
        try assertCalendarReadRetry(calls, expectedRetryStatus: .success)
    }

    func testFailedCalendarReadRetryFailsAsSeparateInvocation() throws {
        let calls = try runCalendarReadRetry(secondAttemptFails: true)
        try assertCalendarReadRetry(calls, expectedRetryStatus: .failure)
    }

    private func replayReason(in arguments: String?) throws -> String {
        let arguments = try XCTUnwrap(arguments)
        let decoded = try JSONDecoder().decode([String: String].self, from: Data(arguments.utf8))
        return try XCTUnwrap(decoded["reason"])
    }

    private func runCalendarReadRetry(secondAttemptFails: Bool) throws -> [ChatToolCall] {
        let service = try makeService(keepsToolCallsInHistory: true)
        service.messages = [Message(role: .assistant, contentType: .null)]
        var events: [AgentEvent] = [
            .started(agent: "calendarAgent", parent: nil, task: "check calendars"),
            .agentTransfer(from: "calendarAgent", to: "calendarReadAgent", reason: "first attempt"),
            .started(agent: "calendarReadAgent", parent: "calendarAgent", task: "read calendar"),
            .toolCalled(agent: "calendarReadAgent", tool: "calendar_read", arguments: "{}"),
            .error(agent: "calendarReadAgent", message: "first read failed"),
            .completed(agent: "calendarReadAgent", result: "first attempt failed", is_error: true),
            .agentTransfer(from: "calendarAgent", to: "calendarReadAgent", reason: "retry"),
            .started(agent: "calendarReadAgent", parent: "calendarAgent", task: "retry calendar read"),
            .toolCalled(agent: "calendarReadAgent", tool: "calendar_read", arguments: "{}")
        ]
        if secondAttemptFails {
            events.append(.error(agent: "calendarReadAgent", message: "retry failed"))
            events.append(.completed(agent: "calendarReadAgent", result: "retry failed", is_error: true))
            events.append(.completed(agent: "calendarAgent", result: "calendar failed", is_error: true))
        } else {
            events.append(.toolCompleted(agent: "calendarReadAgent", result: "event found"))
            events.append(.completed(agent: "calendarReadAgent", result: "event found"))
            events.append(.completed(agent: "calendarAgent", result: "done"))
        }

        events.forEach(service.handleAgentEvent)
        service.drainAgentEvents()
        return (try service.messages.mappingElement(at: 0)).toolCalls
    }

    private func assertCalendarReadRetry(
        _ calls: [ChatToolCall],
        expectedRetryStatus: ChatToolCall.Status,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let root = try XCTUnwrap(calls.first, file: file, line: line)
        let reads = root.children.filter { $0.kind == .agent && $0.name == "calendarReadAgent" }
        XCTAssertEqual(reads.count, 2, file: file, line: line)
        XCTAssertEqual((try reads.mappingElement(at: 0)).status, .failure, file: file, line: line)
        XCTAssertEqual((try reads.mappingElement(at: 0)).result, "first attempt failed", file: file, line: line)
        XCTAssertEqual(try replayReason(in: (try reads.mappingElement(at: 0)).arguments), "read calendar", file: file, line: line)
        XCTAssertEqual((try reads.mappingElement(at: 1)).status, expectedRetryStatus, file: file, line: line)
        XCTAssertEqual((try reads.mappingElement(at: 1)).result, expectedRetryStatus == .success ? "event found" : "retry failed", file: file, line: line)
        XCTAssertEqual(try replayReason(in: (try reads.mappingElement(at: 1)).arguments), "retry calendar read", file: file, line: line)
        XCTAssertFalse(calls.flattened().contains { $0.name == "agent_transfer" }, file: file, line: line)
        XCTAssertFalse(calls.flattened().contains { $0.status == .pending }, file: file, line: line)
    }
}

private extension Array {
    /// Report a failed prerequisite through XCTest instead of trapping on an index.
    func mappingElement(at index: Int, file: StaticString = #filePath, line: UInt = #line) throws -> Element {
        try XCTUnwrap(
            indices.contains(index) ? self[index] : nil,
            "Expected element at index \(index), but found \(count) elements",
            file: file,
            line: line
        )
    }
}

private struct TestSelection: LangToolsToolSelection {
    let id: String?
    let name: String?
    let arguments: String
}

private struct TestResult: LangToolsToolSelectionResult {
    let tool_selection_id: String
    let result: String
    let is_error: Bool

    init(tool_selection_id: String, result: String, is_error: Bool) {
        self.tool_selection_id = tool_selection_id
        self.result = result
        self.is_error = is_error
    }

    init(tool_selection_id: String, result: String) {
        self.init(tool_selection_id: tool_selection_id, result: result, is_error: false)
    }
}

private extension Array where Element == ChatToolCall {
    func flattened() -> [ChatToolCall] {
        flatMap { [$0] + $0.children.flattened() }
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
