import Agents
import ChatUI
import Foundation
import LangTools
import OpenAI
import ToolKit
import XCTest
@testable import Chat

/// Only value settings, synthetic agents/callbacks and a fail-closed memory client.
/// No preferences, provider factories, credentials, sessions or tool registries.
@MainActor
final class MessageServiceDependencyTests: XCTestCase {
    @MainActor
    private final class Inputs {
        var model: Model = .openAI(.gpt4o_mini)
        var settings = ChatConversationSettings(systemPrompt: "memory prompt")
        var history = true
        var budget: Int? = nil
        var enabled: [OpenAI.Tool]? = nil
        var configurations: [ToolConfiguration] = []
        var reads: [String] = []

        var dependencies: MessageService.Dependencies {
            .init(
                selectedModel: { self.reads.append("model"); return self.model },
                conversationSettings: { self.reads.append("settings"); return self.settings },
                keepsToolCallsInHistory: { self.reads.append("history"); return self.history },
                maxToolIterations: { self.reads.append("budget"); return self.budget },
                enabledTools: { self.reads.append("enabled"); return self.enabled },
                toolConfigurations: { self.reads.append("configurations"); return self.configurations }
            )
        }

        func service(_ client: MemoryMessageClient, agents: [any Agent]? = nil, tools: [Tool]? = nil) -> MessageService {
            MessageService(networkClient: client, agents: agents, tools: tools, dependencies: dependencies)
        }
    }

    private func configuration(_ name: String, isAgent: Bool = false) -> ToolConfiguration {
        ToolConfiguration(id: name, displayName: name, description: "synthetic", iconName: "", isAgent: isAgent,
                          callback: { _ in XCTFail("Unscripted callback: \(name)"); throw MemoryMessageError.unexpected })
    }

    func testConstructionIsLazyAndHistoryAssignmentAndStoppedCallbacksUseDynamicPolicy() throws {
        let inputs = Inputs()
        let service = inputs.service(MemoryMessageClient())
        XCTAssertTrue(inputs.reads.isEmpty)
        var snapshots: [Message] = []
        service.messageUpdatedCallback = { snapshots.append($0) }
        let loaded = Message(text: "loaded", role: .assistant)
        loaded.toolCalls = [ChatToolCall(id: "call", name: "memory", status: .success, result: "result")]
        loaded.providerToolResults = ["call": "raw"]
        inputs.history = false
        service.messages = [loaded]
        XCTAssertEqual(inputs.reads, ["history"])
        XCTAssertTrue(try XCTUnwrap(snapshots.last).toolCalls.isEmpty)
        XCTAssertEqual(loaded.toolCalls.count, 1, "Loading must not mutate authoritative history")
        inputs.history = true
        service.messages = [loaded]
        XCTAssertTrue(try XCTUnwrap(snapshots.last) === loaded)
        let user = Message(text: "stopped", role: .user)
        service.messages.append(user)
        inputs.history = false
        service.markResponseStopped(messageID: user.uuid)
        XCTAssertTrue(try XCTUnwrap(snapshots.last).wasResponseStopped)
        XCTAssertEqual(inputs.reads, ["history", "history", "history", "history"])
    }

    func testModelPromptMemoryAndContextRemainDynamicAtOriginalReadSites() async throws {
        let inputs = Inputs()
        let client = MemoryMessageClient()
        let service = inputs.service(client)
        inputs.settings = .init(systemPrompt: "first", maxContextMessages: 2, memoryFields: [
            .init(label: "Name", value: "Synthetic"), .init(label: "", value: "omit-one"),
            .init(label: "omit-two", value: "")
        ])
        service.messages = [Message(text: "old", role: .user), Message(text: "answer", role: .assistant)]
        client.replies = [.text("one"), .text("two"), .text("three")]
        try await service.send(message: "new", stream: true)
        let first = try XCTUnwrap(client.requests.first)
        XCTAssertEqual(first.model, .openAI(.gpt4o_mini))
        XCTAssertTrue(first.stream)
        XCTAssertEqual(first.messages.dropFirst().map(\.text), ["answer", "new"])
        let prompt = try XCTUnwrap(first.messages.first?.text)
        XCTAssertTrue(prompt.hasPrefix("first\n\n## User Context\n- Name: Synthetic\n"))
        XCTAssertFalse(prompt.contains("omit-"))
        XCTAssertTrue(prompt.hasSuffix("If an agent tool returns an error, explain the error to the user."))
        inputs.model = .openAI(.gpt4o)
        inputs.settings = .init(systemPrompt: "second", maxContextMessages: 0)
        try await service.send(message: "next", stream: false)
        XCTAssertEqual(client.requests[1].model, .openAI(.gpt4o))
        XCTAssertFalse(client.requests[1].stream)
        XCTAssertEqual(client.requests[1].messages.dropFirst().map(\.text), ["old", "answer", "new", "one", "next"])
        XCTAssertTrue(client.requests[1].messages[0].text?.hasPrefix("second\n\nWhen agent tools") == true)
        inputs.settings = .init(systemPrompt: "third", maxContextMessages: nil)
        try await service.send(message: "last")
        XCTAssertEqual(client.requests[2].messages.count, 8)
        XCTAssertEqual(inputs.reads.filter { $0 == "model" }.count, 3)
        XCTAssertEqual(inputs.reads.filter { $0 == "settings" }.count, 6, "Snapshot and prompt keep separate lookup timing")
        XCTAssertTrue(client.replies.isEmpty)
    }

