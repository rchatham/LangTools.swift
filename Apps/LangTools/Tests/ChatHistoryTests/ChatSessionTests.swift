import Foundation
import XCTest
@testable import Chat
@testable import ChatHistory

@MainActor
final class ChatSessionTests: XCTestCase {
    private var storage: InMemoryChatHistoryStorage!
    private var client: ScriptedChatClient!
    private var saves = 0
    private var failingSaves = 0

    override func setUp() async throws {
        storage = InMemoryChatHistoryStorage()
        client = ScriptedChatClient()
        saves = 0
        failingSaves = 0
        storage.saveHook = { [unowned self] in
            if self.failingSaves > 0 {
                self.failingSaves -= 1
                throw ScriptedError.saveFailed
            }
            self.saves += 1
        }
    }

    private func manager(timing: ChatPersistenceTiming = .manual, removesFailedPrompt: Bool = true) -> ChatSessionManager {
        ChatSessionManager(storage: storage, hooks: TestHooks.make(client: client, removesFailedPrompt: removesFailedPrompt), timing: timing)
    }

    private func storedSession(_ manager: ChatSessionManager, messages: [Message] = []) throws -> ChatSession {
        let record = try storage.importConversation(ConversationDraft(title: "Stored"), messages: messages)
        saves = 0
        return try manager.session(for: record.id)
    }

    private func stored(_ id: UUID) throws -> [Message] {
        try storage.loadMessages(conversationID: id)
    }

    // MARK: Sending

    func testSendSavesPromptAndReplyWhenItFinishes() async throws {
        let session = try storedSession(manager())
        client.replies = [.text("Hello there")]

        try await session.send(message: "Hi", stream: true)

        XCTAssertEqual(try stored(session.conversationID).map(\.text), ["Hi", "Hello there"])
        XCTAssertEqual(saves, 1, "One terminal save, no debounced saves")
        XCTAssertFalse(session.hasPendingPersistence)
    }

    func testOpeningAConversationWritesNothing() async throws {
        let session = try storedSession(manager(timing: .fast), messages: [text("old", .user, at: 1)])
        XCTAssertEqual(session.chatMessages.map(\.text), ["old"])

        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(saves, 0, "Loading must not re-save and reorder the conversation")
    }

    func testStreamingUpdatesAreBatchedUntilTheDebounceOrTheEnd() async throws {
        let session = try storedSession(manager())
        client.replies = [.held]
        let operation = session.sendOperation(message: "Stream", stream: true)
        try await operation.waitUntilEstablished()

        client.yieldHeld("part one")
        await assertEventually { session.chatMessages.count == 2 }
        client.yieldHeld(" and two")
        await assertEventually { session.chatMessages.last?.text == "part one and two" }
        XCTAssertEqual(saves, 0)
        XCTAssertGreaterThan(session.pendingUpsertCountForTesting, 0)

        client.finishHeld()
        try await operation.waitForCompletion()
        XCTAssertEqual(saves, 1)
        XCTAssertEqual(try stored(session.conversationID).last?.text, "part one and two")
    }

    func testLongStreamsAreSavedWithinTheMaximumLatency() async throws {
        let session = try storedSession(manager(timing: ChatPersistenceTiming(debounce: 3600, maximumLatency: 0.05)))
        client.replies = [.held]
        let operation = session.sendOperation(message: "Long", stream: true)
        try await operation.waitUntilEstablished()
        client.yieldHeld("partial")

        await assertEventually { (try? self.stored(session.conversationID).last?.text) == "partial" }
        client.finishHeld()
        try await operation.waitForCompletion()
    }

    func testFailedFinalSaveIsRetriedWithoutAnotherRequest() async throws {
        let session = try storedSession(manager(timing: ChatPersistenceTiming(debounce: 3600, maximumLatency: 3600, initialRetryDelay: 0.01)))
        client.replies = [.text("Answer")]
        failingSaves = 2

        do {
            try await session.send(message: "Question", stream: true)
            XCTFail("A save failure after a successful request is reported")
        } catch {
            XCTAssertTrue(error is ChatSessionError)
        }

        await assertEventually { (try? self.stored(session.conversationID).count) == 2 }
        XCTAssertEqual(client.requests.count, 1)
        XCTAssertFalse(session.hasPendingPersistence)
    }

    func testFailureWithoutOutputRemovesThePrompt() async throws {
        let session = try storedSession(manager())
        client.replies = [.failure(partial: nil)]

        await XCTAssertThrowsErrorAsync(try await session.send(message: "Doomed", stream: true))

        XCTAssertTrue(session.chatMessages.isEmpty, "ChatUI restores the prompt to the composer")
        XCTAssertTrue(try stored(session.conversationID).isEmpty)
    }

    func testFailureWithPartialOutputKeepsEverything() async throws {
        let session = try storedSession(manager())
        client.replies = [.failure(partial: "Half an ans")]

        await XCTAssertThrowsErrorAsync(try await session.send(message: "Question", stream: true))

        XCTAssertEqual(try stored(session.conversationID).map(\.text), ["Question", "Half an ans"])
    }

    func testRetryReplacesTheFailedAttemptsOutput() async throws {
        let session = try storedSession(manager())
        client.replies = [.failure(partial: "broken"), .text("fixed")]
        await XCTAssertThrowsErrorAsync(try await session.send(message: "Try", stream: true))
        let prompt = try XCTUnwrap(session.chatMessages.first { $0.isUser })
        XCTAssertNotNil(prompt.sendFailure)

        let retry = try session.retryOperation(messageID: prompt.uuid, stream: true)
        try await retry.waitForCompletion()

        XCTAssertEqual(try stored(session.conversationID).map(\.text), ["Try", "fixed"],
                       "The failed attempt's partial output is deleted from storage")
    }

