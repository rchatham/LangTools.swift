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
        MessageService.completeLastPendingChild(ofAgent: "Research", result: "42", in: &calls)

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
}