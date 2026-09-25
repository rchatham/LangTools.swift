import Agents
import Foundation
import LangTools
import OpenAI
import XCTest
@testable import Chat

@MainActor
final class MessageServiceConversationTests: XCTestCase {
    func testSendsReuseConversationAndClearRotatesBeforeCleanup() async throws {
        let client = ConversationNetworkStub()
        let service = MessageService(networkClient: client)

        try await service.send(message: "first")
        try await service.send(message: "second")
        XCTAssertEqual(client.conversationIDs.count, 2)
        XCTAssertEqual(Set(client.conversationIDs).count, 1)
        let oldID = try XCTUnwrap(client.conversationIDs.first)

        service.clearMessages()
        try await service.send(message: "after clear")
        let newID = try XCTUnwrap(client.conversationIDs.last)
        XCTAssertNotEqual(newID, oldID)

        for _ in 0..<100 where client.endedConversationIDs.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(client.endedConversationIDs, [oldID])
    }

    func testClearCancelsAndDrainsAllOldSendsBeforeEndingConversation() async throws {
        let client = DelayedConversationNetworkStub()
        let service = MessageService(networkClient: client)
        let firstOldSend = Task { try await service.send(message: "old-1") }
        let secondOldSend = Task { try await service.send(message: "old-2") }

        for _ in 0..<100 where client.delayedResponseCount < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(client.delayedResponseCount, 2)
        let oldID = try XCTUnwrap(client.conversationIDs.first)

        service.clearMessages()
        try await service.send(message: "fresh")
        XCTAssertEqual(service.messages.count, 2)

        for oldSend in [firstOldSend, secondOldSend] {
            do {
                try await oldSend.value
                XCTFail("Expected the old conversation send to be cancelled")
            } catch is CancellationError {
                // Expected.
            }
        }
        for _ in 0..<100 where client.endedConversationIDs.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(client.endedConversationIDs, [oldID])
        XCTAssertEqual(client.terminationCountObservedAtEnd, 2)
        XCTAssertEqual(service.messages.map(\.text), ["fresh", "fresh-response"])
    }

    func testOverlappingSendsKeepToolCallbacksAttachedToTheirRequestAndDiscardLateCallbacks() async throws {
        let client = OverlappingNetworkStub()
        let service = MessageService(networkClient: client)

        let firstSend = Task { try await service.send(message: "first") }
        for _ in 0..<100 where client.requestCount < 1 {
            try await Task.sleep(for: .milliseconds(5))
        }
        let secondSend = Task { try await service.send(message: "second") }
        for _ in 0..<100 where client.requestCount < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(client.requestCount, 2)

        client.yield("first-preamble", request: 0)
        client.yield("second-preamble", request: 1)
        for _ in 0..<100 where service.messages.filter(\.isAssistant).count < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }

        client.emitToolLifecycle(request: 0, name: "first_tool", result: "first-result")
        client.emitToolLifecycle(request: 1, name: "second_tool", result: "second-result")
        client.yield("", request: 0)
        client.yield("", request: 1)
        for _ in 0..<100 where service.messages.filter({ !$0.toolCalls.isEmpty }).count < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        client.finish(request: 1)
        client.finish(request: 0)
        try await firstSend.value
        try await secondSend.value

        let cardMessages = service.messages.filter { !$0.toolCalls.isEmpty }
        XCTAssertEqual(cardMessages.count, 2)
        XCTAssertEqual(cardMessages.flatMap(\.toolCalls).map(\.name).sorted(), ["first_tool", "second_tool"])
        for message in cardMessages {
            XCTAssertEqual(message.toolCalls.count, 1)
            let call = message.toolCalls[0]
            let isFirstRequest = call.name == "first_tool"
            XCTAssertEqual(call.result, isFirstRequest ? "first-result" : "second-result")
            XCTAssertEqual(message.text, isFirstRequest ? "first-preamble" : "second-preamble")
        }

