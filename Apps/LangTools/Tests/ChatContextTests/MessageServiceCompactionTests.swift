import ChatUI
import Foundation
import OpenAI
import XCTest
@testable import Chat
@testable import ChatContext

/// The preparer plugged into a real `MessageService`.
@MainActor
final class MessageServiceCompactionTests: XCTestCase {
    private func makeService(_ client: ContextScriptedClient, settings: ChatConversationSettings = ChatConversationSettings(systemPrompt: "base")) -> MessageService {
        MessageService(
            networkClient: client,
            agents: nil,
            tools: nil,
            dependencies: .init(
                selectedModel: { unknownWindowModel },
                conversationSettings: { settings },
                keepsToolCallsInHistory: { true },
                maxToolIterations: { nil },
                enabledTools: { nil },
                toolConfigurations: { [] }
            )
        )
    }

    func testRequestsCarryTheSummaryWhileTheTranscriptStaysWhole() async throws {
        let client = ContextScriptedClient([.success("- Earlier the user asked fifteen questions."), .success("final answer")])
        let service = makeService(client)
        let store = InMemoryContextCheckpointStore()
        let conversationID = UUID()
        service.messages = Array(conversation(turns: 15).dropLast())
        let transcript = service.messages.map(\.uuid)
        // The summary is written through the same client.
        let preparer = CompactingRequestPreparer(
            conversationID: conversationID,
            checkpoints: store,
            policy: { testPolicy() },
            summarizer: LLMConversationSummarizer(networkClient: client)
        )
        service.requestPreparer = preparer.requestPreparer

        try await service.send(message: "current question", stream: true)

        XCTAssertEqual(client.requests.count, 2, "One summary request, then the chat request")
        let chat = try XCTUnwrap(client.requests.last?.messages)
        let system = try XCTUnwrap(chat.first?.text)
        XCTAssertTrue(system.hasPrefix("base"))
        XCTAssertTrue(system.contains(CompactedContext.heading))
        XCTAssertTrue(system.contains("- Earlier the user asked fifteen questions."))
        XCTAssertTrue(chat[1].isUser, "History resumes at a turn boundary")
        XCTAssertEqual(chat.last?.text, "current question")
        XCTAssertLessThan(chat.count, transcript.count)

        let checkpoint = try XCTUnwrap(try store.latestCheckpoint(conversationID: conversationID))
        XCTAssertEqual(checkpoint.model, unknownWindowModel.rawValue)
        XCTAssertEqual(service.messages.count, transcript.count + 2)
        XCTAssertEqual(Array(service.messages.map(\.uuid).prefix(transcript.count)), transcript, "The visible transcript is unchanged")
    }

    func testInterleavedSendsReportTheOtherPromptAsInFlight() async throws {
        let client = ContextScriptedClient([.success("a"), .success("b")])
        let service = makeService(client)
        var contexts: [ChatRequestContext] = []
        var releaseFirst: CheckedContinuation<Void, Never>?
        service.requestPreparer = { context in
            contexts.append(context)
            if contexts.count == 1 { await withCheckedContinuation { releaseFirst = $0 } }
            return context
        }

        let first = service.sendOperation(message: "first", stream: true)
        for _ in 0..<200 where releaseFirst == nil { try await Task.sleep(nanoseconds: 2_000_000) }
        let second = service.sendOperation(message: "second", stream: true)
        for _ in 0..<200 where contexts.count < 2 { try await Task.sleep(nanoseconds: 2_000_000) }
        releaseFirst?.resume()
        try await first.waitForCompletion()
        try await second.waitForCompletion()

        XCTAssertEqual(contexts.count, 2)
        XCTAssertEqual(contexts[0].inFlightMessageIDs, [])
        XCTAssertEqual(contexts[1].inFlightMessageIDs, [try XCTUnwrap(first.messageID)])
        XCTAssertEqual(contexts[1].settings.systemPrompt, "base", "The request's settings reach the preparer")
    }
}
