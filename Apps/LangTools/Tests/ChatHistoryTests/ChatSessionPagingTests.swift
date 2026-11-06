import Foundation
import Ollama
import XCTest
@testable import Chat
@testable import ChatContext
@testable import ChatHistory

@MainActor
final class ChatSessionPagingTests: XCTestCase {
    private var storage: InMemoryChatHistoryStorage!
    private var client: ScriptedChatClient!
    private var saves = 0

    override func setUp() async throws {
        storage = InMemoryChatHistoryStorage()
        client = ScriptedChatClient()
        saves = 0
        storage.saveHook = { [unowned self] in self.saves += 1 }
    }

    private func manager(paging: ChatSessionPaging = ChatSessionPaging(initialMessageCount: 3, earlierPageSize: 4)) -> ChatSessionManager {
        ChatSessionManager(storage: storage, hooks: TestHooks.make(client: client), timing: .manual, paging: paging)
    }

    /// Twenty stored messages, with a checkpoint covering the first `covered`.
    private func storedConversation(covered: Int? = nil) throws -> (UUID, [Message]) {
        let messages = (0..<20).map { text("m\($0)", $0.isMultiple(of: 2) ? .user : .assistant, at: TimeInterval($0)) }
        let record = try storage.importConversation(ConversationDraft(title: "Long"), messages: messages)
        if let covered {
            try storage.saveCheckpoint(ContextCheckpoint(
                conversationID: record.id,
                coversThroughMessageID: messages[covered - 1].uuid,
                summary: "summary",
                tokenEstimate: 1,
                model: "m"
            ))
        }
        saves = 0
        return (record.id, messages)
    }

    func testWithoutACheckpointEveryMessageLoads() throws {
        let (id, messages) = try storedConversation()
        let session = try manager().session(for: id)

        XCTAssertEqual(session.chatMessages.map(\.uuid), messages.map(\.uuid), "Requests need the whole history")
        XCTAssertFalse(session.canLoadEarlierMessages)
    }

    func testOpeningLoadsFromTheCheckpointAndPagesEarlierMessagesOnDemand() throws {
        let (id, messages) = try storedConversation(covered: 10)
        let session = try manager().session(for: id)

        XCTAssertEqual(session.chatMessages.map(\.uuid), messages[9...].map(\.uuid), "The covered message and everything after it")
        XCTAssertTrue(session.canLoadEarlierMessages)

        XCTAssertEqual(try session.loadEarlierMessages(), 4)
        XCTAssertEqual(session.chatMessages.map(\.uuid), messages[5...].map(\.uuid))
        XCTAssertEqual(try session.loadEarlierMessages(), 4)
        XCTAssertEqual(try session.loadEarlierMessages(), 1)
        XCTAssertFalse(session.canLoadEarlierMessages)
        XCTAssertEqual(session.chatMessages.map(\.uuid), messages.map(\.uuid))
        XCTAssertEqual(try session.loadEarlierMessages(), 0)

        XCTAssertEqual(saves, 0, "Paging never writes")
        XCTAssertEqual(session.pendingUpsertCountForTesting, 0)
    }

    func testARecentCheckpointStillLoadsTheMinimumCount() throws {
        let (id, messages) = try storedConversation(covered: 19)
        let session = try manager(paging: ChatSessionPaging(initialMessageCount: 5, earlierPageSize: 4)).session(for: id)
        XCTAssertEqual(session.chatMessages.map(\.uuid), messages.suffix(5).map(\.uuid))
    }

    func testUnboundedPagingLoadsEverything() throws {
        let (id, messages) = try storedConversation(covered: 10)
        let session = try manager(paging: .unbounded).session(for: id)
        XCTAssertEqual(session.chatMessages.count, messages.count)
        XCTAssertFalse(session.canLoadEarlierMessages)
    }

    func testSendingAfterPagingSavesOnlyTheNewTurn() async throws {
        let (id, messages) = try storedConversation(covered: 10)
        let session = try manager().session(for: id)
        try session.loadEarlierMessages()
        client.replies = [.text("reply")]

        try await session.send(message: "new", stream: true)

        let stored = try storage.loadMessages(conversationID: id)
        XCTAssertEqual(stored.count, messages.count + 2)
        XCTAssertEqual(Array(stored.map(\.uuid).prefix(messages.count)), messages.map(\.uuid), "Paged-in messages keep their place")
        XCTAssertEqual(saves, 1)
        XCTAssertEqual(client.requests.first?.dropFirst().count, 16, "Without a preparer the request replays what is loaded plus the prompt")
    }

    // MARK: Compaction through the hooks

    func testCompactingHooksWriteCheckpointsThatTheNextSessionOpensFrom() async throws {
        let (id, messages) = try storedConversation()
        let client = self.client!
        var events: [CompactingRequestPreparer.Event] = []
        var hooks = ChatSessionHooks(makeMessageService: { context in
            MessageService(
                networkClient: client,
                agents: nil,
                tools: nil,
                dependencies: .init(
                    // No published window, so the policy's 1,024-token fallback applies.
                    selectedModel: { .ollama(Ollama.Model(rawValue: "paging-test:latest")!) },
                    conversationSettings: { ChatConversationSettings(systemPrompt: "test prompt") },
                    keepsToolCallsInHistory: { true },
                    maxToolIterations: { nil },
                    enabledTools: { nil },
                    toolConfigurations: { [] }
                )
            )
        })
        hooks.makeRequestPreparer = ChatSessionHooks.compactingRequestPreparers(
            policy: { record in
                XCTAssertEqual(record?.id, id, "The policy is resolved for the session's conversation")
                return CompactionPolicy(
                    triggerPercent: 50,
                    targetPercent: 25,
                    minimumRecentTurns: 1,
                    summaryTokenLimit: 64,
                    reservedResponseTokens: 0,
                    fallbackContextWindowTokens: 1_024
                )
            },
            summarizer: ExtractiveConversationSummarizer(),
            onEvent: { conversationID, event in
                XCTAssertEqual(conversationID, id)
                events.append(event)
            }
        )
        let paging = ChatSessionPaging(initialMessageCount: 2, earlierPageSize: 4)
        let session = try ChatSessionManager(storage: storage, hooks: hooks, timing: .manual, paging: paging).session(for: id)
        client.replies = [.text("reply")]

        try await session.send(message: String(repeating: "long prompt ", count: 80), stream: true)

        let checkpoint = try XCTUnwrap(try storage.latestCheckpoint(conversationID: id))
        XCTAssertEqual(events, [.compacted(checkpoint)])
        XCTAssertEqual(checkpoint.coversThroughMessageID, messages[17].uuid, "Keeps the last turn and the prompt")
        let request = try XCTUnwrap(client.requests.first)
        XCTAssertTrue(request.first?.text?.contains(checkpoint.summary) == true)
        XCTAssertEqual(request.dropFirst().map(\.text), ["m18", "m19", String(repeating: "long prompt ", count: 80)])
        XCTAssertEqual(session.chatMessages.count, 22, "The open session keeps its whole transcript")

        session.close()
        let reopened = try ChatSessionManager(storage: storage, hooks: hooks, timing: .manual, paging: paging).session(for: id)
        XCTAssertEqual(reopened.chatMessages.map(\.text).prefix(3), ["m17", "m18", "m19"], "A new session opens from the checkpoint")
        XCTAssertEqual(reopened.chatMessages.count, 5)
        XCTAssertTrue(reopened.canLoadEarlierMessages)
    }
}