        XCTAssertEqual(service.bufferedEventCountForTesting, 0)
        client.emitToolLifecycle(request: 0, name: "late_tool", result: "late-result")
        XCTAssertEqual(
            service.bufferedEventCountForTesting,
            0,
            "A completed send must reject callbacks instead of retaining them in its event buffer"
        )
    }

    func testClearingToolHistoryNotifiesPersistenceForAnchorMessage() async throws {
        let previousKeepsToolCallsInHistory = ToolSettings.shared.keepsToolCallsInHistory
        ToolSettings.shared.keepsToolCallsInHistory = false
        defer { ToolSettings.shared.keepsToolCallsInHistory = previousKeepsToolCallsInHistory }

        let client = OverlappingNetworkStub()
        let service = MessageService(networkClient: client)
        var persistedToolCallNames: [UUID: [String]] = [:]
        var persistedProviderResults: [UUID: [String: String]] = [:]
        service.messageUpdatedCallback = { message in
            persistedToolCallNames[message.uuid] = message.toolCalls.map(\.name)
            persistedProviderResults[message.uuid] = message.providerToolResults
        }

        let send = Task { try await service.send(message: "history") }
        for _ in 0..<100 where client.requestCount < 1 {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(client.requestCount, 1)

        client.yield("preamble", request: 0)
        for _ in 0..<100 where service.messages.first(where: \.isAssistant) == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        let anchor = try XCTUnwrap(service.messages.first(where: \.isAssistant))
        anchor.providerToolResults = ["history_tool-id": "raw-result"]

        client.emitToolLifecycle(request: 0, name: "history_tool", result: "visible-result")
        client.yield("", request: 0)
        for _ in 0..<100 where anchor.toolCalls.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(anchor.toolCalls.map(\.name), ["history_tool"], "Sanitizing persistence must not hide the live card")
        XCTAssertEqual(persistedToolCallNames[anchor.uuid], [])
        XCTAssertEqual(anchor.providerToolResults, [:])
        XCTAssertEqual(persistedProviderResults[anchor.uuid], [:])

        client.yield("follow-up", request: 0)
        client.finish(request: 0)
        try await send.value

        XCTAssertEqual(anchor.toolCalls, [])
        XCTAssertEqual(anchor.providerToolResults, [:])
        XCTAssertEqual(persistedToolCallNames[anchor.uuid], [])
        XCTAssertEqual(persistedProviderResults[anchor.uuid], [:])
    }

    func testHistoryDisabledClearsToolCardsWhenStreamFinishesWithoutFollowUp() async throws {
        let previousKeepsToolCallsInHistory = ToolSettings.shared.keepsToolCallsInHistory
        ToolSettings.shared.keepsToolCallsInHistory = false
        defer { ToolSettings.shared.keepsToolCallsInHistory = previousKeepsToolCallsInHistory }

        let client = OverlappingNetworkStub()
        let service = MessageService(networkClient: client)
        let send = Task { try await service.send(message: "no follow-up") }
        for _ in 0..<100 where client.requestCount < 1 {
            try await Task.sleep(for: .milliseconds(5))
        }

        client.yield("preamble", request: 0)
        for _ in 0..<100 where service.messages.first(where: \.isAssistant) == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        let anchor = try XCTUnwrap(service.messages.first(where: \.isAssistant))
        client.emitToolLifecycle(request: 0, name: "private_tool", result: "private-result")
        client.finish(request: 0)
        try await send.value

        XCTAssertEqual(anchor.text, "preamble")
        XCTAssertTrue(anchor.toolCalls.isEmpty)
        XCTAssertTrue(anchor.providerToolResults.isEmpty)
    }

    func testHistoryDisabledKeepsCardsLiveForEmptyChunkThenClearsAtTerminalSend() async throws {
        let previousKeepsToolCallsInHistory = ToolSettings.shared.keepsToolCallsInHistory
        ToolSettings.shared.keepsToolCallsInHistory = false
        defer { ToolSettings.shared.keepsToolCallsInHistory = previousKeepsToolCallsInHistory }

        let client = OverlappingNetworkStub()
        let service = MessageService(networkClient: client)
        let send = Task { try await service.send(message: "empty follow-up") }
        for _ in 0..<100 where client.requestCount < 1 {
            try await Task.sleep(for: .milliseconds(5))
        }

        client.emitToolLifecycle(request: 0, name: "private_tool", result: "private-result")
        client.yield("", request: 0)
        for _ in 0..<100 where service.messages.first(where: { !$0.toolCalls.isEmpty }) == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        let anchor = try XCTUnwrap(service.messages.first(where: { !$0.toolCalls.isEmpty }))
        XCTAssertEqual(anchor.toolCalls.map(\.name), ["private_tool"])
        XCTAssertTrue(anchor.providerToolResults.isEmpty)

        client.finish(request: 0)
        try await send.value

        XCTAssertTrue(anchor.toolCalls.isEmpty)
        XCTAssertTrue(anchor.providerToolResults.isEmpty)
        XCTAssertEqual(service.messages.map(\.role), [.user])
        XCTAssertEqual(service.messages.map(\.text), ["empty follow-up"])
    }

    func testHistoryDisabledClearsLiveCardsWhenStreamThrows() async throws {
        let previousKeepsToolCallsInHistory = ToolSettings.shared.keepsToolCallsInHistory
        ToolSettings.shared.keepsToolCallsInHistory = false
        defer { ToolSettings.shared.keepsToolCallsInHistory = previousKeepsToolCallsInHistory }

        let client = OverlappingNetworkStub()
        let service = MessageService(networkClient: client)
        let send = Task { try await service.send(message: "error") }
        for _ in 0..<100 where client.requestCount < 1 {
            try await Task.sleep(for: .milliseconds(5))
        }

        client.emitToolLifecycle(request: 0, name: "private_tool", result: "private-result")
        client.yield("", request: 0)
        for _ in 0..<100 where service.messages.first(where: { !$0.toolCalls.isEmpty }) == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        let anchor = try XCTUnwrap(service.messages.first(where: { !$0.toolCalls.isEmpty }))
        XCTAssertEqual(anchor.toolCalls.map(\.name), ["private_tool"])

        client.fail(request: 0)
        do {
            try await send.value
            XCTFail("Expected stream failure")
        } catch OverlappingStubError.failed {
            // Expected.
        }

        XCTAssertTrue(anchor.toolCalls.isEmpty)
        XCTAssertTrue(anchor.providerToolResults.isEmpty)
    }

    func testHistoryDisabledOverlappingSendSnapshotExcludesLiveToolCards() async throws {
        let previousKeepsToolCallsInHistory = ToolSettings.shared.keepsToolCallsInHistory
        ToolSettings.shared.keepsToolCallsInHistory = false
        defer { ToolSettings.shared.keepsToolCallsInHistory = previousKeepsToolCallsInHistory }

        let client = OverlappingNetworkStub()
        let service = MessageService(networkClient: client)
        let firstSend = Task { try await service.send(message: "first") }
        for _ in 0..<100 where client.requestCount < 1 {
            try await Task.sleep(for: .milliseconds(5))
        }

        client.emitToolLifecycle(request: 0, name: "private_tool", result: "private-result")
        client.yield("", request: 0)
        for _ in 0..<100 where service.messages.first(where: { !$0.toolCalls.isEmpty }) == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        let liveAnchor = try XCTUnwrap(service.messages.first(where: { !$0.toolCalls.isEmpty }))
        service.messages.append(
            .contentCards(
                ContentCardsContent(
                    cardType: "test-cards",
                    message: "cards summary",
                    cardsJSON: "[]",
                    cardCount: 0
                )
            )
        )

        let secondSend = Task { try await service.send(message: "second") }
        for _ in 0..<100 where client.requestCount < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(liveAnchor.toolCalls.map(\.name), ["private_tool"], "Taking a request snapshot must not hide the live card")
        XCTAssertTrue(client.toolCallNamesSent(request: 1).isEmpty)
        XCTAssertTrue(client.providerToolResultsSent(request: 1).isEmpty)
        XCTAssertEqual(client.messageRolesSent(request: 1), [.system, .user, .assistant, .user])
        XCTAssertEqual(
            Array(client.messageTextsSent(request: 1).suffix(3)),
            ["first", "cards summary", "second"],
            "The empty tool anchor must be omitted while content-card messages remain in the request"
        )
        guard case .contentCards = client.messageContentTypesSent(request: 1)[2] else {
            return XCTFail("Expected the content-card message to retain its semantic content type")
        }

        client.finish(request: 1)
        client.finish(request: 0)
        try await secondSend.value
        try await firstSend.value
        XCTAssertTrue(liveAnchor.toolCalls.isEmpty)
    }

    func testLegacyNetworkClientUsesCompatibilityPath() async throws {
        let client = LegacyNetworkStub()
        let service = MessageService(networkClient: client)

        try await service.send(message: "legacy")

        XCTAssertEqual(client.streamRequestCount, 1)
    }
}

