import ChatUI
import Foundation
import XCTest
@testable import Chat
@testable import ChatContext

@MainActor
final class CompactingRequestPreparerTests: XCTestCase {
    private var store: InMemoryContextCheckpointStore!
    private var summarizer: RecordingSummarizer!
    private var clock = Date(timeIntervalSinceReferenceDate: 1_000)
    private var events: [CompactingRequestPreparer.Event] = []
    private let conversationID = UUID()
    private let estimator = TokenEstimator.standard

    override func setUp() async throws {
        store = InMemoryContextCheckpointStore()
        summarizer = RecordingSummarizer()
        events = []
    }

    private func preparer(
        policy: CompactionPolicy = testPolicy(),
        summarizer: (any ConversationSummarizer)? = nil,
        useRecordingSummarizer: Bool = true
    ) -> CompactingRequestPreparer {
        let preparer = CompactingRequestPreparer(
            conversationID: conversationID,
            checkpoints: store,
            policy: { policy },
            summarizer: summarizer ?? (useRecordingSummarizer ? self.summarizer : nil),
            now: { [unowned self] in self.clock }
        )
        preparer.onEvent = { [unowned self] in self.events.append($0) }
        return preparer
    }

    private func tokens(of context: ChatRequestContext) -> Int {
        estimator.tokens(in: context.systemPrompt) + estimator.tokens(in: context.history)
    }

    // MARK: Below the trigger

    func testRequestsUnderTheTriggerAreUnchanged() async throws {
        // 14 turns of 220 tokens plus the prompt is about 3,100 tokens, under the 3,200 trigger.
        let history = conversation(turns: 14)
        let context = requestContext(history)

        let prepared = try await preparer().prepare(context)

        XCTAssertEqual(prepared.systemPrompt, "system")
        XCTAssertTrue(prepared.history.elementsEqual(history, by: ===), "Nothing to change, so the snapshot is passed through")
        XCTAssertTrue(summarizer.requests.isEmpty)
        XCTAssertTrue(store.checkpoints.isEmpty)
    }

    // MARK: Compacting

    func testCrossingTheTriggerFoldsTheOldestTurnsIntoASavedCheckpoint() async throws {
        let history = conversation(turns: 15)
        let snapshot = history.map { $0.text }

        let prepared = try await preparer().prepare(requestContext(history))

        let request = try XCTUnwrap(summarizer.requests.first)
        XCTAssertNil(request.previousSummary)
        XCTAssertEqual(request.maximumTokens, 200)
        let coveredCount = request.messages.count
        XCTAssertTrue(request.messages.elementsEqual(history.prefix(coveredCount), by: ===), "The oldest messages are summarized")
        XCTAssertTrue(history[coveredCount].isUser, "The cut falls before a user message")

        let checkpoint = try XCTUnwrap(store.checkpoints.first)
        XCTAssertEqual(store.checkpoints.count, 1)
        XCTAssertEqual(checkpoint.conversationID, conversationID)
        XCTAssertEqual(checkpoint.coversThroughMessageID, history[coveredCount - 1].uuid)
        XCTAssertEqual(checkpoint.summary, "summary of \(coveredCount) messages")
        XCTAssertEqual(checkpoint.model, "test/summarizer")
        XCTAssertEqual(checkpoint.tokenEstimate, estimator.tokens(in: checkpoint.summary))
        XCTAssertEqual(checkpoint.createdAt, clock)
        XCTAssertEqual(events, [.compacted(checkpoint)])

        XCTAssertEqual(prepared.systemPrompt, CompactedContext.systemPrompt("system", summary: checkpoint.summary))
        XCTAssertEqual(prepared.history.map(\.uuid), history.dropFirst(coveredCount).map(\.uuid))
        XCTAssertEqual(prepared.history.last?.text, "current question")
        XCTAssertLessThanOrEqual(tokens(of: prepared), 2_000, "The request fits the 50% target")

        // Folding as little as needed: one turn fewer would not fit the target.
        let oneTurnFewer = estimator.tokens(in: CompactedContext.systemPrompt("system", summary: ""))
            + 200 + estimator.tokens(in: history.dropFirst(coveredCount - 2))
        XCTAssertGreaterThan(oneTurnFewer, 2_000)

        XCTAssertFalse(prepared.history.contains { kept in history.contains { $0 === kept } }, "The request holds copies")
        XCTAssertEqual(history.map(\.text), snapshot, "The transcript is never mutated")
    }

    func testTheCheckpointStaysStableSoTheRequestPrefixRepeats() async throws {
        let preparer = preparer()
        var history = conversation(turns: 15)
        let first = try await preparer.prepare(requestContext(history))

        // The next turn: the previous prompt was answered and a new one sent.
        history.append(Message(text: "answer", role: .assistant))
        history.append(Message(text: "follow-up", role: .user))
        let second = try await preparer.prepare(requestContext(history))

        XCTAssertEqual(summarizer.requests.count, 1, "No new summary until the trigger is crossed again")
        XCTAssertEqual(second.systemPrompt, first.systemPrompt, "Identical prefix keeps provider prompt caching effective")
        XCTAssertEqual(Array(second.history.map(\.uuid).prefix(first.history.count)), first.history.map(\.uuid))
        XCTAssertEqual(second.history.suffix(2).map(\.text), ["answer", "follow-up"])
    }

