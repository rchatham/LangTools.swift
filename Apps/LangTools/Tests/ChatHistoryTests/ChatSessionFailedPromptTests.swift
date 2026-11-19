import Foundation
import XCTest
@testable import Chat
@testable import ChatHistory
import ChatUI

/// `FailedPromptHandling.keepWithRetry` and the send events a host can
/// observe (Botsworth's reply activity).
@MainActor
final class ChatSessionFailedPromptTests: XCTestCase {
    private var storage: InMemoryChatHistoryStorage!
    private var client: ScriptedChatClient!
    private var events: [ChatSendEvent] = []
    private var alertedServices: [ObjectIdentifier] = []

    override func setUp() async throws {
        storage = InMemoryChatHistoryStorage()
        client = ScriptedChatClient()
        events = []
        alertedServices = []
    }

    private func manager(_ handling: FailedPromptHandling = .keepWithRetry) -> ChatSessionManager {
        var hooks = TestHooks.make(client: client, failedPromptHandling: handling)
        hooks.onSendEvent = { [unowned self] in self.events.append($0) }
        hooks.alert = { [unowned self] error, service in
            self.alertedServices.append(ObjectIdentifier(service))
            return ChatAlertInfo(title: "Error", message: error.localizedDescription)
        }
        return ChatSessionManager(storage: storage, hooks: hooks, timing: .manual)
    }

    private func storedSession(_ manager: ChatSessionManager) throws -> ChatSession {
        let record = try storage.importConversation(ConversationDraft(title: "Stored"), messages: [])
        return try manager.session(for: record.id)
    }

    private func stored(_ id: UUID) throws -> [String?] {
        try storage.loadMessages(conversationID: id).map(\.text)
    }

    private var outcomes: [ChatSendEvent.Outcome] {
        events.compactMap { if case .finished(let outcome) = $0.kind { return outcome } else { return nil } }
    }

    // MARK: keepWithRetry

    func testFailedPromptStaysOnScreenButOutOfStorage() async throws {
        let session = try storedSession(manager())
        client.replies = [.failure(partial: nil)]

        let operation = session.sendOperation(message: "Doomed", stream: true)
        await XCTAssertThrowsErrorAsync(try await operation.waitForCompletion())

        XCTAssertNil(operation.messageID, "ChatUI must route the failure through handleError too")
        let prompt = try XCTUnwrap(session.chatMessages.first)
        XCTAssertEqual(prompt.text, "Doomed")
        XCTAssertNotNil(prompt.sendFailure, "ChatUI's Retry row reads the failure from the message")
        XCTAssertEqual(try stored(session.conversationID), [])
        XCTAssertFalse(session.hasPendingPersistence)
    }

    func testFailedFirstSendOfADraftKeepsThePrompt() async throws {
        let manager = manager()
        let session = manager.draftSession(ConversationDraft())
        client.replies = [.failure(partial: nil)]

        await XCTAssertThrowsErrorAsync(try await session.send(message: "Hello?", stream: true))

        XCTAssertTrue(session.isMaterialized)
        XCTAssertEqual(session.chatMessages.map(\.text), ["Hello?"])
        XCTAssertEqual(try stored(session.conversationID), [])
    }

    func testRetryStoresTheHeldPromptWithItsReply() async throws {
        let session = try storedSession(manager())
        client.replies = [.failure(partial: nil), .text("Recovered")]
        await XCTAssertThrowsErrorAsync(try await session.send(message: "Again", stream: true))
        let prompt = try XCTUnwrap(session.chatMessages.first)

        try await session.retryOperation(messageID: prompt.uuid, stream: true).waitForCompletion()

        XCTAssertEqual(try stored(session.conversationID), ["Again", "Recovered"])
        XCTAssertEqual(session.chatMessages.filter(\.isUser).count, 1, "Retry resends the same prompt")
        XCTAssertNil(prompt.sendFailure)
        XCTAssertEqual(client.requests.count, 2)
    }

    func testRetryThatFailsAgainKeepsThePromptHeld() async throws {
        let session = try storedSession(manager())
        client.replies = [.failure(partial: nil), .failure(partial: nil)]
        await XCTAssertThrowsErrorAsync(try await session.send(message: "Still down", stream: true))
        let prompt = try XCTUnwrap(session.chatMessages.first)

        let retry = try session.retryOperation(messageID: prompt.uuid, stream: true)
        await XCTAssertThrowsErrorAsync(try await retry.waitForCompletion())

        XCTAssertNotNil(prompt.sendFailure)
        XCTAssertEqual(try stored(session.conversationID), [])
    }

    func testPartialReplyIsStoredWithItsPromptAndRemovedOnRetry() async throws {
        let session = try storedSession(manager())
        client.replies = [.failure(partial: "Half"), .text("Whole")]
        await XCTAssertThrowsErrorAsync(try await session.send(message: "Ask", stream: true))
        XCTAssertEqual(try stored(session.conversationID), ["Ask", "Half"])
        let prompt = try XCTUnwrap(session.chatMessages.first { $0.isUser })

        try await session.retryOperation(messageID: prompt.uuid, stream: true).waitForCompletion()

        XCTAssertEqual(try stored(session.conversationID), ["Ask", "Whole"])
    }