    func testSnapshotPrecedesTaskButModelPromptAndToolsAreReadWhenSendStarts() async throws {
        let inputs = Inputs()
        inputs.settings = .init(systemPrompt: "snapshot", maxContextMessages: 1)
        let client = MemoryMessageClient()
        let service = inputs.service(client)
        service.messages = [Message(text: "excluded by snapshot", role: .assistant)]
        client.replies = [.text("answer")]
        let operation = service.sendOperation(message: "current")
        XCTAssertEqual(inputs.reads, ["history", "history", "history", "settings"])
        inputs.settings = .init(systemPrompt: "task prompt", maxContextMessages: 0)
        inputs.model = .openAI(.gpt4o)
        inputs.enabled = []
        try await operation.waitForCompletion()
        let request = try XCTUnwrap(client.requests.first)
        XCTAssertEqual(request.messages.dropFirst().map(\.text), ["current"])
        XCTAssertEqual(request.model, .openAI(.gpt4o))
        XCTAssertTrue(request.messages[0].text?.hasPrefix("task prompt") == true)
        XCTAssertEqual(request.tools?.count, 0)
    }

    func testToolSelectionPreservesNilEmptyIntersectionAgentOrderAndConfigurationDeduplication() throws {
        let inputs = Inputs()
        let supplied = [Tool(configuration("supplied").toTool()), Tool(configuration("disabled").toTool())]
        let service = inputs.service(MemoryMessageClient(), agents: [MemoryAgent(name: "agent"), MemoryAgent(name: "off-agent")], tools: supplied)
        XCTAssertNil(service.filteredTools(for: UUID()))
        XCTAssertEqual(inputs.reads, ["enabled"], "Nil enabled set must not resolve configurations")
        inputs.enabled = []
        XCTAssertEqual(service.filteredTools(for: UUID())?.count, 0)
        inputs.enabled = ["agent", "supplied", "missing", "agent-config"].map { configuration($0).toTool() }
        inputs.configurations = [configuration("supplied"), configuration("missing"), configuration("agent-config", isAgent: true), configuration("disabled")]
        XCTAssertEqual(service.filteredTools(for: UUID())?.map(\.name), ["agent", "supplied", "missing"])
        // Preserve the actual algorithm: duplicates among supplied tools remain;
        // configurations only skip names already in the supplied/agent snapshot.
        service.tools = [supplied[0], supplied[0]]
        XCTAssertEqual(service.filteredTools(for: UUID())?.map(\.name), ["agent", "supplied", "supplied", "missing"])
        inputs.configurations.append(configuration("missing"))
        XCTAssertEqual(service.filteredTools(for: UUID())?.map(\.name), ["agent", "supplied", "supplied", "missing", "missing"])
    }

    func testBudgetsAreDynamicPerSendAndClaimBeforeSyntheticCallbacks() async throws {
        let inputs = Inputs()
        var executions = 0
        let config = ToolConfiguration(id: "counter", displayName: "Counter", description: "memory", iconName: "", callback: { _ in
            executions += 1
            return "counted"
        })
        inputs.enabled = [config.toTool()]
        inputs.configurations = [config]
        let client = MemoryMessageClient()
        let service = inputs.service(client)
        for (budget, allowed) in [(0 as Int?, 0), (1 as Int?, 1), (nil, 3)] {
            inputs.budget = budget
            client.replies.append(.text("done"))
            try await service.send(message: "budget")
            let tool = try XCTUnwrap(client.requests.last?.tools?.first)
            let callback = try XCTUnwrap(tool.callback)
            let before = executions
            for index in 0..<3 {
                do {
                    let result = try await callback(MemoryLanguage.info, [:])
                    XCTAssertLessThan(index, allowed)
                    XCTAssertEqual(result, "counted")
                } catch let error as LangToolsRequestError {
                    XCTAssertGreaterThanOrEqual(index, allowed)
                    XCTAssertEqual(error.localizedDescription, "Tool iteration limit reached.")
                }
            }
            XCTAssertEqual(executions - before, allowed)
        }
    }

