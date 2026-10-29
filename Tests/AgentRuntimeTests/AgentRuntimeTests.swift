//
//  AgentRuntimeTests.swift
//  AgentRuntimeTests
//

import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import AgentRuntime
import AgentRuntimeProviders
@testable import Agents
@testable import LangTools
@testable import OpenAI
@testable import TestUtils

final class AgentRuntimeTests: XCTestCase {
    var session: URLSession!

    override func setUp() {
        super.setUp()
        _ = URLProtocol.registerClass(MockURLProtocol.self)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)
    }

    override func tearDown() {
        MockURLProtocol.resetHandlers()
        URLProtocol.unregisterClass(MockURLProtocol.self)
        super.tearDown()
    }

    // MARK: - Helpers

    private let openAI = LangToolsProviderID(rawValue: "openai")

    private func spec(tools: [String] = [], delegates: [AgentSpec] = [], timeout: Double? = nil) -> AgentSpec {
        AgentSpec(name: "Researcher", instructions: "Answer briefly.", provider: openAI, model: "gpt-4o", messages: [.user("What is 6 x 7?")], tools: tools, delegates: delegates, timeoutSeconds: timeout)
    }

    private func runner(tools: AgentToolRegistry = .builtIn, keys: [LangToolsProviderID: String]? = nil) -> AgentRunner {
        AgentRunner(providers: .builtIn, tools: tools, credentials: .keys(keys ?? [openAI: "sk-test"]), session: session)
    }

    private func chatResponse(content: String) -> Data {
        let body: [String: Any] = [
            "id": "chatcmpl-runtime", "object": "chat.completion", "created": 1700000000, "model": "gpt-4o",
            "choices": [["index": 0, "message": ["role": "assistant", "content": content], "finish_reason": "stop"] as [String: Any]],
            "usage": ["prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15],
        ]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    private func toolCallResponse(tool: String, arguments: String) -> Data {
        let body: [String: Any] = [
            "id": "chatcmpl-runtime-tool", "object": "chat.completion", "created": 1700000000, "model": "gpt-4o",
            "choices": [[
                "index": 0,
                "message": ["role": "assistant", "content": NSNull(), "tool_calls": [["id": "call_1", "type": "function", "function": ["name": tool, "arguments": arguments]]]] as [String: Any],
                "finish_reason": "tool_calls",
            ] as [String: Any]],
            "usage": ["prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15],
        ]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    private func recordingTool(name: String = "lookup", delay: Double = 0, calls: CallLog) -> Tool {
        Tool(name: name, description: "Looks something up.", tool_schema: .init(properties: ["query": .init(type: "string")], required: ["query"])) { _, args in
            if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            calls.append(args["query"]?.stringValue ?? "")
            return "42"
        }
    }

    // MARK: - Spec

    func testMinimalSpecDecodesWithDefaults() throws {
        let json = """
        {"name": "Helper", "instructions": "Be helpful.", "provider": "anthropic", "model": "claude-sonnet-4-6",
         "messages": [{"role": "user", "content": "Hi"}]}
        """
        let spec = try AgentSpec.decode(from: Data(json.utf8))
        XCTAssertEqual(spec.version, AgentSpec.currentVersion)
        XCTAssertEqual(spec.provider.rawValue, "anthropic")
        XCTAssertEqual(spec.tools, [])
        XCTAssertEqual(spec.delegates, [])
        XCTAssertNil(spec.timeoutSeconds)
        XCTAssertNoThrow(try spec.validateStructure())
    }

    func testSpecRoundTrips() throws {
        let original = spec(tools: ["current_time"], delegates: [AgentSpec(name: "Math", instructions: "Do math.", provider: openAI, model: "gpt-4o", messages: [])], timeout: 30)
        XCTAssertEqual(try AgentSpec.decode(from: original.encoded()), original)
    }

    func testSpecWithoutUserMessageIsInvalid() {
        var spec = spec()
        spec.messages = [.system("Context only")]
        XCTAssertThrowsError(try spec.validateStructure())
    }

    func testDuplicateAgentNamesAreInvalid() {
        let delegate = AgentSpec(name: "Researcher", instructions: "x", provider: openAI, model: "gpt-4o", messages: [])
        XCTAssertThrowsError(try spec(delegates: [delegate]).validateStructure()) { error in
            XCTAssertTrue(error.localizedDescription.contains("Researcher"))
        }
    }

    func testDelegateMustShareProviderAndModel() {
        let delegate = AgentSpec(name: "Math", instructions: "x", provider: openAI, model: "gpt-4o-mini", messages: [])
        XCTAssertThrowsError(try spec(delegates: [delegate]).validateStructure())
    }

    func testNonPositiveTimeoutAndFutureVersionAreInvalid() {
        XCTAssertThrowsError(try spec(timeout: 0).validateStructure())
        var future = spec()
        future.version = AgentSpec.currentVersion + 1
        XCTAssertThrowsError(try future.validateStructure())
    }

    func testAllToolNamesIncludesDelegates() {
        let delegate = AgentSpec(name: "Math", instructions: "x", provider: openAI, model: "gpt-4o", messages: [], tools: ["calculator"])
        XCTAssertEqual(spec(tools: ["current_time"], delegates: [delegate]).allToolNames, ["current_time", "calculator"])
    }

    // MARK: - Validation against registries

    func testUnknownProviderIsReportedWithAlternatives() async {
        var spec = spec()
        spec.provider = LangToolsProviderID(rawValue: "nope")
        let result = await runner().run(spec)
        XCTAssertEqual(result.status, .invalid)
        XCTAssertTrue(result.error?.contains("nope") ?? false)
        XCTAssertTrue(result.error?.contains("anthropic") ?? false, "Should list available providers: \(result.error ?? "")")
    }

    func testUnknownClosedCatalogModelIsInvalid() {
        var spec = spec()
        spec.provider = LangToolsProviderID(rawValue: "anthropic")
        spec.model = "claude-not-a-model"
        XCTAssertThrowsError(try runner(keys: [spec.provider: "k"]).validate(spec)) { error in
            XCTAssertEqual(error as? AgentRuntimeError, .unknownModel(provider: "anthropic", model: "claude-not-a-model"))
        }
    }

    func testUnknownToolsAreAllNamed() {
        XCTAssertThrowsError(try runner().validate(spec(tools: ["current_time", "a", "b"]))) { error in
            XCTAssertEqual(error as? AgentRuntimeError, .unknownTools(["a", "b"], available: ["current_time"]))
        }
    }

    func testMissingKeyNamesEnvironmentVariable() {
        XCTAssertThrowsError(try runner(keys: [:]).validate(spec())) { error in
            XCTAssertEqual(error as? AgentRuntimeError, .missingCredential(provider: "openai", environmentVariable: "OPENAI_API_KEY"))
        }
    }

    func testEnvironmentCredentialsUseProviderVariable() throws {
        let runner = AgentRunner(providers: .builtIn, credentials: .environment(["OPENAI_API_KEY": "sk-env"]), session: session)
        XCTAssertNoThrow(try runner.validate(spec()))
        let empty = AgentRunner(providers: .builtIn, credentials: .environment(["OPENAI_API_KEY": ""]), session: session)
        XCTAssertThrowsError(try empty.validate(spec()))
    }

    func testOllamaRunsWithoutKey() {
        let spec = AgentSpec(name: "Local", instructions: "x", provider: LangToolsProviderID(rawValue: "ollama"), model: "llama3.2", messages: [.user("hi")])
        XCTAssertNoThrow(try runner(keys: [:]).validate(spec))
    }

    func testEveryBuiltInProviderBuildsAClient() throws {
        for registration in AgentProviderRegistry.builtIn.all {
            XCTAssertNoThrow(try registration.makeClient(ProviderConfiguration(apiKey: "k", session: session)), registration.id.rawValue)
        }
    }

    // MARK: - Running

    func testRunReturnsAnswerAndSendsKeyFromCredentials() async throws {
        var authorization: String?
        MockURLProtocol.setHandler(for: OpenAI.ChatCompletionRequest.endpoint) { request in
            authorization = request.value(forHTTPHeaderField: "Authorization")
            return (.success(self.chatResponse(content: "42")), 200)
        }

        let result = await runner().run(spec())

        XCTAssertEqual(result.status, .completed, result.error ?? "")
        XCTAssertEqual(result.output, "42")
        XCTAssertEqual(authorization, "Bearer sk-test")
        XCTAssertEqual(result.events.first?.kind, .started)
        XCTAssertEqual(result.events.first?.detail, "What is 6 x 7?")
        XCTAssertEqual(result.events.last?.kind, .completed)
        XCTAssertFalse(String(decoding: try spec().encoded(), as: UTF8.self).contains("sk-test"))
    }

    func testRunCallsRegisteredTool() async throws {
        let calls = CallLog()
        MockURLProtocol.setHandler(for: OpenAI.ChatCompletionRequest.endpoint) { _ in
            MockURLProtocol.setHandler(for: OpenAI.ChatCompletionRequest.endpoint) { _ in (.success(self.chatResponse(content: "It is 42.")), 200) }
            return (.success(self.toolCallResponse(tool: "lookup", arguments: #"{"query":"answer"}"#)), 200)
        }

        let result = await runner(tools: AgentToolRegistry([recordingTool(calls: calls)])).run(spec(tools: ["lookup"]))

        XCTAssertEqual(result.status, .completed, result.error ?? "")
        XCTAssertEqual(result.output, "It is 42.")
        XCTAssertEqual(calls.values, ["answer"])
        XCTAssertTrue(result.events.contains { $0.kind == .toolCalled && $0.tool == "lookup" })
        XCTAssertTrue(result.events.contains { $0.kind == .toolCompleted && $0.detail == "42" })
    }

    func testRunTimesOut() async {
        let calls = CallLog()
        MockURLProtocol.setHandler(for: OpenAI.ChatCompletionRequest.endpoint) { _ in
            (.success(self.toolCallResponse(tool: "lookup", arguments: #"{"query":"slow"}"#)), 200)
        }

        let started = Date()
        let result = await runner(tools: AgentToolRegistry([recordingTool(delay: 10, calls: calls)])).run(spec(tools: ["lookup"], timeout: 0.3))

        XCTAssertEqual(result.status, .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "Timeout should cancel the slow tool")
        XCTAssertEqual(calls.values, [], "The cancelled tool should not finish")
    }

    func testTimeoutHoldsWhenWorkIgnoresCancellation() async {
        MockURLProtocol.setHandler(for: OpenAI.ChatCompletionRequest.endpoint) { _ in
            (.success(self.toolCallResponse(tool: "stuck", arguments: "{}")), 200)
        }
        // Blocks without checking for cancellation, like a request that never returns.
        let stuck = Tool(name: "stuck", description: "Never cooperates.", tool_schema: .init(), callback: { _, _ in
            let end = Date().addingTimeInterval(3)
            while Date() < end { usleep(10_000) }
            return "late"
        })

        let started = Date()
        let result = await runner(tools: AgentToolRegistry([stuck])).run(spec(tools: ["stuck"], timeout: 0.3))

        XCTAssertEqual(result.status, .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "The run must not wait for work that ignores cancellation")
    }

    func testProviderErrorIsReportedAsFailure() async {
        MockURLProtocol.setHandler(for: OpenAI.ChatCompletionRequest.endpoint) { _ in
            (.success(Data(#"{"error":{"message":"bad key","type":"invalid_request_error","param":null,"code":"invalid_api_key"}}"#.utf8)), 401)
        }
        let result = await runner().run(spec())
        XCTAssertEqual(result.status, .failed)
        XCTAssertNotNil(result.error)
        XCTAssertNil(result.output)
    }

    func testDelegatesKeepTheirOwnResponseSchema() throws {
        let schema = JSONSchema.object(properties: ["answer": .string()], required: ["answer"])
        var root = spec(delegates: [AgentSpec(name: "Math", instructions: "x", provider: openAI, model: "gpt-4o", messages: [])])
        root.responseSchema = schema
        let agent = try SpecAgent(spec: root, tools: .builtIn)
        XCTAssertEqual(agent.responseSchema, schema)
        XCTAssertNil(agent.delegateAgents.first?.responseSchema)
    }

    func testResultRoundTrips() throws {
        let result = AgentRunResult(agent: "a", provider: "openai", model: "gpt-4o", status: .completed, output: "ok",
                                    events: [.init(kind: .started, agent: "a", detail: "task", date: Date(timeIntervalSince1970: 1))],
                                    startedAt: Date(timeIntervalSince1970: 0), finishedAt: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(try AgentRunResult.decode(from: result.encoded()), result)
    }

    func testCurrentTimeTool() async throws {
        let tool = BuiltInTools.currentTime
        let info = LangToolsRequestInfo(langTool: OpenAI(apiKey: "k"), model: OpenAI.Model.gpt4o, messages: [])
        let utc = try await tool.callback?(info, [:])
        XCTAssertNotNil(utc.flatMap { ISO8601DateFormatter().date(from: $0) }, utc ?? "nil")
        let bad = try await tool.callback?(info, ["time_zone": .string("Mars/Olympus")])
        XCTAssertEqual(bad, "Unknown time zone 'Mars/Olympus'.")
    }
}

final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [String] = []
    var values: [String] { lock.lock(); defer { lock.unlock() }; return _values }
    func append(_ value: String) { lock.lock(); _values.append(value); lock.unlock() }
}
