import Agents
import ChatUI
import Foundation
import LangTools
import OpenAI
import ToolKit
import XCTest
@testable import Chat

/// Covers `MessageService.requestPreparer`, the seam used by context
/// compaction and memory injection to rewrite a request before it is sent.
@MainActor
final class MessageServiceRequestPreparerTests: XCTestCase {
    private func makeService(_ client: PreparerTestClient) -> MessageService {
        MessageService(
            networkClient: client,
            agents: nil,
            tools: nil,
            dependencies: .init(
                selectedModel: { .openAI(.gpt4o_mini) },
                conversationSettings: { ChatConversationSettings(systemPrompt: "base prompt") },
                keepsToolCallsInHistory: { true },
                maxToolIterations: { nil },
                enabledTools: { nil },
                toolConfigurations: { [] }
            )
        )
    }

    func testNilPreparerSendsTheUnmodifiedSnapshot() async throws {
        let client = PreparerTestClient(replies: ["answer"])
        let service = makeService(client)
        service.messages = [Message(text: "earlier", role: .user), Message(text: "reply", role: .assistant)]

        try await service.send(message: "now", stream: true)

        let request = try XCTUnwrap(client.requests.first)
        XCTAssertEqual(request.dropFirst().map(\.text), ["earlier", "reply", "now"])
        XCTAssertTrue(request.first?.text?.hasPrefix("base prompt") == true)
    }

    func testPreparerReplacesHistoryAndSystemPromptButNotTheTranscript() async throws {
        let client = PreparerTestClient(replies: ["answer"])
        let service = makeService(client)
        service.messages = [Message(text: "old one", role: .user), Message(text: "old two", role: .assistant)]
        var seen: ChatRequestContext?
        service.requestPreparer = { context in
            seen = context
            var prepared = context
            prepared.systemPrompt = "summary prompt\n\n" + context.systemPrompt
            prepared.history = [Message(text: "[summary of earlier turns]", role: .system)] + context.history.suffix(1)
            return prepared
        }

        try await service.send(message: "latest", stream: true)

        let context = try XCTUnwrap(seen)
        XCTAssertEqual(context.model, .openAI(.gpt4o_mini))
        XCTAssertEqual(context.history.map(\.text), ["old one", "old two", "latest"])
        let request = try XCTUnwrap(client.requests.first)
        XCTAssertTrue(request.first?.text?.hasPrefix("summary prompt\n\nbase prompt") == true)
        XCTAssertEqual(request.dropFirst().map(\.text), ["[summary of earlier turns]", "latest"])
        XCTAssertEqual(
            service.messages.map(\.text),
            ["old one", "old two", "latest", "answer"],
            "The preparer only shapes the request; the visible transcript is unchanged"
        )
    }

    func testThrowingPreparerFailsTheSendWithoutANetworkRequest() async throws {
        let client = PreparerTestClient(replies: [])
        let service = makeService(client)
        service.requestPreparer = { _ in throw PreparerTestError.rejected }

        do {
            try await service.send(message: "blocked", stream: true)
            XCTFail("Expected the preparer error")
        } catch {
            XCTAssertEqual(error as? PreparerTestError, .rejected)
        }
        XCTAssertTrue(client.requests.isEmpty)
        let prompt = try XCTUnwrap(service.messages.first { $0.isUser })
        XCTAssertNotNil(prompt.sendFailure, "A preparer failure is reported like a provider failure")
    }
}

private enum PreparerTestError: Error, Equatable { case rejected, unexpected }

private final class PreparerTestClient: NetworkClientProtocol {
    var replies: [String]
    var requests: [[Message]] = []

    init(replies: [String]) { self.replies = replies }

    static var shared: NetworkClientProtocol { fatalError("No shared client") }

    func streamChatCompletionRequest(messages: [Message], model: Model, stream: Bool, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) throws -> AsyncThrowingStream<String, Error> {
        guard !replies.isEmpty else { XCTFail("Unscripted send"); throw PreparerTestError.unexpected }
        requests.append(messages)
        let reply = replies.removeFirst()
        return AsyncThrowingStream { continuation in
            continuation.yield(reply)
            continuation.finish()
        }
    }

    func performChatCompletionRequest(messages: [Message], model: Model, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) async throws -> Message { throw PreparerTestError.unexpected }
    func playAudio(for text: String) async throws { throw PreparerTestError.unexpected }
    func agentContext(messages: [Message], model: Model, eventHandler: @escaping (AgentEvent) -> Void) throws -> AgentContext { throw PreparerTestError.unexpected }
    func updateApiKey(_ apiKey: String, for llm: APIService) throws { throw PreparerTestError.unexpected }
    func removeApiKey(for llm: APIService) throws { throw PreparerTestError.unexpected }
    func connectAccount(_ provider: AccountLoginProvider) async throws { throw PreparerTestError.unexpected }
    func disconnectAccount(_ provider: AccountLoginProvider) async throws { throw PreparerTestError.unexpected }
}
