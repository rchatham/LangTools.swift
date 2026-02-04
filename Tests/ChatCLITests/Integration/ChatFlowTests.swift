//
//  ChatFlowTests.swift
//  ChatCLITests
//
//  Integration tests for chat message flow and command parsing
//

import XCTest
@testable import ChatCLI

final class ChatFlowTests: XCTestCase {

    // MARK: - Command Parser Integration Tests

    func testCommandParserRecognizesAllCommands() {
        let commands = ["help", "clear", "exit", "quit", "save", "load", "sessions",
                        "model", "tools", "status", "compact", "plan", "tasks", "cancel"]

        for command in commands {
            let result = CommandParser.parse("/\(command)")
            if case .command(let slashCommand) = result {
                XCTAssertEqual(slashCommand.name, command, "Command /\(command) should be recognized")
            } else {
                XCTFail("Expected command type for /\(command)")
            }
        }
    }

    func testCommandParserHandlesArguments() {
        let result = CommandParser.parse("/load session123")
        if case .command(let slashCommand) = result {
            XCTAssertEqual(slashCommand.name, "load")
            XCTAssertEqual(slashCommand.rawArguments, "session123")
            XCTAssertEqual(slashCommand.arguments.first, "session123")
        } else {
            XCTFail("Expected command with arguments")
        }
    }

    func testCommandParserDistinguishesMessagesFromCommands() {
        // Regular message
        let message = CommandParser.parse("Hello, how are you?")
        if case .message(let text) = message {
            XCTAssertEqual(text, "Hello, how are you?")
        } else {
            XCTFail("Expected message type")
        }

        // Command with slash
        let command = CommandParser.parse("/help")
        if case .command(let slashCommand) = command {
            XCTAssertEqual(slashCommand.name, "help")
        } else {
            XCTFail("Expected command type")
        }
    }

    func testCommandParserHandlesEmptyInput() {
        let result = CommandParser.parse("")
        if case .empty = result {
            // Expected
        } else {
            XCTFail("Expected empty type for empty input")
        }
    }

    func testCommandParserHandlesUnknownCommands() {
        // Unknown commands still parse as commands, but commandType returns nil
        let result = CommandParser.parse("/unknowncommand")
        if case .command(let slashCommand) = result {
            XCTAssertEqual(slashCommand.name, "unknowncommand")
            XCTAssertNil(CommandParser.commandType(for: slashCommand.name))
        } else {
            XCTFail("Expected command type for unknown command")
        }
    }

    func testCommandTypeReturnsCorrectDescription() {
        XCTAssertEqual(CommandType.help.description, "Show available commands")
        XCTAssertEqual(CommandType.clear.description, "Clear the chat history")
        XCTAssertEqual(CommandType.exit.description, "Exit the application")
    }

    func testCommandTypeReturnsCorrectUsage() {
        XCTAssertEqual(CommandType.help.usage, "/help [command]")
        XCTAssertEqual(CommandType.load.usage, "/load <session-id>")
        XCTAssertEqual(CommandType.model.usage, "/model [model-name]")
    }

    // MARK: - Session Manager Integration Tests

    func testSessionManagerCreatesSession() {
        let manager = SessionManager.shared
        let session = manager.createSession(
            name: "Test Session",
            workingDirectory: "/tmp",
            model: "test-model"
        )

        XCTAssertEqual(session.name, "Test Session")
        XCTAssertEqual(session.metadata.workingDirectory, "/tmp")
        XCTAssertEqual(session.metadata.model, "test-model")
        XCTAssertTrue(session.messages.isEmpty)
    }

    func testSessionManagerSavesAndLoadsSession() throws {
        let manager = SessionManager.shared
        let session = manager.createSession(
            name: "Persistence Test",
            workingDirectory: "/tmp",
            model: "test-model"
        )

        // Save and load
        try manager.saveSession(session)
        let loaded = try manager.loadSession(id: session.id)

        XCTAssertEqual(loaded.name, "Persistence Test")
        XCTAssertEqual(loaded.metadata.workingDirectory, "/tmp")

        // Cleanup
        try manager.deleteSession(id: session.id)
    }

    // MARK: - Context Manager Integration Tests

    func testContextManagerTokenEstimation() {
        let manager = ContextManager.shared

        // Test basic estimation (approximately 4 chars per token)
        let shortText = "Hello"
        let shortTokens = manager.estimateTokens(shortText)
        XCTAssertGreaterThan(shortTokens, 0)

        let longText = String(repeating: "word ", count: 1000)
        let longTokens = manager.estimateTokens(longText)
        XCTAssertGreaterThan(longTokens, shortTokens)
    }