    func testTheNextCompactionFoldsTheOldSummaryWithTheFollowingTurns() async throws {
        let preparer = preparer()
        var history = conversation(turns: 15)
        _ = try await preparer.prepare(requestContext(history))
        let first = try XCTUnwrap(store.checkpoints.first)
        clock += 60

        history.removeLast()
        history += conversation(turns: 8, prompt: "much later")
        let prepared = try await preparer.prepare(requestContext(history))

        XCTAssertEqual(summarizer.requests.count, 2)
        let second = summarizer.requests[1]
        XCTAssertEqual(second.previousSummary, first.summary)
        let boundary = try XCTUnwrap(history.firstIndex { $0.uuid == first.coversThroughMessageID })
        XCTAssertTrue(second.messages.first === history[boundary + 1], "The new summary continues from the old checkpoint")
        let latest = try XCTUnwrap(try store.latestCheckpoint(conversationID: conversationID))
        XCTAssertNotEqual(latest.id, first.id)
        XCTAssertEqual(latest.createdAt, clock)
        XCTAssertTrue(prepared.systemPrompt.hasSuffix(latest.summary))
        XCTAssertEqual(prepared.history.last?.text, "much later")
    }

    func testAMissingCoveredMessageKeepsTheSummaryAndTheWholeHistory() async throws {
        let history = conversation(turns: 2)
        try store.saveCheckpoint(ContextCheckpoint(
            conversationID: conversationID,
            coversThroughMessageID: UUID(),
            summary: "older summary",
            tokenEstimate: 3,
            model: "m"
        ))

        let prepared = try await preparer().prepare(requestContext(history))

        XCTAssertEqual(prepared.systemPrompt, CompactedContext.systemPrompt("system", summary: "older summary"))
        XCTAssertEqual(prepared.history.map(\.uuid), history.map(\.uuid), "Content may repeat, but nothing is lost")
    }

    func testTheWindowPercentSettingTriggersCompactionEarlier() async throws {
        let history = conversation(turns: 10)
        let preparer = preparer()

        _ = try await preparer.prepare(requestContext(history))
        XCTAssertTrue(summarizer.requests.isEmpty, "2,200 tokens fit the full window")

        _ = try await preparer.prepare(requestContext(history, settings: ChatConversationSettings(contextWindowPercent: 50)))
        XCTAssertEqual(summarizer.requests.count, 1, "At 50% the trigger is 1,600 tokens")
    }

    func testADisabledPolicyNeverCompactsButStillAppliesAnExistingSummary() async throws {
        let history = conversation(turns: 30)
        let disabled = preparer(policy: testPolicy(isEnabled: false))

        let untouched = try await disabled.prepare(requestContext(history))
        XCTAssertTrue(untouched.history.elementsEqual(history, by: ===))
        XCTAssertTrue(summarizer.requests.isEmpty)

        try store.saveCheckpoint(ContextCheckpoint(conversationID: conversationID, coversThroughMessageID: history[9].uuid, summary: "kept", tokenEstimate: 1, model: "m"))
        let summarized = try await disabled.prepare(requestContext(history))
        XCTAssertTrue(summarized.systemPrompt.hasSuffix("kept"))
        XCTAssertEqual(summarized.history.map(\.uuid), history.dropFirst(10).map(\.uuid))
        XCTAssertTrue(summarizer.requests.isEmpty)
    }

    func testInFlightTurnsAreNeverSummarized() async throws {
        let history = conversation(turns: 15)
        let inFlight = history[2] // the second turn's prompt is still streaming

        _ = try await preparer().prepare(requestContext(history, inFlight: [inFlight.uuid]))

        let request = try XCTUnwrap(summarizer.requests.first)
        XCTAssertEqual(request.messages.map(\.uuid), history.prefix(2).map(\.uuid), "Only the turn before the in-flight one is folded")
    }

    // MARK: Choosing the cut

    func testRecentTurnsAreKeptWhenTheyFitTheLimitButNotTheTarget() async throws {
        // Three huge recent turns (about 1,000 tokens each message pair) after small ones.
        var history = (0..<5).flatMap { turn($0, tokens: 20) }
        history += (5..<8).flatMap { turn($0, tokens: 490) }
        history.append(Message(text: "current question", role: .user))

        let prepared = try await preparer(policy: testPolicy(minimumRecentTurns: 2)).prepare(requestContext(history))

        let request = try XCTUnwrap(summarizer.requests.first)
        // Two recent turns plus the prompt (about 2,000 tokens) miss the 2,000 target with the summary room but fit the 4,000 limit.
        XCTAssertEqual(request.messages.count, 12, "Folds the small turns and the first huge one")
        XCTAssertEqual(prepared.history.count, 5)
    }

