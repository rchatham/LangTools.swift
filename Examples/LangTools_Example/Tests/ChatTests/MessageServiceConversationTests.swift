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

    func testLegacyNetworkClientUsesCompatibilityPath() async throws {
        let client = LegacyNetworkStub()
        let service = MessageService(networkClient: client)

        try await service.send(message: "legacy")

        XCTAssertEqual(client.streamRequestCount, 1)
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