    func testStoppedMarkerAndDeletesAreDurable() async throws {
        let session = try storedSession(manager())
        client.replies = [.text("one"), .text("two")]
        try await session.send(message: "first", stream: true)
        try await session.send(message: "second", stream: true)
        let firstPrompt = try XCTUnwrap(session.chatMessages.first)
        let secondReply = try XCTUnwrap(session.chatMessages.last)

        session.markResponseStopped(messageID: firstPrompt.uuid)
        session.deleteMessage(id: secondReply.uuid)
        try session.flush()

        let reloaded = try stored(session.conversationID)
        XCTAssertEqual(reloaded.map(\.text), ["first", "one", "second"])
        XCTAssertTrue(reloaded[0].wasResponseStopped)
    }

    func testAFailedToolCallIsSavedWithItsFailureState() async throws {
        let session = try storedSession(manager())
        client.replies = [.toolCallThenFailure(name: "lookup")]

        await XCTAssertThrowsErrorAsync(try await session.send(message: "Use the tool", stream: true))

        let reloaded = try stored(session.conversationID)
        XCTAssertEqual(reloaded.first?.text, "Use the tool", "A send with tool activity keeps its prompt")
        let call = try XCTUnwrap(reloaded.flatMap(\.toolCalls).first)
        XCTAssertEqual(call.name, "lookup")
        XCTAssertEqual(call.status, .failure, "The final failed state is what gets stored")
    }

    func testCancellingASendCleansUpAndKeepsThePrompt() async throws {
        let session = try storedSession(manager())
        client.replies = [.held]
        let operation = session.sendOperation(message: "Never mind", stream: true)
        try await operation.waitUntilEstablished()
        XCTAssertEqual(session.activeSendCount, 1)

        operation.cancel()
        try? await operation.waitForCompletion()

        XCTAssertEqual(session.activeSendCount, 0)
        XCTAssertFalse(session.hasActivity)
        XCTAssertEqual(try stored(session.conversationID).map(\.text), ["Never mind"])
    }

    // MARK: Drafts

    func testDraftIsStoredOnlyWhenItsFirstMessageIsSent() async throws {
        let manager = manager()
        let owner = ConversationOwner(kind: "bot", id: "primary")
        let session = manager.draftSession(ConversationDraft(owner: owner, threadKind: "topic"))
        XCTAssertFalse(session.isMaterialized)
        XCTAssertNil(try storage.conversation(id: session.conversationID))

        client.replies = [.text("ok")]
        try await session.send(message: "Start", stream: true)

        let record = try XCTUnwrap(try storage.conversation(id: session.conversationID))
        XCTAssertTrue(session.isMaterialized)
        XCTAssertEqual(record.owner, owner)
        XCTAssertEqual(record.threadKind, "topic")
        XCTAssertEqual(record.title, "Start")
        XCTAssertTrue(manager.draftSession(ConversationDraft(id: session.conversationID)) === session)
    }

    func testDraftCreationFailureSendsNoRequest() async throws {
        let session = manager().draftSession(ConversationDraft())
        failingSaves = 1

        await XCTAssertThrowsErrorAsync(try await session.send(message: "Never sent", stream: true))

        XCTAssertTrue(client.requests.isEmpty)
        XCTAssertFalse(session.isMaterialized)
        XCTAssertTrue(session.chatMessages.isEmpty)
    }

    // MARK: Concurrency and deletion

    func testABackgroundConversationKeepsStreamingWhileAnotherSends() async throws {
        let manager = manager()
        let first = try storedSession(manager)
        let second = try storedSession(manager)
        client.replies = [.held, .text("quick")]

        let slow = first.sendOperation(message: "slow", stream: true)
        try await slow.waitUntilEstablished()
        try await second.send(message: "fast", stream: true)
        client.yieldHeld("late")
        client.finishHeld()
        try await slow.waitForCompletion()

        XCTAssertEqual(try stored(first.conversationID).map(\.text), ["slow", "late"])
        XCTAssertEqual(try stored(second.conversationID).map(\.text), ["fast", "quick"])
    }

    func testDeletingTheConversationClosesItsSessionAndWritesNothingMore() async throws {
        let manager = manager()
        let session = try storedSession(manager)
        client.replies = [.held]
        let operation = session.sendOperation(message: "about to vanish", stream: true)
        try await operation.waitUntilEstablished()

        try storage.deleteConversations(ids: [session.conversationID])
        try? await operation.waitForCompletion()

        XCTAssertTrue(session.isClosed)
        XCTAssertNil(try storage.conversation(id: session.conversationID))
        XCTAssertNil(manager.liveSession(for: session.conversationID))
    }

    func testFlushAllSavesQueuedStreamingUpdates() async throws {
        let manager = manager()
        let session = try storedSession(manager)
        client.replies = [.held]
        let operation = session.sendOperation(message: "pending", stream: true)
        try await operation.waitUntilEstablished()
        client.yieldHeld("partial")
        await assertEventually { session.chatMessages.count == 2 }
        XCTAssertTrue(manager.flushAll().isEmpty)

        XCTAssertEqual(try stored(session.conversationID).map(\.text), ["pending", "partial"])
        client.finishHeld()
        try await operation.waitForCompletion()
    }
}

func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {}
}
