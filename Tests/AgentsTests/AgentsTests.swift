//
//  AgentsTests.swift
//  LangTools
//
//  Tests for the Agents module: execution, events, delegation, and prompts.
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
        messages: [any LangToolsMessage] = [],
        events: @escaping (AgentEvent) -> Void = { _ in },
        parent: (any Agent)? = nil,
        tools: [any LangToolsTool]? = nil
    ) -> AgentContext {
        let userMessages: [any LangToolsMessage] = messages.isEmpty
            ? [OpenAI.Message(role: .user, content: "Hello")]
            : messages
        return AgentContext(
            langTool: api!,
            model: OpenAI.Model.gpt4o,
            messages: userMessages,
            eventHandler: events,
            parent: parent,
            tools: tools
        )
    }

    private func mockChatResponse(content: String) -> Data {
        return """
        {
            "id": "chatcmpl-agent-test",
            "object": "chat.completion",
            "created": 1700000000,
            "model": "gpt-4o",
            "choices": [{
                "index": 0,
                "message": {"role": "assistant", "content": "\(content)"},
                "finish_reason": "stop"
            }],
            "usage": {"prompt_tokens": 50, "completion_tokens": 20, "total_tokens": 70}
        }
        """.data(using: .utf8)!
    }

    private func mockEmptyResponse() -> Data {
        return """
        {
            "id": "chatcmpl-agent-empty",
            "object": "chat.completion",
            "created": 1700000000,
            "model": "gpt-4o",
            "choices": [{
                "index": 0,
                "message": {"role": "assistant", "content": ""},
                "finish_reason": "stop"
            }],
            "usage": {"prompt_tokens": 50, "completion_tokens": 0, "total_tokens": 50}
        }
        """.data(using: .utf8)!
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

    func testAgentExecuteEmitsStartedAndCompletedEvents() async throws {
        MockURLProtocol.mockNetworkHandlers[OpenAI.ChatCompletionRequest.endpoint] = { _ in
            (.success(self.mockChatResponse(content: "Done.")), 200)
        }

        var events: [AgentEvent] = []
        let agent = TestAgent(name: "EventAgent")
        let context = makeContext(events: { events.append($0) })
        _ = try await agent.execute(context: context)

        XCTAssertGreaterThanOrEqual(events.count, 2)
        // First event should be .started
        if case .started(let agentName, _, _) = events.first {
            XCTAssertEqual(agentName, "EventAgent")
        } else {
            XCTFail("First event should be .started")
        }
        // Last event should be .completed
        if case .completed(let agentName, let result, let isError) = events.last {
            XCTAssertEqual(agentName, "EventAgent")
            XCTAssertEqual(result, "Done.")
            XCTAssertFalse(isError)
        } else {
            XCTFail("Last event should be .completed")
        }
    }

    func testAgentExecuteEmptyResponseThrows() async throws {
        MockURLProtocol.mockNetworkHandlers[OpenAI.ChatCompletionRequest.endpoint] = { _ in
            (.success(self.mockEmptyResponse()), 200)
        }

        var errorEventFired = false
        let agent = TestAgent()
        let context = makeContext(events: { event in
            if case .error = event { errorEventFired = true }
        })

        do {
            _ = try await agent.execute(context: context)
            XCTFail("Should have thrown for empty response")
        } catch {
            XCTAssertTrue(error is AgentError)
        }
        XCTAssertTrue(errorEventFired)
    }

    func testAgentExecuteNetworkErrorThrows() async throws {
        MockURLProtocol.mockNetworkHandlers[OpenAI.ChatCompletionRequest.endpoint] = { _ in
            (.failure(URLError(.notConnectedToInternet)), nil)
        }

        var completedWithError = false
        let agent = TestAgent()
        let context = makeContext(events: { event in
            if case .completed(_, _, let isError) = event, isError {
                completedWithError = true
            }
        })

        do {
            _ = try await agent.execute(context: context)
            XCTFail("Should have thrown for network error")
        } catch {
            XCTAssertTrue(error is AgentError)
        }
        XCTAssertTrue(completedWithError)
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

    // MARK: - System Prompt

    func testSystemPromptContainsAgentInfo() async throws {
        var capturedBody: [String: Any]?
        MockURLProtocol.mockNetworkHandlers[OpenAI.ChatCompletionRequest.endpoint] = { request in
            capturedBody = try? JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any]
            return (.success(self.mockChatResponse(content: "OK")), 200)
        }

        let agent = TestAgent(
            name: "WeatherBot",
            description: "Provides weather info",
            instructions: "Always give temperatures in Fahrenheit"
        )
        let context = makeContext()
        _ = try await agent.execute(context: context)

        // The system prompt should be the first message
        let messages = capturedBody?["messages"] as? [[String: Any]]
        XCTAssertNotNil(messages)
        let systemMessage = messages?.first(where: { ($0["role"] as? String) == "system" || ($0["role"] as? String) == "developer" })
        let systemContent = systemMessage?["content"] as? String
        XCTAssertTrue(systemContent?.contains("WeatherBot") ?? false, "System prompt should contain agent name")
        XCTAssertTrue(systemContent?.contains("weather") ?? false, "System prompt should contain description")
        XCTAssertTrue(systemContent?.contains("Fahrenheit") ?? false, "System prompt should contain instructions")
    }

    func testSystemPromptIncludesToolList() async throws {
        var capturedBody: [String: Any]?
        MockURLProtocol.mockNetworkHandlers[OpenAI.ChatCompletionRequest.endpoint] = { request in
            capturedBody = try? JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any]
            return (.success(self.mockChatResponse(content: "OK")), 200)
        }

        let tools: [any LangToolsTool] = [
            Tool(name: "calculator", description: "Do math", tool_schema: ToolSchema<ToolSchemaProperty>(properties: [:]))
        ]
        let agent = TestAgent(tools: tools)
        let context = makeContext()
        _ = try await agent.execute(context: context)

        let messages = capturedBody?["messages"] as? [[String: Any]]
        let systemMessage = messages?.first(where: { ($0["role"] as? String) == "system" || ($0["role"] as? String) == "developer" })
        let systemContent = systemMessage?["content"] as? String
        XCTAssertTrue(systemContent?.contains("calculator") ?? false, "System prompt should list tool names")
    }

    func testSystemPromptIncludesDelegateAgents() async throws {
        var capturedBody: [String: Any]?
        MockURLProtocol.mockNetworkHandlers[OpenAI.ChatCompletionRequest.endpoint] = { request in
            capturedBody = try? JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any]
            return (.success(self.mockChatResponse(content: "OK")), 200)
        }

        let delegate = TestAgent(name: "HelperBot", description: "Assists with tasks")
        let agent = TestAgent(delegateAgents: [delegate])
        let context = makeContext()
        _ = try await agent.execute(context: context)

        let messages = capturedBody?["messages"] as? [[String: Any]]
        let systemMessage = messages?.first(where: { ($0["role"] as? String) == "system" || ($0["role"] as? String) == "developer" })
        let systemContent = systemMessage?["content"] as? String
        XCTAssertTrue(systemContent?.contains("HelperBot") ?? false, "System prompt should list delegate agent names")
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
        XCTAssertEqual(d, e)
    }
}