    func testHistoryPolicySanitizesLoadedRequestAndTerminalToolEventsWithoutChangingLiveOrdering() async throws {
        for keepsHistory in [false, true] {
            let inputs = Inputs()
            inputs.history = keepsHistory
            let client = MemoryMessageClient()
            let service = inputs.service(client)
            let loaded = Message(text: "loaded", role: .assistant)
            loaded.toolCalls = [ChatToolCall(id: "old-call", name: "old-tool", status: .success, result: "old")]
            loaded.providerToolResults = ["old-call": "raw"]
            service.messages = [loaded]
            var persisted: [[ChatToolCall.Status]] = []
            service.messageUpdatedCallback = { if !$0.toolCalls.isEmpty { persisted.append($0.toolCalls.map(\.status)) } }
            client.replies = [.tool]
            try await service.send(message: "events")
            XCTAssertEqual(client.requests[0].messages[1].toolCalls.count, keepsHistory ? 1 : 0)
            XCTAssertEqual(client.requests[0].messages[1].providerToolResults, keepsHistory ? ["old-call": "raw"] : [:])
            XCTAssertEqual(loaded.toolCalls.count, 1)
            XCTAssertEqual(service.messages.flatMap(\.toolCalls).count, keepsHistory ? 2 : 1)
            XCTAssertEqual(persisted, keepsHistory ? [[.pending], [.success]] : [])
            XCTAssertEqual(service.messages.last?.text, "follow-up")
            XCTAssertEqual(service.bufferedEventCountForTesting, 0)
        }
    }

    func testFailedAttemptsAreExcludedAndRetryUsesCurrentProviders() async throws {
        let inputs = Inputs()
        let client = MemoryMessageClient()
        let service = inputs.service(client)
        client.replies = [.failure, .text("recovered")]
        do { try await service.send(message: "failed"); XCTFail("Expected scripted failure") }
        catch MemoryMessageError.scripted { }
        let failed = try XCTUnwrap(service.messages.first)
        XCTAssertNotNil(failed.sendFailure)
        inputs.model = .openAI(.gpt4o)
        let retry = try service.retryOperation(messageID: failed.uuid)
        try await retry.waitForCompletion()
        XCTAssertEqual(client.requests[1].messages.dropFirst().map(\.text), ["failed"])
        XCTAssertEqual(client.requests[1].model, .openAI(.gpt4o))
        XCTAssertEqual(service.messages.map(\.text), ["failed", "recovered"])
        XCTAssertNil(failed.sendFailure)
    }

    func testNewSendExcludesFailedAttemptAndNilParserUsesDefaultAgentRendering() async throws {
        let inputs = Inputs()
        let client = MemoryMessageClient()
        let service = inputs.service(client)
        client.replies = [.failure, .text("success")]
        do { try await service.send(message: "failed"); XCTFail("Expected scripted failure") }
        catch MemoryMessageError.scripted { }
        try await service.send(message: "fresh")
        XCTAssertEqual(client.requests[1].messages.dropFirst().map(\.text), ["fresh"])
        XCTAssertTrue(service.messages.contains { $0.text == "failed" && $0.sendFailure != nil })
        service.handleAgentEvent(.started(agent: "agent", parent: nil, task: "memory"))
        service.handleAgentEvent(.completed(agent: "agent", result: "visible"))
        service.drainAgentEvents()
        let call = try XCTUnwrap(service.messages.flatMap(\.toolCalls).last)
        XCTAssertEqual(call.status, .success)
        XCTAssertEqual(call.result, "visible")
        XCTAssertTrue(service.messages.allSatisfy { $0.providerToolResults.isEmpty })
    }

    func testCancellationDrainsOwnedSendWithoutMarkingFailure() async throws {
        let inputs = Inputs()
        let client = MemoryMessageClient()
        let service = inputs.service(client)
        client.replies = [.held]
        let operation = service.sendOperation(message: "cancel")
        try await operation.waitUntilEstablished()
        operation.cancel()
        client.finishHeld()
        do { try await operation.waitForCompletion(); XCTFail("Expected cancellation") }
        catch is CancellationError { }
        XCTAssertNil(service.messages.first?.sendFailure)
        XCTAssertEqual(service.bufferedEventCountForTesting, 0)
    }