    func testWhenNothingFitsTheLargestCutIsUsed() async throws {
        var history = turn(0, tokens: 2_000)
        history.append(Message(text: filler(4_000, "enormous prompt"), role: .user))

        let prepared = try await preparer().prepare(requestContext(history))

        XCTAssertEqual(summarizer.requests.first?.messages.count, 2)
        XCTAssertEqual(prepared.history.count, 1, "Only the current prompt is left; the provider reports the overflow")
    }

    func testNothingFoldableSendsTheRequestAsItIs() async throws {
        let history = [Message(text: filler(5_000, "one huge prompt"), role: .user)]
        let prepared = try await preparer().prepare(requestContext(history))
        XCTAssertTrue(prepared.history.elementsEqual(history, by: ===))
        XCTAssertTrue(summarizer.requests.isEmpty)
    }

    // MARK: Failures

    func testASummarizerFailureFallsBackToAnUnsavedExtractiveSummary() async throws {
        summarizer.error = ContextTestError.summarizerDown
        let preparer = preparer()
        var history = conversation(turns: 15)

        let prepared = try await preparer.prepare(requestContext(history))

        XCTAssertTrue(store.checkpoints.isEmpty, "A fallback summary is never saved")
        guard case .usedFallbackSummary(let fallback, _) = events.first else { return XCTFail("Expected a fallback event: \(events)") }
        XCTAssertEqual(fallback.model, ContextSummary.extractiveModelName)
        XCTAssertTrue(prepared.systemPrompt.hasSuffix(fallback.summary))
        XCTAssertTrue(prepared.history.first?.isUser == true)

        // Within the cooldown the model is not asked again, even when compacting.
        history.removeLast()
        history += conversation(turns: 10)
        _ = try await preparer.prepare(requestContext(history))
        XCTAssertEqual(summarizer.requests.count, 1)

        // After the cooldown a model summary is written from the original messages.
        clock += 301
        summarizer.error = nil
        history.removeLast()
        history += conversation(turns: 10)
        _ = try await preparer.prepare(requestContext(history))
        XCTAssertEqual(summarizer.requests.count, 2)
        XCTAssertNil(summarizer.requests[1].previousSummary, "Built from messages, not from the fallback summary")
        XCTAssertTrue(summarizer.requests[1].messages.first === history[0])
        XCTAssertEqual(store.checkpoints.count, 1)
    }

    func testWithoutASummarizerTheExtractiveSummaryIsUsed() async throws {
        let prepared = try await preparer(useRecordingSummarizer: false).prepare(requestContext(conversation(turns: 15)))
        XCTAssertTrue(prepared.systemPrompt.contains("- User: q7"), "The newest folded turn is listed")
        XCTAssertTrue(prepared.systemPrompt.contains("earlier turns omitted)"))
        XCTAssertTrue(store.checkpoints.isEmpty)
    }

    func testASaveFailureStillUsesTheSummaryForThisAndLaterRequests() async throws {
        store.saveHook = { throw ContextTestError.saveFailed }
        let preparer = preparer()
        var history = conversation(turns: 15)

        let first = try await preparer.prepare(requestContext(history))
        history.append(Message(text: "next", role: .user))
        let second = try await preparer.prepare(requestContext(history))

        guard case .checkpointSaveFailed = events.first else { return XCTFail("Expected a save failure: \(events)") }
        XCTAssertTrue(first.systemPrompt.hasSuffix("summary of \(summarizer.requests[0].messages.count) messages"))
        XCTAssertEqual(second.systemPrompt, first.systemPrompt)
        XCTAssertEqual(summarizer.requests.count, 1)
    }

    func testCancellingDuringSummarizationSavesNothing() async throws {
        summarizer.holds = true
        let preparer = preparer()
        let task = Task { try await preparer.prepare(requestContext(conversation(turns: 15))) }
        await waitFor { self.summarizer.gate != nil }

        task.cancel()
        summarizer.release()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertTrue(store.checkpoints.isEmpty)
    }

    // MARK: Concurrency

    func testConcurrentRequestsShareOneCompaction() async throws {
        summarizer.holds = true
        let preparer = preparer()
        var history = conversation(turns: 15)
        let first = Task { try await preparer.prepare(requestContext(history)) }
        await waitFor { self.summarizer.gate != nil }
        history.append(Message(text: "interleaved", role: .user))
        let second = Task { [history] in try await preparer.prepare(requestContext(history)) }
        await Task.yield()

        summarizer.release()
        let firstPrepared = try await first.value
        let secondPrepared = try await second.value

        XCTAssertEqual(summarizer.requests.count, 1, "The second request waits and reuses the new checkpoint")
        XCTAssertEqual(store.checkpoints.count, 1)
        XCTAssertEqual(secondPrepared.systemPrompt, firstPrepared.systemPrompt)
        XCTAssertEqual(secondPrepared.history.last?.text, "interleaved")
    }

    private func waitFor(_ condition: @escaping () -> Bool) async {
        for _ in 0..<400 where !condition() {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(condition())
    }
}
