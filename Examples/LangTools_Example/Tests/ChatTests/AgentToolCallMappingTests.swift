//
//  AgentToolCallMappingTests.swift
//  ChatTests
//

import Agents
import ChatUI
import Foundation
import LangTools
import OpenAI
import XCTest
@testable import Chat

@MainActor
final class AgentToolCallMappingTests: XCTestCase {

    func testAgentStartedToolCallCompletedAndAgentCompleted() {
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
        let agent = calls[0]
        XCTAssertEqual(agent.kind, .agent)
        XCTAssertEqual(agent.name, "Research")
        XCTAssertEqual(agent.status, .success)
        XCTAssertEqual(agent.result, "42")
        XCTAssertEqual(agent.children.count, 1)
        let tool = agent.children[0]
        XCTAssertEqual(tool.kind, .tool)
        XCTAssertEqual(tool.name, "calculate")
        XCTAssertEqual(tool.status, .success)
        XCTAssertEqual(tool.result, "42")
    }

    func testAgentDelegationNestsAsAgentChild() {
        var calls: [ChatToolCall] = []
        calls.append(ChatToolCall(id: "main", name: "Main", kind: .agent, status: .pending, details: "started: task"))

        // Main delegates to Research
        MessageService.appendChild(
            ChatToolCall(id: "sub", name: "Research", kind: .agent, status: .pending, details: "delegated: because"),
            toAgent: "Main", in: &calls)

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].children.count, 1)
        let sub = calls[0].children[0]
        XCTAssertEqual(sub.kind, .agent)
        XCTAssertEqual(sub.name, "Research")
        XCTAssertEqual(sub.details, "delegated: because")
    }

    func testSetAgentStatusOnlyAffectsMatchingAgent() {
        var calls: [ChatToolCall] = [
            ChatToolCall(id: "a", name: "A", kind: .agent, status: .pending),
            ChatToolCall(id: "b", name: "B", kind: .agent, status: .pending)
        ]
        MessageService.setAgentStatus("B", status: .failure, result: "oops", in: &calls)
        XCTAssertEqual(calls[0].status, .pending)
        XCTAssertEqual(calls[1].status, .failure)
        XCTAssertEqual(calls[1].result, "oops")
    }

    func testNilResultToolCompletionStillCompletesChild() {
        // toolCompleted may fire with a nil result; the child must still complete.
        var calls: [ChatToolCall] = [ChatToolCall(id: "a", name: "A", kind: .agent, status: .pending)]
        MessageService.appendChild(ChatToolCall(id: "t", name: "tool", kind: .tool, status: .pending), toAgent: "A", in: &calls)
        MessageService.completePendingChild(ofAgent: "A", result: "", status: .success, in: &calls)
        XCTAssertEqual(calls[0].children[0].status, .success)
        XCTAssertEqual(calls[0].children[0].result, "")
    }

    func testConcurrentToolCallsCompleteInCallOrder() {
        // toolCompleted carries no tool name, so completions match in call order (FIFO).
        var calls: [ChatToolCall] = [ChatToolCall(id: "a", name: "A", kind: .agent, status: .pending)]
        MessageService.appendChild(ChatToolCall(id: "t1", name: "toolA", kind: .tool, status: .pending), toAgent: "A", in: &calls)
        MessageService.appendChild(ChatToolCall(id: "t2", name: "toolB", kind: .tool, status: .pending), toAgent: "A", in: &calls)
        MessageService.completePendingChild(ofAgent: "A", result: "resA", status: .success, in: &calls)
        MessageService.completePendingChild(ofAgent: "A", result: "resB", status: .success, in: &calls)
        XCTAssertEqual(calls[0].children[0].name, "toolA")
        XCTAssertEqual(calls[0].children[0].result, "resA")
        XCTAssertEqual(calls[0].children[0].status, .success)
        XCTAssertEqual(calls[0].children[1].name, "toolB")
        XCTAssertEqual(calls[0].children[1].result, "resB")
        XCTAssertEqual(calls[0].children[1].status, .success)
    }

    func testDelegationDoesNotDuplicateAgentCard() {
        // agentTransfer then started(to, parent) must produce a single sub-agent card.
        var calls: [ChatToolCall] = [ChatToolCall(id: "main", name: "Main", kind: .agent, status: .pending)]
        // .agentTransfer(Main, to: Research, reason)
        MessageService.appendChild(ChatToolCall(id: "d", name: "Research", kind: .agent, status: .pending, details: "delegated: because"), toAgent: "Main", in: &calls)
        // .started(Research, parent: Main, task) -> should update existing, not duplicate
        let updated = MessageService.updateAgentChildDetails("Research", parent: "Main", append: "started: find", in: &calls)
        XCTAssertTrue(updated)
        XCTAssertEqual(calls[0].children.count, 1)
        XCTAssertEqual(calls[0].children[0].name, "Research")
        XCTAssertTrue(calls[0].children[0].details?.contains("delegated") == true)
        XCTAssertTrue(calls[0].children[0].details?.contains("started") == true)
    }

    func testToolErrorCompletesPendingToolWithoutCompletingAgentChild() {
        var calls: [ChatToolCall] = [ChatToolCall(id: "a", name: "A", kind: .agent, status: .pending)]
        MessageService.appendChild(ChatToolCall(id: "sub", name: "Delegate", kind: .agent, status: .pending), toAgent: "A", in: &calls)
        MessageService.appendChild(ChatToolCall(id: "t", name: "tool", kind: .tool, status: .pending), toAgent: "A", in: &calls)
        MessageService.completePendingChild(ofAgent: "A", result: "boom", status: .failure, in: &calls)
        XCTAssertEqual(calls[0].children[0].status, .pending)
        XCTAssertNil(calls[0].children[0].result)
        XCTAssertEqual(calls[0].children[1].status, .failure)
        XCTAssertEqual(calls[0].children[1].result, "boom")
    }

    func testCompleteRemainingPendingClearsStuckChildrenAndPreservesFailures() {
        var calls: [ChatToolCall] = [ChatToolCall(id: "a", name: "A", kind: .agent, status: .pending, children: [
            ChatToolCall(id: "c1", name: "subagent", kind: .agent, status: .pending, children: [
                ChatToolCall(id: "g1", name: "failedTool", kind: .tool, status: .failure, result: "boom"),
                ChatToolCall(id: "g2", name: "pendingTool", kind: .tool, status: .pending)
            ]),
            ChatToolCall(id: "c2", name: "toolB", kind: .tool, status: .success, result: "ok")
        ])]
        MessageService.completeRemainingPending(ofAgent: "A", status: .success, in: &calls)
        XCTAssertEqual(calls[0].children[0].status, .success)
        XCTAssertEqual(calls[0].children[0].children[0].status, .failure)
        XCTAssertEqual(calls[0].children[0].children[1].status, .success)
        XCTAssertEqual(calls[0].children[1].status, .success)
    }

    func testFailedCalendarReadRetrySucceedsAsSeparateInvocation() throws {
        let calls = runCalendarReadRetry(secondAttemptFails: false)
        try assertCalendarReadRetry(calls, expectedRetryStatus: .success)
    }

    func testFailedCalendarReadRetryFailsAsSeparateInvocation() throws {
        let calls = runCalendarReadRetry(secondAttemptFails: true)
        try assertCalendarReadRetry(calls, expectedRetryStatus: .failure)
    }

    private func runCalendarReadRetry(secondAttemptFails: Bool) -> [ChatToolCall] {
        let service = MessageService(networkClient: AgentEventNetworkStub())
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
        return service.messages[0].toolCalls
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
        XCTAssertEqual(reads[0].status, .failure, file: file, line: line)
        XCTAssertEqual(reads[0].result, "first attempt failed", file: file, line: line)
        XCTAssertEqual(reads[1].status, expectedRetryStatus, file: file, line: line)
        XCTAssertEqual(reads[1].result, expectedRetryStatus == .success ? "event found" : "retry failed", file: file, line: line)
        XCTAssertFalse(calls.flattened().contains { $0.name == "agent_transfer" }, file: file, line: line)
        XCTAssertFalse(calls.flattened().contains { $0.status == .pending }, file: file, line: line)
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