    func testALaterSendDoesNotStoreAnEarlierFailedPrompt() async throws {
        let session = try storedSession(manager())
        client.replies = [.failure(partial: nil), .text("Answer")]
        await XCTAssertThrowsErrorAsync(try await session.send(message: "Lost", stream: true))

        try await session.send(message: "Next", stream: true)

        XCTAssertEqual(try stored(session.conversationID), ["Next", "Answer"])
        XCTAssertEqual(client.requests.last?.contains { $0.text == "Lost" }, false,
                       "A failed prompt is not sent as history")
    }

    func testDeletingAHeldPromptForgetsIt() async throws {
        let session = try storedSession(manager())
        client.replies = [.failure(partial: nil)]
        await XCTAssertThrowsErrorAsync(try await session.send(message: "Drop me", stream: true))
        let prompt = try XCTUnwrap(session.chatMessages.first)

        session.deleteMessage(id: prompt.uuid)
        try session.flush()

        XCTAssertTrue(session.chatMessages.isEmpty)
        XCTAssertEqual(try stored(session.conversationID), [])
    }

    func testStoppingASendWithoutMessageIDStillMarksTheResponseStopped() async throws {
        let session = try storedSession(manager())
        client.replies = [.held]
        let operation = session.sendOperation(message: "Long one", stream: true)
        try await operation.waitUntilEstablished()
        client.yieldHeld("Partial")

        operation.cancel()
        try? await operation.waitForCompletion()
        try session.flush()

        let prompt = try XCTUnwrap(try storage.loadMessages(conversationID: session.conversationID).first)
        XCTAssertEqual(prompt.text, "Long one")
        XCTAssertTrue(prompt.wasResponseStopped)
    }

    func testOtherPoliciesKeepTheMessageID() async throws {
        let session = try storedSession(manager(.returnToComposer))
        client.replies = [.text("Hi")]
        let operation = session.sendOperation(message: "Hello", stream: true)
        try await operation.waitForCompletion()
        XCTAssertNotNil(operation.messageID)
    }

    func testAlertGetsTheSessionsMessageService() async throws {
        let session = try storedSession(manager())
        _ = session.handleError(error: ScriptedError.scripted)
        XCTAssertEqual(alertedServices, [ObjectIdentifier(session.messageService)])
    }

    // MARK: Send events

    func testSuccessfulSendReportsStartedThenSucceeded() async throws {
        let session = try storedSession(manager())
        client.replies = [.text("Done")]

        try await session.send(message: "Go", stream: true)

        XCTAssertEqual(events, [
            ChatSendEvent(conversationID: session.conversationID, kind: .started, isStillSending: true),
            ChatSendEvent(conversationID: session.conversationID, kind: .finished(.succeeded), isStillSending: false),
        ])
    }

    func testFailedSendReportsFailed() async throws {
        let session = try storedSession(manager())
        client.replies = [.failure(partial: nil)]
        await XCTAssertThrowsErrorAsync(try await session.send(message: "Go", stream: true))
        XCTAssertEqual(outcomes, [.failed])
    }

    func testCancelledSendReportsCancelled() async throws {
        let session = try storedSession(manager())
        client.replies = [.held]
        let operation = session.sendOperation(message: "Wait", stream: true)
        try await operation.waitUntilEstablished()

        operation.cancel()
        try? await operation.waitForCompletion()

        XCTAssertEqual(outcomes, [.cancelled])
    }

    func testClosingDuringASendReportsCancelled() async throws {
        let session = try storedSession(manager())
        client.replies = [.held]
        let operation = session.sendOperation(message: "Wait", stream: true)
        try await operation.waitUntilEstablished()

        session.close()
        client.finishHeld()
        try? await operation.waitForCompletion()

        XCTAssertEqual(outcomes, [.cancelled])
    }

    func testOverlappingSendsStayInFlightUntilTheLastFinishes() async throws {
        let session = try storedSession(manager())
        client.replies = [.held, .held]
        let first = session.sendOperation(message: "One", stream: true)
        let second = session.sendOperation(message: "Two", stream: true)
        try await first.waitUntilEstablished()
        try await second.waitUntilEstablished()

        client.finishHeld(index: 0)
        try? await first.waitForCompletion()
        XCTAssertEqual(events.last?.isStillSending, true)

        client.finishHeld(index: 1)
        try? await second.waitForCompletion()
        XCTAssertEqual(events.last?.isStillSending, false)
    }

    func testDraftCreationFailureReportsNothing() async throws {
        let manager = manager()
        let session = manager.draftSession(ConversationDraft())
        storage.saveHook = { throw ScriptedError.saveFailed }

        await XCTAssertThrowsErrorAsync(try await session.send(message: "Hi", stream: true))

        XCTAssertTrue(events.isEmpty, "No request was made, so no reply was pending")
    }
}
