//
//  MainView.swift
//  ChatCLI
//
//  Root SwiftTUI view for the SwiftClaude CLI application
//

import SwiftTUI
import Foundation

/// Main application view containing the entire chat interface
struct MainView: View {
    @State private var messages: [ChatMessage] = []
    @State private var isStreaming: Bool = false
    @State private var currentTool: String? = nil
    @State private var inputHistory: [String] = []
    @State private var statusMessage: String = "Ready"
    @State private var errorMessage: String? = nil

    private let environment = AppEnvironment.detect()

    var body: some View {
        VStack {
            // Header - using dedicated HeaderView component
            HeaderView(
                modelName: UserDefaults.model.rawValue,
                workingDirectory: environment.workingDirectory,
                gitBranch: environment.gitBranch
            )

            // Separator
            Text(String(repeating: "─", count: 80))
                .foregroundColor(.blue)

            // Chat history - using dedicated ChatHistoryView component
            ChatHistoryView(
                messages: messages,
                isStreaming: isStreaming
            )

            // Status bar - using dedicated StatusBarView component
            StatusBarView(
                statusMessage: statusMessage,
                messageCount: messages.count,
                currentTool: currentTool,
                isStreaming: isStreaming,
                errorMessage: errorMessage
            )

            // Separator
            Text(String(repeating: "─", count: 80))
                .foregroundColor(.blue)

            // Input - using dedicated InputView component
            InputView { text in
                handleInput(text)
            }
        }
        .padding(1)
    }

    // MARK: - Input Handling

    private func handleInput(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Clear any previous errors
        errorMessage = nil

        // Handle special commands
        if handleCommand(trimmed) {
            return
        }

        // Add user message
        messages.append(ChatMessage(role: .user, content: trimmed))
        inputHistory.append(trimmed)

        // Start streaming
        isStreaming = true
        statusMessage = "Thinking..."

        // TODO: Integrate with MessageService for real LLM calls
        // For now, simulate async response
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.messages.append(ChatMessage(
                role: .assistant,
                content: "Echo: \(trimmed)"
            ))
            self.isStreaming = false
            self.statusMessage = "Ready"
        }
    }

    /// Handle special commands
    /// Returns true if command was handled
    private func handleCommand(_ text: String) -> Bool {
        let command = text.lowercased()

        // Support both /command and plain command syntax
        let normalizedCommand = command.hasPrefix("/") ? String(command.dropFirst()) : command

        switch normalizedCommand {
        case "exit", "quit":
            exit(0)

        case "clear":
            messages.removeAll()
            statusMessage = "Cleared"
            return true

        case "help":
            showHelp()
            return true

        case "model":
            showModel()
            return true

        case "tools":
            showTools()
            return true

        case "history":
            showHistory()
            return true

        default:
            // Check if it's an unknown command (starts with /)
            if text.hasPrefix("/") {
                messages.append(ChatMessage(
                    role: .system,
                    content: "Unknown command: \(text). Type /help for available commands."
                ))
                return true
            }
            return false
        }
    }

    // MARK: - Command Implementations

    private func showHelp() {
        let helpText = """
        Available commands:
          /help     - Show this help message
          /clear    - Clear chat history
          /model    - Show current model
          /tools    - List available tools
          /history  - Show input history
          /exit     - Exit the application

        Keyboard shortcuts:
          Enter     - Send message
          Up/Down   - Navigate input history (TODO)
          Ctrl+C    - Cancel current operation
        """
        messages.append(ChatMessage(role: .system, content: helpText))
    }

    private func showModel() {
        let model = UserDefaults.model
        messages.append(ChatMessage(
            role: .system,
            content: "Current model: \(model.rawValue)"
        ))
    }

    private func showTools() {
        let registry = ToolRegistry.shared
        let tools = registry.toolNames.joined(separator: ", ")
        messages.append(ChatMessage(
            role: .system,
            content: "Available tools: \(tools.isEmpty ? "None registered" : tools)"
        ))
    }

    private func showHistory() {
        if inputHistory.isEmpty {
            messages.append(ChatMessage(role: .system, content: "No input history"))
        } else {
            let historyList = inputHistory.suffix(10).enumerated().map { (i, text) in
                "  \(i + 1). \(text)"
            }.joined(separator: "\n")
            messages.append(ChatMessage(
                role: .system,
                content: "Recent history:\n\(historyList)"
            ))
        }
    }
}

// MARK: - Preview Helper

#if DEBUG
extension MainView {
    static var preview: MainView {
        MainView()
    }
}
#endif
