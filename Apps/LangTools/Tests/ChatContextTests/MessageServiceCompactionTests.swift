import ChatUI
import Foundation
import LangTools
import OpenAI
import XCTest
@testable import Chat
@testable import ChatContext

/// The preparer plugged into a real `MessageService`.
@MainActor
final class MessageServiceCompactionTests: XCTestCase {
    private func makeService(
        _ client: ContextScriptedClient,
        settings: ChatConversationSettings = ChatConversationSettings(systemPrompt: "base"),
        tools: [Tool]? = nil
    ) -> MessageService {
        MessageService(
            networkClient: client,
            agents: nil,
            tools: tools,
            dependencies: .init(
                selectedModel: { unknownWindowModel },
                conversationSettings: { settings },
                keepsToolCallsInHistory: { true },
                maxToolIterations: { nil },
                enabledTools: { tools?.map { OpenAI.Tool($0) } },
                toolConfigurations: { [] }
            )
        )
    }

    private func compactingPreparer(_ client: ContextScriptedClient) -> CompactingRequestPreparer {
        CompactingRequestPreparer(
            conversationID: UUID(),
            checkpoints: InMemoryContextCheckpointStore(),
            policy: { testPolicy() },
            summarizer: LLMConversationSummarizer(networkClient: client)
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

    func testTheOfferedToolsReachThePreparer() async throws {
        let client = ContextScriptedClient([.success("done")])
        let service = makeService(client, tools: [contextTestTool()])
        var contexts: [ChatRequestContext] = []
        service.requestPreparer = { context in
            contexts.append(context)
            return context
        }

        try await service.send(message: "question", stream: true)

        XCTAssertEqual(contexts.first?.tools.map(\.name), ["lookup"])
        XCTAssertEqual(client.requests.first?.tools?.map(\.name), ["lookup"])
    }

    // MARK: Provider overflow

    func testAnOverflowIsRetriedOnceWithAForcedCompaction() async throws {
        // Fourteen turns stay under the trigger by the estimate, but the
        // provider counts more than its window allows.
        let client = ContextScriptedClient([
            .failure(promptTooLong(7_000, 4_000)),
            .success("- The user asked fourteen questions."),
            .success("final answer"),
        ])
        let service = makeService(client)
        service.messages = Array(conversation(turns: 14).dropLast())
        let preparer = compactingPreparer(client)
        var overflows: [ContextOverflow?] = []
        service.requestPreparer = { context in
            overflows.append(context.contextOverflow)
            return try await preparer.prepare(context)
        }

        try await service.send(message: "current question", stream: true)

        XCTAssertEqual(overflows, [nil, ContextOverflow(requestedTokens: 7_000, maximumTokens: 4_000)])
        XCTAssertEqual(client.requests.count, 3, "The rejected request, the summary, then the compacted retry")
        let retry = try XCTUnwrap(client.requests.last?.messages)
        XCTAssertLessThan(retry.count, client.requests[0].messages.count)
        XCTAssertTrue(retry.first?.text?.contains("- The user asked fourteen questions.") == true)
        XCTAssertEqual(retry.last?.text, "current question")
        XCTAssertEqual(service.messages.last?.text, "final answer")
        XCTAssertNil(service.messages.first { $0.text == "current question" }?.sendFailure)
    }

    func testAnOverflowThePreparerCannotShrinkFailsWithTheProviderError() async throws {
        let client = ContextScriptedClient([.failure(promptTooLong(7_000, 4_000))])
        let service = makeService(client)
        var calls = 0
        service.requestPreparer = { context in
            calls += 1
            return context
        }

        do {
            try await service.send(message: "question", stream: true)
            XCTFail("Expected the provider's error")
        } catch {
            XCTAssertNotNil(ContextOverflow(error: error))
        }
        XCTAssertEqual(calls, 2, "The preparer is asked once more")
        XCTAssertEqual(client.requests.count, 1, "An unchanged request is not sent again")
        XCTAssertNotNil(service.messages.last?.sendFailure)
    }

    func testOnlyOneRetryIsMade() async throws {
        let client = ContextScriptedClient([.failure(promptTooLong(7_000, 4_000)), .failure(promptTooLong(5_000, 4_000))])
        let service = makeService(client)
        service.messages = turn(0)
        var calls = 0
        service.requestPreparer = { context in
            calls += 1
            var shorter = context
            if context.contextOverflow != nil { shorter.history.removeFirst(2) }
            return shorter
        }

        do {
            try await service.send(message: "question", stream: true)
            XCTFail("Expected the second overflow")
        } catch {
            XCTAssertEqual(ContextOverflow(error: error)?.requestedTokens, 5_000)
        }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(client.requests.count, 2)
    }

    func testOtherErrorsAreNotRetried() async throws {
        let client = ContextScriptedClient([.failure(ContextTestError.unexpected)])
        let service = makeService(client)
        var calls = 0
        service.requestPreparer = { context in
            calls += 1
            return context
        }

        do {
            try await service.send(message: "question", stream: true)
            XCTFail("Expected the provider's error")
        } catch {
            XCTAssertEqual(error as? ContextTestError, .unexpected)
        }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(client.requests.count, 1)
    }

    func testAnOverflowAfterTheReplyStartedIsNotRetried() async throws {
        let client = ContextScriptedClient([.success("partial answer")])
        client.failAfterNextReply = promptTooLong(7_000, 4_000)
        let service = makeService(client)
        var calls = 0
        service.requestPreparer = { context in
            calls += 1
            var shorter = context
            shorter.history = Array(context.history.suffix(1))
            return shorter
        }

        do {
            try await service.send(message: "question", stream: true)
            XCTFail("Expected the provider's error")
        } catch {
            XCTAssertNotNil(ContextOverflow(error: error))
        }
        XCTAssertEqual(calls, 1, "Text was already shown, so the turn is not sent again")
        XCTAssertEqual(client.requests.count, 1)
    }

    func testAnOverflowAfterAToolRanIsNotRetried() async throws {
        let client = ContextScriptedClient([.failure(promptTooLong(7_000, 4_000))])
        client.toolEventBeforeNextReply = .toolCompleted(nil)
        let service = makeService(client)
        service.messages = turn(0)
        var calls = 0
        service.requestPreparer = { context in
            calls += 1
            var shorter = context
            shorter.history = Array(context.history.suffix(1))
            return shorter
        }

        do {
            try await service.send(message: "question", stream: true)
            XCTFail("Expected the provider's error")
        } catch {
            XCTAssertNotNil(ContextOverflow(error: error))
        }
        XCTAssertEqual(calls, 1, "A tool already ran in this turn, so it is not sent again")
        XCTAssertEqual(client.requests.count, 1)
    }
}
