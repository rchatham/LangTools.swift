//
//  AgentsTests.swift
//  LangTools
//
//  Tests for the Agents module: events, errors, and context.
//

import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LangTools
@testable import Agents
@testable import OpenAI
@testable import TestUtils

struct TestAgent: Agent {
    var name: String
    var description: String
    var instructions: String
    var tools: [any LangToolsTool]?
    var delegateAgents: [any Agent]
    var responseSchema: JSONSchema?

    init(name: String = "TestAgent",
         description: String = "A test agent",
         instructions: String = "Follow instructions",
         tools: [any LangToolsTool]? = nil,
         delegateAgents: [any Agent] = [],
         responseSchema: JSONSchema? = nil) {
        self.name = name
        self.description = description
        self.instructions = instructions
        self.tools = tools
        self.delegateAgents = delegateAgents
        self.responseSchema = responseSchema
    }
}

final class AgentsTests: XCTestCase {

    var api: OpenAI!

    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(MockURLProtocol.self)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        api = OpenAI(apiKey: "test-key").configure(testURLSessionConfiguration: config)
    }

    override func tearDown() {
        MockURLProtocol.mockNetworkHandlers.removeAll()
        URLProtocol.unregisterClass(MockURLProtocol.self)
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeContext(
        events: @escaping (AgentEvent) -> Void = { _ in },
        parent: (any Agent)? = nil
    ) -> AgentContext {
        let langTool: any LangTools = api!
        let model: any RawRepresentable = OpenAI.Model.gpt4o
        return AgentContext(
            langTool: langTool,
            model: model,
            messages: [OpenAI.Message(role: .user, content: "Hello")],
            eventHandler: events,
            parent: parent,
            tools: nil,
            responseSchema: nil
        )
    }

    private func mockChatResponse(content: String) -> Data {
        let body: [String: Any] = [
            "id": "chatcmpl-agent-test",
            "object": "chat.completion",
            "created": 1700000000,
            "model": "gpt-4o",
            "choices": [["index": 0, "message": ["role": "assistant", "content": content], "finish_reason": "stop"] as [String: Any]],
            "usage": ["prompt_tokens": 50, "completion_tokens": 20, "total_tokens": 70]
        ]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    // MARK: - Agent Execution

    func testAgentExecuteReturnsTextResponse() async throws {
        MockURLProtocol.mockNetworkHandlers[OpenAI.ChatCompletionRequest.endpoint] = { _ in
            (.success(self.mockChatResponse(content: "The answer is 42.")), 200)
        }

        let agent = TestAgent()
        let context = makeContext()
        let result = try await agent.execute(context: context)
        XCTAssertEqual(result, "The answer is 42.")
    }

    func testAgentExecuteEmptyResponseThrows() async throws {
        let emptyJSON = """
        {"id":"x","object":"chat.completion","created":0,"model":"gpt-4o","choices":[{"index":0,"message":{"role":"assistant","content":""},"finish_reason":"stop"}],"usage":{"prompt_tokens":0,"completion_tokens":0,"total_tokens":0}}
        """.data(using: .utf8)!
        MockURLProtocol.mockNetworkHandlers[OpenAI.ChatCompletionRequest.endpoint] = { _ in
            (.success(emptyJSON), 200)
        }

        let agent = TestAgent()
        let context = makeContext()
        do {
            _ = try await agent.execute(context: context)
            XCTFail("Should have thrown for empty response")
        } catch {
            // Pin the empty-content path specifically — asserting only `is AgentError` would also
            // pass on an unrelated failure (e.g. a missing mock handler) that the agent wraps.
            let agentError = error as? AgentError
            XCTAssertNotNil(agentError, "Expected AgentError, got \(type(of: error))")
            XCTAssertTrue(agentError?.message.contains("Failed to return text content") ?? false,
                          "Empty-response error should identify the empty-content path, got: \(agentError?.message ?? "nil")")
        }
    }

    func testAgentExecuteNetworkErrorThrows() async throws {
        MockURLProtocol.mockNetworkHandlers[OpenAI.ChatCompletionRequest.endpoint] = { _ in
            (.failure(URLError(.notConnectedToInternet)), nil)
        }

        let agent = TestAgent()
        let context = makeContext()
        do {
            _ = try await agent.execute(context: context)
            XCTFail("Should have thrown for network error")
        } catch {
            // Pin the network path: the wrapped error must surface the underlying connection
            // failure, and must NOT be the empty-content path (which would mean the wrong branch ran).
            let agentError = error as? AgentError
            XCTAssertNotNil(agentError, "Expected AgentError, got \(type(of: error))")
            let message = agentError?.message ?? ""
            // Match the stable error identity (URLError.notConnectedToInternet == code -1009) as well
            // as the friendly localized text, since which description surfaces is environment-dependent.
            XCTAssertTrue(message.contains("-1009") || message.contains("NSURLError")
                          || message.contains("Internet") || message.contains("offline")
                          || message.contains("network") || message.contains("connection"),
                          "Network error should surface the connection failure, got: \(message)")
            XCTAssertFalse(message.contains("Failed to return text content"),
                           "Should have hit the network path, not the empty-content path")
        }
    }

    // MARK: - Agent Event Description

    func testAgentEventDescriptions() {
        let started = AgentEvent.started(agent: "A", parent: nil, task: "Do X")
        XCTAssertTrue(started.description.contains("A"))
        XCTAssertTrue(started.description.contains("Do X"))

        let transfer = AgentEvent.agentTransfer(from: "A", to: "B", reason: "Need help")
        XCTAssertTrue(transfer.description.contains("A"))
        XCTAssertTrue(transfer.description.contains("B"))

        let completed = AgentEvent.completed(agent: "A", result: "done", is_error: false)
        XCTAssertTrue(completed.description.contains("completed"))

        let errorEvent = AgentEvent.completed(agent: "A", result: "oops", is_error: true)
        XCTAssertTrue(errorEvent.description.contains("error"))

        let toolCalled = AgentEvent.toolCalled(agent: "A", tool: "calc", arguments: "{}")
        XCTAssertTrue(toolCalled.description.contains("calc"))
    }

    // MARK: - AgentError

    func testAgentErrorMessage() {
        let error = AgentError("something went wrong")
        XCTAssertEqual(error.errorDescription, "something went wrong")
        XCTAssertEqual(error.message, "something went wrong")
    }

    // MARK: - AgentContext

    func testAgentContextInitialization() {
        let context = makeContext()
        XCTAssertNil(context.parent)
        XCTAssertNil(context.tools)
        XCTAssertNil(context.responseSchema)
        XCTAssertFalse(context.messages.isEmpty)
    }

    func testAgentContextWithParent() {
        let parent = TestAgent(name: "ParentAgent")
        let context = makeContext(parent: parent)
        XCTAssertNotNil(context.parent)
        XCTAssertEqual(context.parent?.name, "ParentAgent")
    }

    // MARK: - AgentEvent Equatable

    func testAgentEventEquatable() {
        let a = AgentEvent.started(agent: "A", parent: nil, task: "X")
        let b = AgentEvent.started(agent: "A", parent: nil, task: "X")
        let c = AgentEvent.started(agent: "B", parent: nil, task: "X")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)

        let d = AgentEvent.completed(agent: "A", result: "done")
        let e = AgentEvent.completed(agent: "A", result: "done", is_error: false)
        let f = AgentEvent.completed(agent: "A", result: "done", is_error: true)
        XCTAssertEqual(d, e)
        XCTAssertNotEqual(d, f, "Events with different is_error should not be equal")
    }
}
