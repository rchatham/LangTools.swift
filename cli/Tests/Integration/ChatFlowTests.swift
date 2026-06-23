//
//  ChatFlowTests.swift
//  CLITests
//
//  Integration tests for chat message flow and command parsing
//

import XCTest
@testable import CLI
import Ollama
import Foundation

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

    func testHelpTextDeduplicatesExitAlias() {
        let helpText = CommandParser.helpText()
        XCTAssertEqual(helpText.components(separatedBy: "/exit").count - 1, 1)
        XCTAssertNotNil(CommandParser.commandType(for: "quit"))
        XCTAssertTrue(CommandParser.helpText(for: "quit").contains("Usage: /exit"))
    }

    func testHelpTextFormatsOllamaCommandCleanly() {
        let helpText = CommandParser.helpText()
        XCTAssertTrue(helpText.contains("/ollama <subcommand> [name]"))
        XCTAssertTrue(helpText.contains("/ollama <subcommand> [name] Manage local Ollama models"))
    }

    func testCommandSpecificHelpIncludesExamples() {
        let helpText = CommandParser.helpText(for: "ollama")

        XCTAssertTrue(helpText.contains("Examples:"))
        XCTAssertTrue(helpText.contains("/ollama list"))
        XCTAssertTrue(helpText.contains("/ollama pull llama3.2:latest"))
    }

    func testPrintUsageUsesSharedCommandHelp() {
        let output = try! runCLI(arguments: ["--help"])

        XCTAssertTrue(output.contains("COMMANDS (in chat)"))
        XCTAssertTrue(output.contains("/help [command]"))
        XCTAssertTrue(output.contains("/ollama <subcommand> [name]"))
    }

    func testNonInteractiveCommandAllowlist() {
        XCTAssertTrue(CLI.isCommandSupportedInNonInteractiveMode(SlashCommand(name: "help", arguments: [], rawArguments: ""), type: .help))
        XCTAssertTrue(CLI.isCommandSupportedInNonInteractiveMode(SlashCommand(name: "status", arguments: [], rawArguments: ""), type: .status))
        XCTAssertTrue(CLI.isCommandSupportedInNonInteractiveMode(SlashCommand(name: "ollama", arguments: ["list"], rawArguments: "list"), type: .ollama))

        XCTAssertFalse(CLI.isCommandSupportedInNonInteractiveMode(SlashCommand(name: "model", arguments: [], rawArguments: ""), type: .model))
        XCTAssertFalse(CLI.isCommandSupportedInNonInteractiveMode(SlashCommand(name: "apikey", arguments: ["openai"], rawArguments: "openai"), type: .apikey))
        XCTAssertFalse(CLI.isCommandSupportedInNonInteractiveMode(SlashCommand(name: "ollama", arguments: ["pull", "llama3.2"], rawArguments: "pull llama3.2"), type: .ollama))
    }

    func testPipedHelpOmitsInteractivePrompt() throws {
        let output = try runCLI(input: "/help\n")
        XCTAssertTrue(output.contains("Available Commands:"))
        XCTAssertFalse(output.contains("You:"))
    }

    func testPipedInteractiveOnlyCommandShowsFriendlyError() throws {
        let output = try runCLI(input: "/model\n")
        XCTAssertTrue(output.contains("/model is only available in interactive mode."))
        XCTAssertFalse(output.contains("You:"))
    }

    func testModelCapabilitiesForOllamaShowLimitedToolReliability() {
        let capabilities = Model.ollama(Ollama.Model(rawValue: "llama3.2:latest")!).capabilities

        XCTAssertTrue(capabilities.supportsTools)
        XCTAssertEqual(capabilities.toolReliability, .limited)
        XCTAssertFalse(capabilities.isRecommendedForTools)
        XCTAssertEqual(capabilities.cautionText, "Local/Ollama models may be unreliable for tool-heavy tasks")
    }

    func testModelCapabilitiesForGeminiReportUnavailableTools() {
        let capabilities = Model.gemini(.gemini3Flash).capabilities

        XCTAssertFalse(capabilities.supportsTools)
        XCTAssertEqual(capabilities.toolReliability, .unavailable)
        XCTAssertFalse(capabilities.supportsStructuredOutput)
        XCTAssertEqual(capabilities.cautionText, "Tool calling is not currently available for this model in the CLI")
    }

    func testStatusLinesIncludeCapabilities() {
        let lines = CLI.statusLines(model: .ollama(Ollama.Model(rawValue: "llama3.2:latest")!)).joined(separator: "\n")

        XCTAssertTrue(lines.contains("Capabilities:"))
        XCTAssertTrue(lines.contains("Provider:    Ollama"))
        XCTAssertTrue(lines.contains("Tool reliability:   limited"))
        XCTAssertTrue(lines.contains("Recommended tools:"))
        XCTAssertTrue(lines.contains("Structured output:"))
        XCTAssertTrue(lines.contains("Local/Ollama models may be unreliable for tool-heavy tasks"))
    }

    func testToolRegistryProvidesExecutableCallbacks() {
        let tool = ToolRegistry.shared.asOpenAITools().first { $0.name == "Read" }

        XCTAssertNotNil(tool)
        XCTAssertNotNil(tool?.callback)
    }

    func testFallbackMessageForUnknownToolName() {
        let trace = MessageService.ToolCallTrace()
        trace.calledToolNames = ["Available Tools"]

        let message = MessageService().fallbackMessageForEmptyAssistantResponse(
            toolTrace: trace,
            model: .ollama(Ollama.Model(rawValue: "llama3.2:latest")!)
        )

        XCTAssertEqual(message, "The model requested unsupported tool 'Available Tools'. Try rephrasing or switching models.")
    }

    func testFallbackMessageForMalformedToolArguments() {
        let trace = MessageService.ToolCallTrace()
        trace.calledToolNames = ["Read"]
        trace.errorResults = ["Failed to decode function arguments: {not-json}"]

        let message = MessageService().fallbackMessageForEmptyAssistantResponse(
            toolTrace: trace,
            model: .openAI(.gpt4o_mini)
        )

        XCTAssertEqual(message, "The model emitted malformed tool arguments. Failed to decode function arguments: {not-json}")
    }

    func testFallbackMessageForLimitedModelEmptyToolReply() {
        let trace = MessageService.ToolCallTrace()
        trace.calledToolNames = ["Read"]

        let message = MessageService().fallbackMessageForEmptyAssistantResponse(
            toolTrace: trace,
            model: .ollama(Ollama.Model(rawValue: "llama3.2:latest")!)
        )

        XCTAssertEqual(message, "The model attempted a tool call but did not produce a usable reply. Local/Ollama models may be unreliable for tool-heavy tasks.")
    }

    func testToolAvailabilityDecisionDisablesUnavailableTools() {
        let tool = ToolRegistry.shared.asOpenAITools().first!
        let decision = MessageService().toolAvailabilityDecision(
            for: .gemini(.gemini3Flash),
            tools: [tool],
            toolChoice: .auto
        )

        XCTAssertNil(decision.tools)
        XCTAssertNil(decision.toolChoice)
        XCTAssertEqual(decision.warning, "Warning: Tool calling is not currently available for this model in the CLI. Continuing without tools.")
    }

    func testToolAvailabilityDecisionWarnsForLimitedModels() {
        let tool = ToolRegistry.shared.asOpenAITools().first!
        let decision = MessageService().toolAvailabilityDecision(
            for: .ollama(Ollama.Model(rawValue: "llama3.2:latest")!),
            tools: [tool],
            toolChoice: .auto
        )

        XCTAssertNotNil(decision.tools)
        if case .auto? = decision.toolChoice {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected automatic tool choice for limited models")
        }
        XCTAssertEqual(decision.warning, "Warning: This model may be unreliable for tool-heavy tasks.")
    }

    func testEmitToolWarningInSilentModeAddsSystemMessageOnce() {
        let service = MessageService()
        let model = Model.ollama(Ollama.Model(rawValue: "llama3.2:latest")!)
        let warning = "Warning: This model may be unreliable for tool-heavy tasks."

        service.emitToolWarningIfNeeded(warning, model: model, silent: true)
        service.emitToolWarningIfNeeded(warning, model: model, silent: true)

        let warningMessages = service.messages.filter { $0.role == .system && $0.text == warning }
        XCTAssertEqual(warningMessages.count, 1)
    }

    func testMissingProviderMessageForOpenAIModel() {
        let lines = MessageService().missingProviderMessageLines(for: .openAI(.gpt5_2)).joined(separator: "\n")

        XCTAssertTrue(lines.contains("No configured provider could handle the current model 'gpt-5.2'."))
        XCTAssertTrue(lines.contains("OPENAI_API_KEY"))
        XCTAssertTrue(lines.contains("Use /status to inspect configuration or /model to switch models."))
    }

    func testOllamaRequestUsesOllamaChatRequest() {
        let messages = [Message(text: "hi", role: .user)]
        let request = NetworkClient.shared.request(
            messages: messages,
            model: .ollama(Ollama.Model(rawValue: "mistral:latest")!),
            stream: true,
            tools: nil,
            toolChoice: nil
        )

        guard let ollamaRequest = request as? Ollama.ChatRequest else {
            return XCTFail("Expected Ollama.ChatRequest for Ollama models")
        }

        XCTAssertEqual(ollamaRequest.model.rawValue, "mistral:latest")
        XCTAssertEqual(ollamaRequest.messages.count, 1)
        XCTAssertEqual(ollamaRequest.messages.first?.content.text, "hi")
        XCTAssertEqual(ollamaRequest.messages.first?.role, .user)
        XCTAssertEqual(ollamaRequest.stream, true)
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
        XCTAssertTrue(fullHelp.contains("LangTools CLI Help"))
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

    private func runCLI(input: String) throws -> String {
        let process = Process()
        process.currentDirectoryURL = URL(fileURLWithPath: packageDirectory())
        process.executableURL = URL(fileURLWithPath: executablePath())

        let stdout = Pipe()
        let stdin = Pipe()
        process.standardOutput = stdout
        process.standardError = stdout
        process.standardInput = stdin

        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }

    private func packageDirectory(file: StaticString = #filePath) -> String {
        URL(fileURLWithPath: String(describing: file))
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
    }

    private func executablePath() -> String {
        let packageURL = URL(fileURLWithPath: packageDirectory())
        return packageURL.appendingPathComponent(".build/arm64-apple-macosx/debug/langtools").path
    }
}
