import ChatUI
import Foundation
import OpenAI
import XCTest
@testable import Chat
@testable import ChatContext

final class TokenEstimatorTests: XCTestCase {
    private let estimator = TokenEstimator.standard

    func testTextRoundsUpAtFourBytesPerToken() {
        XCTAssertEqual(estimator.tokens(in: ""), 0)
        XCTAssertEqual(estimator.tokens(in: "abcd"), 1)
        XCTAssertEqual(estimator.tokens(in: "abcde"), 2, "Rounds up so estimates lean toward compacting early")
        XCTAssertEqual(estimator.tokens(in: String(repeating: "a", count: 400)), 100)
    }

    func testMultibyteTextCountsMoreThanItsCharacters() {
        // Four CJK characters are twelve UTF-8 bytes. A characters-per-token
        // heuristic would say one token; real tokenizers use several.
        XCTAssertEqual(estimator.tokens(in: "你好世界"), 3)
    }

    @MainActor
    func testMessagesCountOverheadTextAndFinishedToolCalls() {
        let plain = Message(text: String(repeating: "a", count: 40), role: .user)
        XCTAssertEqual(estimator.tokens(in: plain), 10 + 10)

        let withTools = Message(
            role: .assistant,
            contentType: .string(""),
            toolCalls: [
                ChatToolCall(id: "1", name: "abcd", arguments: "abcdabcd", status: .success, result: "visible"),
                ChatToolCall(id: "2", name: "pending", arguments: "ignored", status: .pending),
            ],
            providerToolResults: ["1": String(repeating: "r", count: 40)]
        )
        // overhead 10 + call overhead 10 + name 1 + arguments 2 + hidden raw result 10
        XCTAssertEqual(estimator.tokens(in: withTools), 33, "Raw provider results replace the visible result; pending calls are not replayed")
    }
}

final class ContextBudgetTests: XCTestCase {
    func testUsesThePublishedWindowMinusTheReplyReserve() {
        let budget = ContextBudget(model: .openAI(.gpt4), settings: .default, policy: .standard)
        XCTAssertEqual(budget.contextWindowTokens, 8_192)
        XCTAssertTrue(budget.isContextWindowKnown)
        XCTAssertEqual(budget.reservedResponseTokens, 2_048, "The reserve is capped at a quarter of the window")
        XCTAssertEqual(budget.inputTokenLimit, 6_144)
    }

    func testHonorsTheConversationsWindowPercent() {
        let half = ContextBudget(
            model: .openAI(.gpt4o_mini),
            settings: ChatConversationSettings(contextWindowPercent: 50),
            policy: .standard
        )
        XCTAssertEqual(half.inputTokenLimit, 128_000 / 2 - 4_096)

        let tooHigh = ContextBudget(model: .openAI(.gpt4o_mini), settings: ChatConversationSettings(contextWindowPercent: 250), policy: .standard)
        XCTAssertEqual(tooHigh.windowPercent, 100)
        let tooLow = ContextBudget(model: .openAI(.gpt4o_mini), settings: ChatConversationSettings(contextWindowPercent: 0), policy: .standard)
        XCTAssertEqual(tooLow.windowPercent, 1)
    }

    func testModelsWithoutAPublishedWindowUseThePolicyFallback() {
        let budget = ContextBudget(model: unknownWindowModel, settings: .default, policy: testPolicy(window: 10_000))
        XCTAssertFalse(budget.isContextWindowKnown)
        XCTAssertEqual(budget.contextWindowTokens, 10_000)
        XCTAssertEqual(budget.inputTokenLimit, 10_000)
        XCTAssertEqual(budget.tokens(atPercent: 80), 8_000)
    }
}

final class CompactionPolicyTests: XCTestCase {
    func testMissingFieldsDecodeAsDefaults() throws {
        let decoded = try JSONDecoder().decode(CompactionPolicy.self, from: Data(#"{"triggerPercent": 70}"#.utf8))
        var expected = CompactionPolicy.standard
        expected.triggerPercent = 70
        XCTAssertEqual(decoded, expected)
        XCTAssertEqual(try JSONDecoder().decode(CompactionPolicy.self, from: Data("{}".utf8)), .standard)
    }

    func testRoundTripsThroughJSON() throws {
        let policy = CompactionPolicy(isEnabled: false, triggerPercent: 90, targetPercent: 60, summaryModelIdentifier: "openai/gpt-4o-mini")
        let data = try JSONEncoder().encode(policy)
        XCTAssertEqual(try JSONDecoder().decode(CompactionPolicy.self, from: data), policy)
    }

    func testNormalizedKeepsTheTargetBelowTheTrigger() {
        let wild = CompactionPolicy(
            triggerPercent: 500,
            targetPercent: 400,
            minimumRecentTurns: -3,
            summaryTokenLimit: 0,
            reservedResponseTokens: -1,
            fallbackContextWindowTokens: 10,
            summaryModelIdentifier: ""
        ).normalized
        XCTAssertEqual(wild.triggerPercent, 100)
        XCTAssertEqual(wild.targetPercent, 95)
        XCTAssertEqual(wild.minimumRecentTurns, 0)
        XCTAssertEqual(wild.summaryTokenLimit, 64)
        XCTAssertEqual(wild.reservedResponseTokens, 0)
        XCTAssertEqual(wild.fallbackContextWindowTokens, 1_024)
        XCTAssertNil(wild.summaryModelIdentifier)

        XCTAssertEqual(CompactionPolicy(triggerPercent: 1, targetPercent: 1).normalized.targetPercent, 5)
    }
}
