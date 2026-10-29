import XCTest
import LangTools
@testable import AppleLangTools

final class AppleIntelligenceTests: XCTestCase {
    private typealias Message = AppleIntelligence.Message

    func testTranscriptPlanSplitsInstructionsHistoryAndPrompt() throws {
        let plan = try AppleIntelligence.transcriptPlan(for: [
            Message(role: .system, string: "Be brief."),
            Message(role: .user, string: "Hi"),
            Message(role: .assistant, string: "Hello!"),
            Message(role: .system, string: "Use metric units."),
            Message(role: .user, string: "How tall is Everest?"),
        ])

        XCTAssertEqual(plan.instructions, "Be brief.\n\nUse metric units.")
        XCTAssertEqual(plan.history, [.user("Hi"), .assistant("Hello!")])
        XCTAssertEqual(plan.prompt, "How tall is Everest?")
    }

    func testTranscriptPlanDropsTurnsAfterFinalUserMessageAndEmptyText() throws {
        let plan = try AppleIntelligence.transcriptPlan(for: [
            Message(role: .user, string: "First"),
            Message(role: .assistant, string: ""),
            Message(role: .user, string: "Second"),
            Message(role: .assistant, string: "dangling draft"),
        ])

        XCTAssertNil(plan.instructions)
        XCTAssertEqual(plan.history, [.user("First")])
        XCTAssertEqual(plan.prompt, "Second")
    }

    func testHistoryWindowDropsOldestTurnsAndStartsOnUserTurn() {
        // ~1,380 tokens per long turn against a ~3,060-token history budget:
        // a3, q3, and a2 fit, q2 does not, so the orphaned a2 is trimmed too.
        let long = String(repeating: "word ", count: 1_100)
        let turns: [AppleIntelligence.TranscriptPlan.Turn] = [
            .user("q1 " + long), .assistant("a1 " + long),
            .user("q2 " + long), .assistant("a2 " + long),
            .user("q3 short"), .assistant("a3 " + long),
        ]

        XCTAssertEqual(AppleIntelligence.historyWindow(turns, prompt: "Next?", instructions: ""), Array(turns.suffix(2)))
    }

    func testHistoryWindowReturnsEmptyWhenInstructionsAndPromptExhaustBudget() {
        let huge = String(repeating: "word ", count: 4_000)
        XCTAssertEqual(AppleIntelligence.historyWindow([.user("Hi"), .assistant("Hello")], prompt: huge, instructions: ""), [])
    }

    func testStreamDeltaEmitsOnlyNewTextAndNeverResendsEmittedText() {
        XCTAssertEqual(AppleIntelligence.streamDelta(emitted: "", snapshot: "Hel"), "Hel")
        XCTAssertEqual(AppleIntelligence.streamDelta(emitted: "Hel", snapshot: "Hello"), "lo")
        XCTAssertEqual(AppleIntelligence.streamDelta(emitted: "Hello", snapshot: "Hello"), "")
        // A snapshot that rewrites earlier text only contributes its new tail.
        XCTAssertEqual(AppleIntelligence.streamDelta(emitted: "Hello", snapshot: "Howdy there"), " there")
        XCTAssertEqual(AppleIntelligence.streamDelta(emitted: "Hello there", snapshot: "Hi"), "")
    }

    func testProviderErrorDetectionMatchesOnlyAppleErrors() {
        XCTAssertTrue(AppleIntelligence.isProviderError(AppleIntelligenceError.unavailable(.modelNotReady)))
        XCTAssertFalse(AppleIntelligence.isProviderError(LangToolsError.requestFailed))
        XCTAssertFalse(AppleIntelligence.isProviderError(URLError(.timedOut)))
    }

    func testTranscriptPlanRequiresAUserMessage() {
        XCTAssertThrowsError(try AppleIntelligence.transcriptPlan(for: [Message(role: .system, string: "Only instructions")])) {
            XCTAssertEqual($0 as? AppleIntelligenceError, .missingPrompt)
        }
    }

    func testToolchainRoutesChatRequestsToAppleIntelligence() throws {
        var toolchain = LangToolchain()
        toolchain.register(AppleIntelligence())
        let request = AppleIntelligence.ChatRequest(model: .onDevice, messages: [Message(role: .user, string: "Hi")])

        XCTAssertTrue(AppleIntelligence().canHandleRequest(request))
        // Apple Intelligence never produces HTTP requests.
        XCTAssertThrowsError(try toolchain.prepare(request: request)) {
            XCTAssertEqual($0 as? AppleIntelligenceError, .notAnHTTPProvider)
        }
    }

    func testChatRequestFactoryRejectsUnsupportedFeatures() {
        let messages: [any LangToolsMessage] = [Message(role: .user, string: "Hi")]
        XCTAssertNoThrow(try AppleIntelligence.chatRequest(model: AppleIntelligence.Model.onDevice, messages: messages, tools: nil, responseSchema: nil, toolEventHandler: { _ in }))
        XCTAssertThrowsError(try AppleIntelligence.chatRequest(model: AppleIntelligence.Model.onDevice, messages: messages, tools: nil, responseSchema: JSONSchema.object(properties: [:]), toolEventHandler: { _ in })) {
            XCTAssertEqual($0 as? AppleIntelligenceError, .structuredOutputUnsupported)
        }
    }

    func testUnavailableOSReportsUnsupportedAndFailsRequests() async throws {
        try XCTSkipIf(AppleIntelligence.isSupportedOnThisOS, "Foundation Models is present on this OS")
        XCTAssertEqual(AppleIntelligence.availability, .unavailable(.unsupportedOS))

        let request = AppleIntelligence.ChatRequest(model: .onDevice, messages: [Message(role: .user, string: "Hi")])
        do {
            _ = try await AppleIntelligence().perform(request: request)
            XCTFail("Expected unsupported OS error")
        } catch {
            XCTAssertEqual(error as? AppleIntelligenceError, .unavailable(.unsupportedOS))
        }
    }

    /// Live generation; runs only where Apple Intelligence is enabled and ready.
    func testLiveStreamingGeneration() async throws {
        try XCTSkipUnless(AppleIntelligence.availability == .available, "Apple Intelligence model is not available here")
        let request = AppleIntelligence.ChatRequest(
            model: .onDevice,
            messages: [Message(role: .user, string: "Reply with the single word: pong")],
            stream: true,
            maximumResponseTokens: 16
        )
        var text = ""
        for try await chunk in AppleIntelligence().stream(request: request) {
            text += chunk.delta?.content ?? ""
        }
        XCTAssertFalse(text.isEmpty)
    }
}
