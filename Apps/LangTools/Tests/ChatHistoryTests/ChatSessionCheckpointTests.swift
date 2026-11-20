import Foundation
import Ollama
import XCTest
@testable import Chat
@testable import ChatContext
@testable import ChatHistory

/// What a session publishes about compaction, which the transcript's markers
/// and progress cue are drawn from.
@MainActor
final class ChatSessionCheckpointTests: XCTestCase {
    private var storage: InMemoryChatHistoryStorage!
    private var client: ScriptedChatClient!

    override func setUp() async throws {
        storage = InMemoryChatHistoryStorage()
        client = ScriptedChatClient()
    }

    /// Twenty stored messages, with a checkpoint covering the first `covered`.
    private func storedConversation(covered: Int? = nil, model: String = "openai/gpt-4o-mini") throws -> (UUID, [Message], ContextCheckpoint?) {
        let messages = (0..<20).map { text("m\($0)", $0.isMultiple(of: 2) ? .user : .assistant, at: TimeInterval($0)) }
        let record = try storage.importConversation(ConversationDraft(title: "Long"), messages: messages)
        var saved: ContextCheckpoint?
        if let covered {
            let checkpoint = ContextCheckpoint(
                conversationID: record.id,
                coversThroughMessageID: messages[covered - 1].uuid,
                summary: "summary",
                tokenEstimate: 3,
                model: model,
                createdAt: Date(timeIntervalSinceReferenceDate: 500)
            )
            try storage.saveCheckpoint(checkpoint)
            saved = checkpoint
        }
        return (record.id, messages, saved)
    }

    /// Hooks whose requests compact early: no published window, so the
    /// policy's 1,024-token fallback applies.
    private func compactingHooks(summarizer: any ConversationSummarizer) -> ChatSessionHooks {
        let client = self.client!
        var hooks = ChatSessionHooks(makeMessageService: { _ in
            MessageService(
                networkClient: client,
                agents: nil,
                tools: nil,
                dependencies: .init(
                    selectedModel: { .ollama(Ollama.Model(rawValue: "checkpoint-test:latest")!) },
                    conversationSettings: { ChatConversationSettings(systemPrompt: "test prompt") },
                    keepsToolCallsInHistory: { true },
                    maxToolIterations: { nil },
                    enabledTools: { nil },
                    toolConfigurations: { [] }
                )
            )
        })
        hooks.makeRequestPreparer = ChatSessionHooks.compactingRequestPreparers(
            policy: { _ in
                CompactionPolicy(
                    triggerPercent: 50,
                    targetPercent: 25,
                    minimumRecentTurns: 1,
                    summaryTokenLimit: 64,
                    reservedResponseTokens: 0,
                    fallbackContextWindowTokens: 1_024
                )
            },
            summarizer: summarizer
        )
        return hooks
    }

    private func session(_ id: UUID, hooks: ChatSessionHooks? = nil, paging: ChatSessionPaging = .unbounded) throws -> ChatSession {
        try ChatSessionManager(storage: storage, hooks: hooks ?? TestHooks.make(client: client), timing: .manual, paging: paging)
            .session(for: id)
    }

    private let longPrompt = String(repeating: "long prompt ", count: 80)

    // MARK: Stored checkpoints

    func testStoredCheckpointsAreListedWithWhatTheyCover() throws {
        let (id, messages, saved) = try storedConversation(covered: 6)
        let session = try session(id)

        XCTAssertEqual(session.checkpoints, [ChatSessionCheckpoint(checkpoint: try XCTUnwrap(saved), coveredMessageCount: 6, isSaved: true)])
        XCTAssertEqual(session.checkpoint(endingAt: messages[5].uuid)?.id, saved?.id, "The marker follows the covered message")
        XCTAssertNil(session.checkpoint(endingAt: messages[6].uuid))
        XCTAssertNil(session.leadingCheckpoint, "Every message is loaded, so the marker is inline")
        XCTAssertFalse(session.isCompacting)
    }

    func testAnExtractiveCheckpointSaysSo() throws {
        let (id, _, _) = try storedConversation(covered: 6, model: ContextSummary.extractiveModelName)
        let checkpoint = try XCTUnwrap(try session(id).checkpoints.first)

        XCTAssertTrue(checkpoint.isExtractive)
        XCTAssertEqual(ChatCheckpointText.author(for: checkpoint), "Summarized without the model")
        XCTAssertTrue(ChatCheckpointText.accessibilityLabel(for: checkpoint).hasPrefix("Earlier messages summarized, 6 messages, "))
    }

