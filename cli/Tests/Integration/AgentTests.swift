//
//  AgentTests.swift
//  CLITests
//
//  Integration tests for agent spawning and lifecycle
//

import XCTest
@testable import CLI

final class AgentTests: XCTestCase {

    // MARK: - Agent Type Tests

    func testAgentTypeDefinitions() {
        // Verify all agent types exist and have proper names
        let types: [AgentType] = [.explore, .plan, .general, .bash]

        for type in types {
            XCTAssertFalse(type.rawValue.isEmpty)
            XCTAssertFalse(type.description.isEmpty)
        }
    }

    func testAgentTypeToolPermissions() {
        // Explore agent should be read-only
        let exploreTools = AgentType.explore.tools
        XCTAssertTrue(exploreTools.contains("read"))
        XCTAssertTrue(exploreTools.contains("glob"))
        XCTAssertTrue(exploreTools.contains("grep"))
        XCTAssertFalse(exploreTools.contains("write"))
        XCTAssertFalse(exploreTools.contains("bash"))

        // Plan agent should also be read-only
        let planTools = AgentType.plan.tools
        XCTAssertTrue(planTools.contains("read"))
        XCTAssertFalse(planTools.contains("write"))

        // General agent should have full access
        let generalTools = AgentType.general.tools
        XCTAssertTrue(generalTools.contains("read"))
        XCTAssertTrue(generalTools.contains("write"))
        XCTAssertTrue(generalTools.contains("bash"))

        // Bash agent focused on command execution
        let bashTools = AgentType.bash.tools
        XCTAssertTrue(bashTools.contains("bash"))
    }

    func testAgentTypeRawValues() {
        XCTAssertEqual(AgentType.explore.rawValue, "Explore")
        XCTAssertEqual(AgentType.plan.rawValue, "Plan")
        XCTAssertEqual(AgentType.general.rawValue, "general-purpose")
        XCTAssertEqual(AgentType.bash.rawValue, "Bash")
    }

    // MARK: - Agent Task Tests

    func testAgentTaskCreation() {
        let task = AgentTask(
            id: "test-123",
            agentType: .explore,
            prompt: "Find all Swift files",
            description: "Test exploration task",
            status: .pending
        )

        XCTAssertEqual(task.id, "test-123")
        XCTAssertEqual(task.agentType, .explore)
        XCTAssertEqual(task.prompt, "Find all Swift files")
        XCTAssertEqual(task.description, "Test exploration task")
        XCTAssertEqual(task.status, .pending)
        XCTAssertNil(task.result)
        XCTAssertNil(task.error)
    }

    func testAgentTaskStatusValues() {
        // Verify all status values exist
        let statuses: [AgentTask.TaskStatus] = [.pending, .running, .completed, .failed, .cancelled]
        XCTAssertEqual(statuses.count, 5)
    }

    func testAgentTaskDuration() {
        var task = AgentTask(
            id: "test-123",
            agentType: .explore,
            prompt: "Test",
            description: "Test",
            status: .pending
        )

        // No duration before start
        XCTAssertNil(task.duration)

        // Set start time
        task.startTime = Date()

        // Should have a small duration now
        if let duration = task.duration {
            XCTAssertGreaterThanOrEqual(duration, 0)
        }
    }

    // MARK: - Plan Mode Tests

    @MainActor
    func testPlanModeStateManagement() {
        let manager = PlanModeManager.shared

        // Reset to clean state
        manager.reset()

        // Initially not in plan mode
        XCTAssertFalse(manager.isInPlanMode)

        // Enter plan mode
        let planFile = manager.enterPlanMode()
        XCTAssertTrue(manager.isInPlanMode)
        XCTAssertFalse(planFile.isEmpty)
        XCTAssertTrue(planFile.contains("plan mode") || planFile.contains("Plan file"))

        // Exit plan mode
        let result = manager.exitPlanMode()
        if case .success(let request) = result {
            XCTAssertFalse(request.planFilePath.isEmpty)
        } else {
            XCTFail("Expected success result from exitPlanMode")
        }

        // Clean up
        manager.reset()
    }

    @MainActor
    func testPlanModeApprovalWorkflow() {
        let manager = PlanModeManager.shared

        // Reset to clean state
        manager.reset()

        // Enter plan mode
        _ = manager.enterPlanMode()
        XCTAssertEqual(manager.approvalStatus, .pending)

        // Exit should return with allowed prompts
        let result = manager.exitPlanMode(allowedPrompts: [
            AllowedPrompt(tool: "Bash", prompt: "run tests")
        ])

        if case .success(let request) = result {
            XCTAssertEqual(request.allowedPrompts.count, 1)
            XCTAssertEqual(request.allowedPrompts.first?.tool, "Bash")
        } else {
            XCTFail("Expected success result from exitPlanMode")
        }

        // Clean up
        manager.reset()
    }

