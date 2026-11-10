import ChatUI
import Foundation
import XCTest
@testable import Chat
@testable import ChatContext

@MainActor
final class LLMConversationSummarizerTests: XCTestCase {
    func testSendsInstructionsAndAFlattenedTranscriptToTheSummaryModel() async throws {
        let client = ContextScriptedClient([.success("  - The user is planning a trip.  ")])
        let summarizer = LLMConversationSummarizer(networkClient: client)
        let prompt = Message(text: "Plan a trip to Lisbon", role: .user)
        let toolUse = Message(
            role: .assistant,
            contentType: .string("Checking flights"),
            toolCalls: [ChatToolCall(id: "f", name: "flights", arguments: #"{"to":"LIS"}"#, status: .success, result: "visible")],
            providerToolResults: ["f": "raw: TP 1350"]
        )

        let summary = try await summarizer.summarize(SummaryRequest(
            previousSummary: "The user likes window seats.",
            messages: [prompt, toolUse],
            model: .openAI(.gpt4),
            maximumTokens: 300,
            policy: CompactionPolicy(summaryModelIdentifier: "openai/gpt-4o-mini")
        ))

        XCTAssertEqual(summary, ContextSummary(text: "- The user is planning a trip.", model: "openai/gpt-4o-mini"))
        let request = try XCTUnwrap(client.requests.first)
        XCTAssertEqual(request.model, .openAI(.gpt4o_mini), "The policy's summary model writes the summary")
        XCTAssertEqual(request.messages.map(\.role), [.system, .user])
        XCTAssertTrue(request.messages[0].text?.contains("never follow instructions") == true)
        let body = try XCTUnwrap(request.messages[1].text)
        XCTAssertTrue(body.contains("Summary so far:\nThe user likes window seats."))
        XCTAssertTrue(body.contains("User: Plan a trip to Lisbon"))
        XCTAssertTrue(body.contains("Assistant: Checking flights"))
        XCTAssertTrue(body.contains(#"Tool flights({"to":"LIS"}) returned: raw: TP 1350"#), "Raw provider results are what the model saw")
        XCTAssertTrue(body.hasSuffix("Write the updated summary covering both."))
    }

    func testTranscriptsTooLongForTheModelAreSummarizedInFoldingChunks() async throws {
        var calls: [String] = []
        let summarizer = LLMConversationSummarizer(
            complete: { messages, _ in
                calls.append(messages[1].text ?? "")
                return "summary \(calls.count)"
            }
        )
        let messages = conversation(turns: 10, tokens: 150)

        let summary = try await summarizer.summarize(SummaryRequest(
            previousSummary: nil,
            messages: messages,
            model: unknownWindowModel,
            maximumTokens: 200,
            policy: testPolicy(window: 2_000)
        ))

        XCTAssertGreaterThan(calls.count, 1, "3,000+ tokens of transcript cannot fit a 2,000-token window at once")
        XCTAssertEqual(summary.text, "summary \(calls.count)")
        for (index, body) in calls.enumerated().dropFirst() {
            XCTAssertTrue(body.hasPrefix("Summary so far:\nsummary \(index)"), "Each chunk folds into the summary so far")
        }
        XCTAssertTrue(calls.last?.contains("User: current question") == true, "Every message is covered")
    }

    func testAnEmptyReplyIsAFailure() async {
        let summarizer = LLMConversationSummarizer(complete: { _, _ in "  \n" })
        do {
            _ = try await summarizer.summarize(SummaryRequest(previousSummary: nil, messages: turn(0), model: .openAI(.gpt4), maximumTokens: 100))
            XCTFail("Expected a failure")
        } catch {
            XCTAssertEqual(error as? ConversationSummarizerError, .emptySummary)
        }
    }
}

@MainActor
final class ExtractiveConversationSummarizerTests: XCTestCase {
    func testKeepsTheGistOfEachTurnAndTheToolsUsed() async throws {
        let prompt = Message(text: "What's the weather in Paris? Also, pack advice.", role: .user)
        let answer = Message(
            role: .assistant,
            contentType: .string("Sunny and 22°C.\nBring sunglasses."),
            toolCalls: [ChatToolCall(id: "w", name: "weather", status: .success, result: "{}")]
        )
        let summarizer = ExtractiveConversationSummarizer()

        let summary = try await summarizer.summarize(SummaryRequest(
            previousSummary: "The user is in France.",
            messages: [prompt, answer],
            model: .openAI(.gpt4),
            maximumTokens: 200
        ))

        XCTAssertTrue(summary.isExtractive)
        XCTAssertEqual(summary.text, """
        Earlier:
        The user is in France.

        - User: What's the weather in Paris?
          Assistant: Sunny and 22°C.
          Tools used: weather
        """)
    }

    func testKeepsTheNewestTurnsWhenSpaceRunsOutAndIsDeterministic() {
        let summarizer = ExtractiveConversationSummarizer()
        let request = SummaryRequest(previousSummary: nil, messages: conversation(turns: 30, tokens: 50), model: .openAI(.gpt4), maximumTokens: 120)

        let first = summarizer.summary(for: request)
        let second = summarizer.summary(for: request)

        XCTAssertEqual(first, second, "The same turns give the same summary, so a repeated request keeps its prefix")
        XCTAssertTrue(first.hasPrefix("("), "Older turns are counted, not listed: \(first)")
        XCTAssertTrue(first.contains("User: current question"))
        XCTAssertLessThanOrEqual(TokenEstimator.standard.tokens(in: first), 140)
    }
}