    func testTheCheckpointAConversationOpensFromLeadsUntilEarlierMessagesLoad() throws {
        let (id, messages, saved) = try storedConversation(covered: 10)
        // Sessions open from a checkpoint only when a preparer injects it.
        var hooks = TestHooks.make(client: client)
        hooks.makeRequestPreparer = { _ in { $0 } }
        let session = try session(id, hooks: hooks, paging: ChatSessionPaging(initialMessageCount: 3, earlierPageSize: 20))

        XCTAssertEqual(session.chatMessages.first?.uuid, messages[9].uuid, "Opens at the covered message")
        XCTAssertEqual(session.leadingCheckpoint?.id, saved?.id, "Shown above the messages, with the earlier ones")
        XCTAssertEqual(session.checkpoint(endingAt: messages[9].uuid)?.id, saved?.id)
        XCTAssertNil(session.inlineCheckpoint(after: messages[9].uuid), "Not repeated inline")

        try session.loadEarlierMessages()

        XCTAssertFalse(session.canLoadEarlierMessages)
        XCTAssertNil(session.leadingCheckpoint, "Once everything is loaded the marker is inline again")
        XCTAssertEqual(session.inlineCheckpoint(after: messages[9].uuid)?.id, saved?.id)
    }

    func testDeletingASummarizedMessageRemovesItsMarker() throws {
        let (id, messages, _) = try storedConversation(covered: 6)
        let session = try session(id)
        XCTAssertEqual(session.checkpoints.count, 1)

        session.deleteMessage(id: messages[2].uuid)
        try session.flush()

        XCTAssertTrue(session.checkpoints.isEmpty, "A summary of deleted content is dropped, and so is its marker")
        XCTAssertNil(session.checkpoint(endingAt: messages[5].uuid))
    }

    // MARK: Compacting during a send

    func testACompactingSendShowsProgressThenItsMarker() async throws {
        let (id, messages, _) = try storedConversation()
        let summarizer = GatedSummarizer()
        let session = try session(id, hooks: compactingHooks(summarizer: summarizer))
        client.replies = [.text("reply")]
        XCTAssertTrue(session.checkpoints.isEmpty)

        let send = Task { try await session.send(message: longPrompt, stream: true) }
        await assertEventually { summarizer.isWaiting }

        XCTAssertTrue(session.isCompacting, "The send waits on the summary")
        XCTAssertTrue(session.checkpoints.isEmpty, "Nothing is shown before it is saved")

        summarizer.release()
        try await send.value

        XCTAssertFalse(session.isCompacting)
        let stored = try XCTUnwrap(try storage.latestCheckpoint(conversationID: id))
        XCTAssertEqual(session.checkpoints, [ChatSessionCheckpoint(checkpoint: stored, coveredMessageCount: 18, isSaved: true)])
        XCTAssertEqual(session.checkpoint(endingAt: messages[17].uuid)?.id, stored.id, "Appears without reopening the session")
        XCTAssertFalse(session.chatMessages.contains { $0.text?.contains(stored.summary) == true }, "The summary is never a message")
    }

    func testAFallbackSummaryIsListedAsUnsavedUntilASavedOneReplacesIt() async throws {
        let (id, _, _) = try storedConversation()
        let summarizer = GatedSummarizer()
        summarizer.error = ScriptedError.scripted
        let session = try session(id, hooks: compactingHooks(summarizer: summarizer))
        client.replies = [.text("reply")]

        try await session.send(message: longPrompt, stream: true)

        let fallback = try XCTUnwrap(session.checkpoints.last)
        XCTAssertEqual(session.checkpoints.count, 1)
        XCTAssertFalse(fallback.isSaved)
        XCTAssertTrue(fallback.isExtractive)
        XCTAssertEqual(fallback.coveredMessageCount, 18)
        XCTAssertNil(try storage.latestCheckpoint(conversationID: id), "A fallback summary is never saved")
        XCTAssertFalse(session.isCompacting)
    }

    func testCompactionFromAnotherPreparerReachesTheSessionThroughItsContext() async throws {
        let (id, messages, _) = try storedConversation()
        let store = storage!
        var hooks = TestHooks.make(client: client)
        hooks.makeRequestPreparer = { context in
            { request in
                context.reportCompaction(.summarizing(messageCount: 2))
                let checkpoint = ContextCheckpoint(
                    conversationID: context.conversationID,
                    coversThroughMessageID: messages[1].uuid,
                    summary: "custom",
                    tokenEstimate: 1,
                    model: "custom/model"
                )
                try store.saveCheckpoint(checkpoint)
                context.reportCompaction(.compacted(checkpoint))
                return request
            }
        }
        let session = try session(id, hooks: hooks)
        client.replies = [.text("reply")]

        try await session.send(message: "hi", stream: true)

        XCTAssertEqual(session.checkpoints.map(\.checkpoint.summary), ["custom"])
        XCTAssertFalse(session.isCompacting)
    }
}

/// A summarizer that waits until released, so a test can look at a send
/// while it is compacting.
@MainActor
private final class GatedSummarizer: ConversationSummarizer {
    var error: Error?
    private var gate: CheckedContinuation<Void, Never>?
    private var released = false
    var isWaiting: Bool { gate != nil }

    func summarize(_ request: SummaryRequest) async throws -> ContextSummary {
        if let error { throw error }
        if !released {
            await withCheckedContinuation { gate = $0 }
        }
        return ContextSummary(text: "summary of \(request.messages.count) messages", model: "test/summarizer")
    }

    func release() {
        released = true
        gate?.resume()
        gate = nil
    }
}