    func testCompatibilityDrainUsesOwnedDynamicModelParserAndHistoryPolicy() throws {
        let inputs = Inputs()
        let service = inputs.service(MemoryMessageClient())
        service.agentResultParser = { result, name in
            XCTAssertEqual(name, "agent")
            return Message(text: "card: \(result)", role: .assistant)
        }
        service.handleAgentEvent(.started(agent: "agent", parent: nil, task: "memory"))
        service.handleAgentEvent(.completed(agent: "agent", result: "raw"))
        service.drainAgentEvents()
        let anchor = try XCTUnwrap(service.messages.first)
        XCTAssertEqual(Array(anchor.providerToolResults.values), ["raw"])
        XCTAssertEqual(Array(anchor.providerToolResultServices.values), [.openAI])
        inputs.model = .anthropic(.claude46Sonnet)
        service.handleAgentEvent(.started(agent: "agent", parent: nil, task: "again"))
        service.handleAgentEvent(.completed(agent: "agent", result: "second"))
        service.drainToolEvents()
        XCTAssertEqual(service.messages.flatMap { $0.providerToolResultServices.values }.filter { $0 == .anthropic }.count, 1)
        inputs.history = false
        service.handleAgentEvent(.started(agent: "agent", parent: nil, task: "discard"))
        service.handleAgentEvent(.completed(agent: "agent", result: "private"))
        service.drainAgentEvents()
        XCTAssertFalse(service.messages.flatMap { $0.providerToolResults.values }.contains("private"))
        XCTAssertEqual(inputs.reads.filter { $0 == "model" }.count, 3)
    }

    func testInFlightAgentReplayProvenanceUsesCapturedModelAndNextSendUsesReplacement() async throws {
        let inputs = Inputs()
        let agent = MemoryAgent(name: "agent")
        inputs.enabled = [configuration("agent").toTool()]
        let client = MemoryMessageClient()
        let service = inputs.service(client, agents: [agent])
        service.agentResultParser = { result, _ in Message(text: "card: \(result)", role: .assistant) }
        client.replies = [.held, .text("next")]
        let operation = service.sendOperation(message: "delegate")
        try await operation.waitUntilEstablished()
        inputs.model = .anthropic(.claude46Sonnet)
        let tool = try XCTUnwrap(client.requests[0].tools?.first)
        let callback = try XCTUnwrap(tool.callback)
        do {
            let result = try await callback(MemoryLanguage.info, ["reason": .string("memory delegation")])
            XCTAssertEqual(result, "agent result")
        } catch {
            client.finishHeld()
            try await operation.waitForCompletion()
            throw error
        }
        client.finishHeld()
        try await operation.waitForCompletion()
        let provenance = service.messages.flatMap { $0.providerToolResultServices.values }
        XCTAssertEqual(provenance, [.openAI], "In-flight completion must not reread replacement model")
        XCTAssertTrue(service.messages.contains { $0.text == "card: agent result" })
        try await service.send(message: "new request")
        XCTAssertEqual(client.requests[1].model, inputs.model)
        XCTAssertEqual(service.bufferedEventCountForTesting, 0)
    }
}

private enum MemoryMessageError: Error, Codable { case unexpected, scripted }

private struct MemoryAgent: Agent {
    let name: String
    let description = "Synthetic agent"
    let instructions = "Return the memory result"
    let tools: [any LangToolsTool]? = nil
    let delegateAgents: [any Agent] = []
}