private final class OverlappingNetworkStub: NetworkClientProtocol, @unchecked Sendable {
    static let shared: NetworkClientProtocol = OverlappingNetworkStub()

    private struct Request {
        let eventHandler: (LangToolsToolEvent) -> Void
        let continuation: AsyncThrowingStream<String, Error>.Continuation
        let toolCallNames: [String]
        let providerToolResults: [String: String]
        let messageRoles: [Role]
        let messageTexts: [String?]
        let messageContentTypes: [ContentType]
    }

    private let lock = NSLock()
    private var requests: [Request] = []

    var requestCount: Int {
        lock.withLock { requests.count }
    }

    func emitToolLifecycle(request index: Int, name: String, result: String) {
        let handler = lock.withLock { requests[index].eventHandler }
        let id = "\(name)-id"
        handler(.toolCalled(OverlapSelection(id: id, name: name, arguments: "{}")))
        handler(.toolCompleted(OverlapResult(tool_selection_id: id, result: result)))
    }

    func yield(_ chunk: String, request index: Int) {
        let continuation = lock.withLock { requests[index].continuation }
        continuation.yield(chunk)
    }

    func finish(request index: Int) {
        let continuation = lock.withLock { requests[index].continuation }
        continuation.finish()
    }

    func fail(request index: Int) {
        let continuation = lock.withLock { requests[index].continuation }
        continuation.finish(throwing: OverlappingStubError.failed)
    }