    func testContextManagerCompactionThreshold() {
        let manager = ContextManager.shared

        // Create messages that don't exceed threshold
        let smallMessages = [
            ChatMessage(role: .user, content: "Hello"),
            ChatMessage(role: .assistant, content: "Hi there!")
        ]
        XCTAssertFalse(manager.needsCompaction(messages: smallMessages))
    }

    // MARK: - Todo Manager Integration Tests

    @MainActor
    func testTodoManagerAddAndComplete() {
        let manager = TodoManager.shared

        // Clear existing todos
        manager.setTodos([])

        // Add a todo
        let todo = TodoItem(content: "Test task", status: .pending, activeForm: "Testing task")
        manager.setTodos([todo])

        XCTAssertEqual(manager.todos.count, 1)
        XCTAssertEqual(manager.todos.first?.content, "Test task")
        XCTAssertEqual(manager.todos.first?.status, .pending)

        // Update status
        if let id = manager.todos.first?.id {
            manager.updateStatus(id: id, status: .completed)
            XCTAssertEqual(manager.todos.first?.status, .completed)
        }

        // Cleanup
        manager.setTodos([])
    }

    @MainActor
    func testTodoManagerProgressSummary() {
        let manager = TodoManager.shared
        manager.setTodos([])

        let todos = [
            TodoItem(content: "Task 1", status: .completed, activeForm: "Task 1"),
            TodoItem(content: "Task 2", status: .completed, activeForm: "Task 2"),
            TodoItem(content: "Task 3", status: .inProgress, activeForm: "Task 3"),
            TodoItem(content: "Task 4", status: .pending, activeForm: "Task 4"),
        ]
        manager.setTodos(todos)

        let summary = manager.progressSummary
        XCTAssertTrue(summary.contains("2/4"))  // 2 completed of 4 total
        XCTAssertTrue(summary.contains("1 in progress"))
        XCTAssertTrue(summary.contains("1 pending"))

        // Cleanup
        manager.setTodos([])
    }

    @MainActor
    func testTodoManagerCurrentTask() {
        let manager = TodoManager.shared
        manager.setTodos([])

        let todos = [
            TodoItem(content: "Task 1", status: .completed, activeForm: "Task 1"),
            TodoItem(content: "Task 2", status: .inProgress, activeForm: "Doing Task 2"),
            TodoItem(content: "Task 3", status: .pending, activeForm: "Task 3"),
        ]
        manager.setTodos(todos)

        let currentTask = manager.currentTask
        XCTAssertNotNil(currentTask)
        XCTAssertEqual(currentTask?.content, "Task 2")
        XCTAssertEqual(currentTask?.activeForm, "Doing Task 2")

        // Cleanup
        manager.setTodos([])
    }

    // MARK: - Help System Integration Tests

    func testHelpSystemGeneratesContent() {
        let fullHelp = HelpSystem.fullHelp()
        XCTAssertTrue(fullHelp.contains("ChatCLI Help"))
        XCTAssertTrue(fullHelp.contains("KEYBOARD SHORTCUTS"))
        XCTAssertTrue(fullHelp.contains("TOOL USAGE"))

        let quickRef = HelpSystem.quickReference()
        XCTAssertTrue(quickRef.contains("/help"))
        XCTAssertTrue(quickRef.contains("/exit"))

        let gettingStarted = HelpSystem.gettingStarted()
        XCTAssertTrue(gettingStarted.contains("Getting Started"))
    }

    func testHelpSystemToolDocumentation() {
        let tools = ["read", "write", "edit", "bash", "glob", "grep"]

        for tool in tools {
            let help = HelpSystem.toolHelp(for: tool)
            XCTAssertFalse(help.contains("Unknown tool"), "Tool \(tool) should have documentation")
        }
    }

    // MARK: - Error Formatter Integration Tests

    func testErrorFormatterHandlesNetworkErrors() {
        let error = NetworkError.timeout(url: "https://example.com")
        let formatted = ErrorFormatter.format(error)

        XCTAssertTrue(formatted.contains("timed out"))
        XCTAssertTrue(formatted.contains("example.com"))
    }

    func testErrorFormatterHandlesConfigurationErrors() {
        let error = ConfigurationError.missingApiKey(provider: "OpenAI")
        let formatted = ErrorFormatter.format(error)

        XCTAssertTrue(formatted.contains("Missing API key"))
        XCTAssertTrue(formatted.contains("OpenAI"))
        XCTAssertTrue(formatted.contains("Suggestion"))
    }

    func testErrorFormatterHandlesInputErrors() {
        let error = InputError.invalidCommand(name: "foo")
        let formatted = ErrorFormatter.format(error)

        XCTAssertTrue(formatted.contains("Unknown command"))
        XCTAssertTrue(formatted.contains("/foo"))
    }
}