/// A pure value fake, not an OpenAI/Ollama/provider instance. Unknown operations
/// record a test failure and fail closed; no URLSession is ever constructed.
private struct MemoryLanguage: LangTools {
    typealias Model = OpenAI.Model
    typealias ErrorResponse = MemoryMessageError
    var session: URLSession { XCTFail("Unexpected session access"); fatalError("No transport") }
    static let requestValidators: [(any LangToolsRequest) -> Bool] = []
    static var info: LangToolsRequestInfo {
        LangToolsRequestInfo(langTool: MemoryLanguage(), model: OpenAI.Model.gpt4o_mini, messages: [])
    }
    func prepare(request: some LangToolsRequest) throws -> URLRequest { XCTFail("Unexpected prepare"); throw MemoryMessageError.unexpected }
    func perform<Request: LangToolsRequest>(request: Request) async throws -> Request.Response {
        guard let request = request as? OpenAI.ChatCompletionRequest else { XCTFail("Unknown agent request type"); throw MemoryMessageError.unexpected }
        guard request.model == .gpt4o_mini, request.messages.count == 2,
              case .text(let text) = request.messages.last?.content.array?.first,
              text.text == "memory delegation"
        else { XCTFail("Unknown agent request"); throw MemoryMessageError.unexpected }
        let response = OpenAI.ChatCompletionResponse(
            id: "memory", object: "chat.completion", created: 0, model: "gpt-4o-mini",
            system_fingerprint: nil,
            choices: [.init(index: 0, message: OpenAI.Message(role: .assistant, content: .string("agent result")),
                            finish_reason: .stop, delta: nil, logprobs: nil)],
            usage: nil, service_tier: nil, choose: { _ in 0 }
        )
        guard let typed = response as? Request.Response else { XCTFail("Unknown response type"); throw MemoryMessageError.unexpected }
        return typed
    }
    func stream<Request: LangToolsStreamableRequest>(request: Request) -> AsyncThrowingStream<Request.Response, Error> {
        XCTFail("Unexpected agent stream")
        return AsyncThrowingStream { $0.finish(throwing: MemoryMessageError.unexpected) }
    }
    static func decodeStream<T: Decodable>(_ buffer: String) throws -> T? { XCTFail("Unexpected decode"); throw MemoryMessageError.unexpected }
    static func chatRequest(model: any RawRepresentable, messages: [any LangToolsMessage], tools: [any LangToolsTool]?, responseSchema: JSONSchema?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) throws -> any LangToolsChatRequest {
        guard let model = model as? OpenAI.Model, model == .gpt4o_mini, tools == nil, responseSchema == nil else { XCTFail("Unknown agent operation"); throw MemoryMessageError.unexpected }
        return OpenAI.ChatCompletionRequest(model: model, messages: messages.map { OpenAI.Message($0) }, toolEventHandler: toolEventHandler)
    }
}

private final class MemoryMessageClient: NetworkClientProtocol {
    struct Request {
        let messages: [Message]
        let model: Model
        let stream: Bool
        let tools: [Tool]?
    }
    enum Reply { case text(String), tool, failure, held }
    var replies: [Reply] = []
    var requests: [Request] = []
    private var held: AsyncThrowingStream<String, Error>.Continuation?
    static var shared: NetworkClientProtocol { XCTFail("Unexpected shared client"); fatalError("No shared client") }
    func streamChatCompletionRequest(messages: [Message], model: Model, stream: Bool, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) throws -> AsyncThrowingStream<String, Error> {
        guard !replies.isEmpty, toolChoice == nil else { XCTFail("Unscripted send"); throw MemoryMessageError.unexpected }
        requests.append(Request(messages: messages, model: model, stream: stream, tools: tools))
        let reply = replies.removeFirst()
        return AsyncThrowingStream { continuation in
            switch reply {
            case .text(let text): continuation.yield(text); continuation.finish()
            case .failure: continuation.yield("failed partial"); continuation.finish(throwing: MemoryMessageError.scripted)
            case .held: held = continuation
            case .tool:
                toolEventHandler(.toolCalled(OpenAI.Message.ToolCall(index: 0, id: "call", type: .function, function: .init(name: "memory-tool", arguments: "{}"))))
                toolEventHandler(.toolCompleted(OpenAI.Message.Content.ToolResultContent(tool_selection_id: "call", result: "result")))
                continuation.yield("follow-up")
                continuation.finish()
            }
        }
    }
    func finishHeld() { guard let held else { XCTFail("No held stream"); return }; self.held = nil; held.finish() }
    func performChatCompletionRequest(messages: [Message], model: Model, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) async throws -> Message { XCTFail("Unexpected nonstream API"); throw MemoryMessageError.unexpected }
    func playAudio(for text: String) async throws { XCTFail("Unexpected audio"); throw MemoryMessageError.unexpected }
    func agentContext(messages: [Message], model: Model, eventHandler: @escaping (AgentEvent) -> Void) throws -> AgentContext { XCTFail("Unexpected agentContext"); throw MemoryMessageError.unexpected }
    func updateApiKey(_ apiKey: String, for llm: APIService) throws { XCTFail("Unexpected key write"); throw MemoryMessageError.unexpected }
    func removeApiKey(for llm: APIService) throws { XCTFail("Unexpected key removal"); throw MemoryMessageError.unexpected }
    func connectAccount(_ provider: AccountLoginProvider) async throws { XCTFail("Unexpected login"); throw MemoryMessageError.unexpected }
    func disconnectAccount(_ provider: AccountLoginProvider) async throws { XCTFail("Unexpected logout"); throw MemoryMessageError.unexpected }
    func connectCodexHelper() async throws { XCTFail("Unexpected helper login"); throw MemoryMessageError.unexpected }
    func disconnectCodexHelper() async throws { XCTFail("Unexpected helper logout"); throw MemoryMessageError.unexpected }
}