    func toolCallNamesSent(request index: Int) -> [String] {
        lock.withLock { requests[index].toolCallNames }
    }

    func providerToolResultsSent(request index: Int) -> [String: String] {
        lock.withLock { requests[index].providerToolResults }
    }

    func messageRolesSent(request index: Int) -> [Role] {
        lock.withLock { requests[index].messageRoles }
    }

    func messageTextsSent(request index: Int) -> [String?] {
        lock.withLock { requests[index].messageTexts }
    }

    func messageContentTypesSent(request index: Int) -> [ContentType] {
        lock.withLock { requests[index].messageContentTypes }
    }

    func performChatCompletionRequest(messages: [Message], model: Model, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) async throws -> Message {
        throw NetworkClient.NetworkError.incompatibleRequest
    }

    func streamChatCompletionRequest(messages: [Message], model: Model, stream: Bool, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) throws -> AsyncThrowingStream<String, Error> {
        let toolCallNames = messages.flatMap { $0.toolCalls.map(\.name) }
        let providerToolResults = messages.reduce(into: [String: String]()) { results, message in
            results.merge(message.providerToolResults) { _, latest in latest }
        }
        return AsyncThrowingStream { continuation in
            lock.withLock {
                requests.append(
                    Request(
                        eventHandler: toolEventHandler,
                        continuation: continuation,
                        toolCallNames: toolCallNames,
                        providerToolResults: providerToolResults,
                        messageRoles: messages.map(\.role),
                        messageTexts: messages.map(\.text),
                        messageContentTypes: messages.map(\.contentType)
                    )
                )
            }
        }
    }

    func playAudio(for text: String) async throws {}
    func agentContext(messages: [Message], model: Model, eventHandler: @escaping (AgentEvent) -> Void) throws -> AgentContext { throw NetworkClient.NetworkError.incompatibleRequest }
    func updateApiKey(_ apiKey: String, for llm: APIService) throws {}
    func removeApiKey(for llm: APIService) throws {}
    func connectAccount(_ provider: AccountLoginProvider) async throws {}
    func disconnectAccount(_ provider: AccountLoginProvider) async throws {}
}

private enum OverlappingStubError: Error {
    case failed
}

private struct OverlapSelection: LangToolsToolSelection {
    let id: String?
    let name: String?
    let arguments: String
}

private struct OverlapResult: LangToolsToolSelectionResult {
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

private final class ConversationNetworkStub: ConversationAwareNetworkClientProtocol {
    static let shared: NetworkClientProtocol = ConversationNetworkStub()
    private(set) var conversationIDs: [UUID] = []
    private(set) var endedConversationIDs: [UUID] = []

    func performChatCompletionRequest(messages: [Message], model: Model, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) async throws -> Message {
        Message(text: "legacy", role: .assistant)
    }

    func streamChatCompletionRequest(messages: [Message], model: Model, stream: Bool, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield("legacy")
            continuation.finish()
        }
    }

    func performChatCompletionRequest(messages: [Message], model: Model, conversationID: UUID, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) async throws -> Message {
        conversationIDs.append(conversationID)
        return Message(text: "response", role: .assistant)
    }

    func streamChatCompletionRequest(messages: [Message], model: Model, conversationID: UUID, stream: Bool, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) throws -> AsyncThrowingStream<String, Error> {
        conversationIDs.append(conversationID)
        return AsyncThrowingStream { continuation in
            continuation.yield("response")
            continuation.finish()
        }
    }