    // MARK: - User Question Manager Tests

    @MainActor
    func testUserQuestionManagerInitialState() {
        let manager = UserQuestionManager.shared

        // Initially no current question (may have pending from previous tests)
        // Just verify the manager exists and we can access currentQuestion
        _ = manager.currentQuestion
        _ = manager.pendingQuestions
    }

    @MainActor
    func testQuestionOptionCreation() {
        let option = QuestionOption(label: "Option A", description: "First choice")
        XCTAssertEqual(option.label, "Option A")
        XCTAssertEqual(option.description, "First choice")
    }

    @MainActor
    func testUserQuestionCreation() {
        let question = UserQuestion(
            question: "Which option?",
            header: "Choice",
            options: [
                QuestionOption(label: "A", description: ""),
                QuestionOption(label: "B", description: "")
            ],
            multiSelect: false
        )

        XCTAssertEqual(question.question, "Which option?")
        XCTAssertEqual(question.header, "Choice")
        XCTAssertEqual(question.options.count, 2)
        XCTAssertFalse(question.multiSelect)
    }

    @MainActor
    func testUserQuestionMultiSelect() {
        let question = UserQuestion(
            question: "Select all",
            header: "Multi",
            options: [
                QuestionOption(label: "A", description: ""),
                QuestionOption(label: "B", description: ""),
                QuestionOption(label: "C", description: "")
            ],
            multiSelect: true
        )

        XCTAssertTrue(question.multiSelect)
        XCTAssertEqual(question.options.count, 3)
    }

    // MARK: - Progress Indicator Tests

    func testProgressIndicatorAdvance() {
        var spinner = ProgressIndicator(style: .spinner)
        let frame1 = spinner.advance()
        XCTAssertFalse(frame1.isEmpty)

        let frame2 = spinner.advance()
        XCTAssertFalse(frame2.isEmpty)
    }

    func testProgressIndicatorStyles() {
        var spinnerIndicator = ProgressIndicator(style: .spinner)
        var dotsIndicator = ProgressIndicator(style: .dots)
        var barIndicator = ProgressIndicator(style: .bar)
        var pulseIndicator = ProgressIndicator(style: .pulse)

        // Each style should produce output
        XCTAssertFalse(spinnerIndicator.advance().isEmpty)
        XCTAssertFalse(dotsIndicator.advance().isEmpty)
        XCTAssertFalse(barIndicator.advance().isEmpty)
        XCTAssertFalse(pulseIndicator.advance().isEmpty)
    }

    func testProgressIndicatorReset() {
        var indicator = ProgressIndicator(style: .spinner)

        // Advance a few times
        _ = indicator.advance()
        _ = indicator.advance()
        _ = indicator.advance()

        // Reset
        indicator.reset()

        // First frame after reset should be the first spinner character
        let frame = indicator.advance()
        XCTAssertEqual(frame, ProgressIndicator.spinnerFrames[0])
    }

    // MARK: - Status Message Tests

    func testStatusMessageCreation() {
        let infoMessage = StatusMessage("Info message", level: .info)
        XCTAssertEqual(infoMessage.message, "Info message")
        XCTAssertEqual(infoMessage.level, .info)

        let errorMessage = StatusMessage("Error message", level: .error)
        XCTAssertEqual(errorMessage.level, .error)
    }

    func testStatusMessageFormatted() {
        let successMessage = StatusMessage("Task completed", level: .success)
        let formatted = successMessage.formatted
        XCTAssertTrue(formatted.contains("✓"))
        XCTAssertTrue(formatted.contains("Task completed"))
    }

    func testStatusMessageFormattedWithTime() {
        let message = StatusMessage("Test message")
        let formatted = message.formattedWithTime
        XCTAssertTrue(formatted.contains("Test message"))
        // Should contain a time in format like [HH:mm:ss]
        XCTAssertTrue(formatted.contains("["))
        XCTAssertTrue(formatted.contains("]"))
    }

    // MARK: - Elapsed Time Formatter Edge Cases

    func testElapsedTimeFormatterZero() {
        let result = ElapsedTimeFormatter.format(0)
        // Should show 0ms for zero time
        XCTAssertTrue(result.contains("0"))
    }

    func testElapsedTimeFormatterEdgeCases() {
        // Just under a second
        let almostSecond = ElapsedTimeFormatter.format(0.999)
        XCTAssertTrue(almostSecond.contains("ms"))

        // Exactly one second
        let oneSecond = ElapsedTimeFormatter.format(1.0)
        XCTAssertTrue(oneSecond.contains("s"))

        // Exactly one minute
        let oneMinute = ElapsedTimeFormatter.format(60.0)
        XCTAssertTrue(oneMinute.contains("m"))
    }
}
