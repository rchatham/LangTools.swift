//
//  AgentToolCallMappingTests.swift
//  ChatTests
//

import Foundation
import LangTools
import ChatUI
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
        MessageService.completePendingChild(ofAgent: "Research", result: "42", in: &calls)

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
        MessageService.completePendingChild(ofAgent: "A", result: "", in: &calls)
        XCTAssertEqual(calls[0].children[0].status, .success)
        XCTAssertEqual(calls[0].children[0].result, "")
    }

    func testConcurrentToolCallsCompleteInCallOrder() {
        // toolCompleted carries no tool name, so completions match in call order (FIFO).
        var calls: [ChatToolCall] = [ChatToolCall(id: "a", name: "A", kind: .agent, status: .pending)]
        MessageService.appendChild(ChatToolCall(id: "t1", name: "toolA", kind: .tool, status: .pending), toAgent: "A", in: &calls)
        MessageService.appendChild(ChatToolCall(id: "t2", name: "toolB", kind: .tool, status: .pending), toAgent: "A", in: &calls)
        MessageService.completePendingChild(ofAgent: "A", result: "resA", in: &calls)
        MessageService.completePendingChild(ofAgent: "A", result: "resB", in: &calls)
        XCTAssertEqual(calls[0].children[0].name, "toolA")
        XCTAssertEqual(calls[0].children[0].result, "resA")
        XCTAssertEqual(calls[0].children[0].status, .success)
        XCTAssertEqual(calls[0].children[1].name, "toolB")
        XCTAssertEqual(calls[0].children[1].result, "resB")
        XCTAssertEqual(calls[0].children[1].status, .success)
    }
}