    func endConversation(id: UUID) async { endedConversationIDs.append(id) }
    func playAudio(for text: String) async throws {}
    func agentContext(messages: [Message], model: Model, eventHandler: @escaping (AgentEvent) -> Void) throws -> AgentContext { throw NetworkClient.NetworkError.incompatibleRequest }
    func updateApiKey(_ apiKey: String, for llm: APIService) throws {}
    func removeApiKey(for llm: APIService) throws {}
    func connectAccount(_ provider: AccountLoginProvider) async throws {}
    func disconnectAccount(_ provider: AccountLoginProvider) async throws {}
}

private final class DelayedConversationNetworkStub: ConversationAwareNetworkClientProtocol, @unchecked Sendable {
    static let shared: NetworkClientProtocol = DelayedConversationNetworkStub()
    private let lock = NSLock()
    private var delayedContinuations: [AsyncThrowingStream<String, Error>.Continuation] = []
    private var streamCount = 0
    private var terminatedStreamCount = 0
    private(set) var conversationIDs: [UUID] = []
    private(set) var endedConversationIDs: [UUID] = []
    private(set) var terminationCountObservedAtEnd = 0
    var delayedResponseCount: Int { delayedContinuations.count }

    func streamChatCompletionRequest(messages: [Message], model: Model, conversationID: UUID, stream: Bool, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) throws -> AsyncThrowingStream<String, Error> {
        conversationIDs.append(conversationID)
        streamCount += 1
        if streamCount <= 2 {
            return AsyncThrowingStream { continuation in
                continuation.onTermination = { [weak self] _ in
                    self?.recordTermination()
                }
                delayedContinuations.append(continuation)
            }
        }
        return AsyncThrowingStream { continuation in
            continuation.yield("fresh-response")
            continuation.finish()
        }
    }

    private func recordTermination() {
        lock.withLock { terminatedStreamCount += 1 }
    }

    private func terminationCount() -> Int {
        lock.withLock { terminatedStreamCount }
    }

    func performChatCompletionRequest(messages: [Message], model: Model, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) async throws -> Message { Message(text: "legacy", role: .assistant) }
    func streamChatCompletionRequest(messages: [Message], model: Model, stream: Bool, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) throws -> AsyncThrowingStream<String, Error> { throw NetworkClient.NetworkError.incompatibleRequest }
    func performChatCompletionRequest(messages: [Message], model: Model, conversationID: UUID, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) async throws -> Message { Message(text: "response", role: .assistant) }
    func endConversation(id: UUID) async {
        terminationCountObservedAtEnd = terminationCount()
        endedConversationIDs.append(id)
    }
    func playAudio(for text: String) async throws {}
    func agentContext(messages: [Message], model: Model, eventHandler: @escaping (AgentEvent) -> Void) throws -> AgentContext { throw NetworkClient.NetworkError.incompatibleRequest }
    func updateApiKey(_ apiKey: String, for llm: APIService) throws {}
    func removeApiKey(for llm: APIService) throws {}
    func connectAccount(_ provider: AccountLoginProvider) async throws {}
    func disconnectAccount(_ provider: AccountLoginProvider) async throws {}
}

private final class LegacyNetworkStub: NetworkClientProtocol {
    static let shared: NetworkClientProtocol = LegacyNetworkStub()
    private(set) var streamRequestCount = 0

    func performChatCompletionRequest(messages: [Message], model: Model, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) async throws -> Message {
        Message(text: "legacy", role: .assistant)
    }

    func streamChatCompletionRequest(messages: [Message], model: Model, stream: Bool, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) throws -> AsyncThrowingStream<String, Error> {
        streamRequestCount += 1
        return AsyncThrowingStream { continuation in
            continuation.yield("legacy")
            continuation.finish()
        }
    }

    func playAudio(for text: String) async throws {}
    func agentContext(messages: [Message], model: Model, eventHandler: @escaping (AgentEvent) -> Void) throws -> AgentContext { throw NetworkClient.NetworkError.incompatibleRequest }
    func updateApiKey(_ apiKey: String, for llm: APIService) throws {}
    func removeApiKey(for llm: APIService) throws {}
    func connectAccount(_ provider: AccountLoginProvider) async throws {}
    func disconnectAccount(_ provider: AccountLoginProvider) async throws {}
}
