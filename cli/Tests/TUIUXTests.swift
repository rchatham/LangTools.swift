import XCTest
@testable import CLI

final class TUIUXTests: XCTestCase {
    func testToolDisplayEventsBecomeHierarchicalChatMessages() {
        let call = ChatMessage(toolEvent: .init(
            kind: .call,
            toolName: "read",
            detail: #"{"file_path":"README.md"}"#,
            selectionID: "call-1"
        ))
        let result = ChatMessage(toolEvent: .init(
            kind: .result(isError: true),
            toolName: "read",
            detail: "permission denied",
            selectionID: "call-1"
        ))

        XCTAssertEqual(call.role, .toolCall)
        XCTAssertEqual(call.toolName, "read")
        XCTAssertEqual(result.role, .toolResult)
        XCTAssertTrue(result.toolFailed)
    }

    func testParallelToolResultsAreGroupedUnderTheirCalls() {
        let events: [MessageService.ToolDisplayEvent] = [
            .init(kind: .call, toolName: "Read", detail: "a", selectionID: "a"),
            .init(kind: .call, toolName: "Read", detail: "b", selectionID: "b"),
            .init(kind: .result(isError: false), toolName: "Read", detail: "result b", selectionID: "b"),
            .init(kind: .result(isError: false), toolName: "Read", detail: "result a", selectionID: "a")
        ]

        let ordered = MessageService.hierarchicalToolEvents(events)

        XCTAssertEqual(ordered.map(\.detail), ["a", "result a", "b", "result b"])
    }

    func testToolMessagePreviewIsBoundedAndRetainsDetail() {
        let preview = ToolMessagePreview.lines(
            for: "line one\nline two\nline three",
            limit: 2,
            characterLimit: 100
        )

        XCTAssertEqual(preview, ["line one", "line two …"])
    }

    func testTUIQuestionHandlerAvoidsTerminalInput() async throws {
        let question = makeQuestion(multiSelect: true)
        await UserQuestionRouter.shared.removeTUIHandler()
        await UserQuestionRouter.shared.installTUIHandler { _ in "2, 1" }

        let result: String
        do {
            result = try await AskUserQuestionTool.collectAnswers(
                for: [question],
                isInteractive: false,
                lineReader: {
                    XCTFail("TUI question handling must not read stdin")
                    return nil
                }
            )
        } catch {
            await UserQuestionRouter.shared.removeTUIHandler()
            throw error
        }
        await UserQuestionRouter.shared.removeTUIHandler()

        XCTAssertEqual(result, "User answers:\nChoice: Option B, Option A")
    }

    func testTraditionalQuestionUsesTerminalFallback() async throws {
        let question = makeQuestion(multiSelect: false)
        await UserQuestionRouter.shared.removeTUIHandler()

        let result = try await AskUserQuestionTool.collectAnswers(
            for: [question],
            isInteractive: true,
            lineReader: { "2" }
        )

        XCTAssertEqual(result, "User answers:\nChoice: Option B")
    }

    @MainActor
    func testCLIInstalledQuestionHandlerUsesManager() async throws {
        let manager = UserQuestionManager.shared
        await CLI.removeTUIQuestionHandler()
        await CLI.installTUIQuestionHandler()
        let question = makeQuestion(multiSelect: false)

        let responseTask = Task {
            try await AskUserQuestionTool.collectAnswers(
                for: [question],
                isInteractive: false,
                lineReader: {
                    XCTFail("CLI-installed TUI handler must not read stdin")
                    return nil
                }
            )
        }
        for _ in 0..<100 where manager.currentQuestion == nil {
            await Task.yield()
        }

        guard manager.currentQuestion != nil else {
            await CLI.removeTUIQuestionHandler()
            _ = try await responseTask.value
            return XCTFail("CLI-installed handler did not reach UserQuestionManager")
        }
        manager.provideCustomAnswer("1")

        let response = try await responseTask.value
        await CLI.removeTUIQuestionHandler()
        XCTAssertEqual(response, "User answers:\nChoice: Option A")
    }

    @MainActor
    func testUserQuestionManagerQueuesConcurrentTUIQuestions() async {
        let manager = UserQuestionManager.shared
        manager.cancel()
        let first = makeQuestion(prompt: "First?", multiSelect: false)
        let second = makeQuestion(prompt: "Second?", multiSelect: false)

        let firstTask = Task { await manager.askQuestions([first]) }
        await Task.yield()
        let secondTask = Task { await manager.askQuestions([second]) }
        await Task.yield()

        XCTAssertEqual(manager.currentQuestion?.question, "First?")
        XCTAssertEqual(manager.pendingQuestions.map(\.question), ["First?", "Second?"])

        manager.provideCustomAnswer("first answer")
        let firstResponse = await firstTask.value
        XCTAssertEqual(firstResponse, "first answer")
        XCTAssertEqual(manager.currentQuestion?.question, "Second?")

        manager.provideCustomAnswer("second answer")
        let secondResponse = await secondTask.value
        XCTAssertEqual(secondResponse, "second answer")
        XCTAssertNil(manager.currentQuestion)
        XCTAssertTrue(manager.pendingQuestions.isEmpty)
    }

    private func makeQuestion(prompt: String = "Which option?", multiSelect: Bool) -> UserQuestion {
        UserQuestion(
            question: prompt,
            header: "Choice",
            options: [
                QuestionOption(label: "Option A", description: "First"),
                QuestionOption(label: "Option B", description: "Second"),
            ],
            multiSelect: multiSelect
        )
    }
}
