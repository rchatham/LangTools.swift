//
//  ChatViewModel.swift
//  ChatCLI
//
//  Central state management for the chat interface
//

import Foundation
import SwiftTUI
import LangTools
import OpenAI

/// Observable view model for managing chat state
@MainActor
class ChatViewModel: ObservableObject {
    /// All messages in the conversation
    @Published var messages: [ChatMessage] = []

    /// Whether a response is currently streaming
    @Published var isStreaming: Bool = false

    /// Currently executing tool, if any
    @Published var currentTool: String? = nil

    /// Status message for the status bar
    @Published var statusMessage: String = "Ready"

    /// Input history for up/down navigation
    @Published var inputHistory: [String] = []

    /// Current position in input history (-1 = not navigating)
    @Published var historyIndex: Int = -1

    /// Error message to display, if any
    @Published var errorMessage: String? = nil

    /// Reference to message service for LLM communication
    private let messageService: MessageService

    /// Tool registry for available tools
    private let toolRegistry = ToolRegistry.shared

    /// Tool executor for running tools
    private let toolExecutor = ToolExecutor.shared

    /// Maximum history size
    private let maxHistorySize = 100

    /// Event callback registration ID
    private var toolEventCallbackId: UUID?

    init(messageService: MessageService = MessageService()) {
        self.messageService = messageService
        registerToolEventCallback()
    }

    // MARK: - Tool Event Handling

    private func registerToolEventCallback() {
        Task {
            toolEventCallbackId = await toolExecutor.registerEventCallback { [weak self] event in
                Task { @MainActor in
                    self?.handleToolEvent(event)
                }
            }
        }
    }

    private func handleToolEvent(_ event: ToolExecutionEvent) {
        switch event {
        case .started(let toolName):
            currentTool = toolName
            statusMessage = "Running: \(toolName)..."

        case .progress(let toolName, let message):
            if currentTool == toolName {
                statusMessage = "\(toolName): \(message)"
            }

        case .output(_, _):
            // Could stream output to UI
            break

        case .completed(let toolName, let result):
            // Add tool result to messages
            var toolMessage = ChatMessage(role: .tool, content: result.output)
            toolMessage.toolName = toolName
            messages.append(toolMessage)
            currentTool = nil
            statusMessage = "Ready"

        case .failed(let toolName, let error):
            var toolMessage = ChatMessage(role: .tool, content: "Error: \(error.localizedDescription)")
            toolMessage.toolName = toolName
            messages.append(toolMessage)
            currentTool = nil
            errorMessage = error.localizedDescription
            statusMessage = "Error"

        case .cancelled(let toolName):
            var toolMessage = ChatMessage(role: .tool, content: "Cancelled")
            toolMessage.toolName = toolName
            messages.append(toolMessage)
            currentTool = nil
            statusMessage = "Cancelled"
        }
    }

    // MARK: - Message Handling

    /// Send a user message and get response
    func sendMessage(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Add to history
        addToHistory(trimmed)

        // Add user message
        let userMessage = ChatMessage(role: .user, content: trimmed)
        messages.append(userMessage)

        // Start streaming
        isStreaming = true
        statusMessage = "Thinking..."
        errorMessage = nil

        do {
            // Create assistant message placeholder
            let assistantMessage = ChatMessage(role: .assistant, content: "")
            messages.append(assistantMessage)

            // Get response from LLM
            try await messageService.performMessageCompletionRequest(message: trimmed, stream: true)

            // Update the last message with the response
            if let lastContent = messageService.messages.last?.text {
                messages[messages.count - 1] = ChatMessage(role: .assistant, content: lastContent)
            }

            statusMessage = "Ready"
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Error"
            // Remove the empty assistant message placeholder
            if messages.last?.content.isEmpty == true {
                messages.removeLast()
            }
        }

        isStreaming = false
        currentTool = nil
    }

    /// Handle special commands
    /// Returns true if command was handled, false to process as normal message
    func handleCommand(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        switch trimmed {
        case "exit", "quit", "/exit", "/quit":
            exit(0)

        case "clear", "/clear":
            clearMessages()
            return true

        case "help", "/help":
            showHelp()
            return true

        case "model", "/model":
            showModel()
            return true

        case "tools", "/tools":
            showTools()
            return true

        case "history", "/history":
            showHistory()
            return true

        default:
            if trimmed.hasPrefix("/") {
                // Unknown command
                messages.append(ChatMessage(
                    role: .system,
                    content: "Unknown command: \(trimmed). Type /help for available commands."
                ))
                return true
            }
            return false
        }
    }

    // MARK: - History Navigation

    func navigateHistoryUp() -> String? {
        guard !inputHistory.isEmpty else { return nil }

        if historyIndex < inputHistory.count - 1 {
            historyIndex += 1
        }

        return inputHistory[inputHistory.count - 1 - historyIndex]
    }

    func navigateHistoryDown() -> String? {
        guard historyIndex > 0 else {
            historyIndex = -1
            return ""
        }

        historyIndex -= 1
        return inputHistory[inputHistory.count - 1 - historyIndex]
    }

    func resetHistoryNavigation() {
        historyIndex = -1
    }

    private func addToHistory(_ text: String) {
        // Don't add duplicates of the last entry
        if inputHistory.last != text {
            inputHistory.append(text)
            if inputHistory.count > maxHistorySize {
                inputHistory.removeFirst()
            }
        }
        resetHistoryNavigation()
    }

    // MARK: - Commands

    func clearMessages() {
        messages.removeAll()
        messageService.messages.removeAll()
        statusMessage = "Cleared"
    }

    func showHelp() {
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
          Up/Down   - Navigate input history
          Ctrl+C    - Cancel current operation
          Ctrl+L    - Clear screen
        """
        messages.append(ChatMessage(role: .system, content: helpText))
    }

    func showModel() {
        let model = UserDefaults.model
        messages.append(ChatMessage(
            role: .system,
            content: "Current model: \(model.rawValue)"
        ))
    }

    func showTools() {
        let tools = toolRegistry.toolNames.joined(separator: ", ")
        messages.append(ChatMessage(
            role: .system,
            content: "Available tools: \(tools)"
        ))
    }

    func showHistory() {
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

    // MARK: - Tool Execution

    func setToolExecuting(_ toolName: String?) {
        currentTool = toolName
        if let name = toolName {
            statusMessage = "Running: \(name)..."
        } else {
            statusMessage = isStreaming ? "Streaming..." : "Ready"
        }
    }

    /// Execute a tool by name with given parameters
    func executeTool(name: String, parameters: [String: Any]) async {
        // Check if approval is required
        if ToolApprovalPolicy.requiresApproval(toolName: name, parameters: parameters) {
            // Show approval request in messages
            let operation = ToolApprovalPolicy.operationDescription(toolName: name, parameters: parameters)
            messages.append(ChatMessage(
                role: .system,
                content: "⚠️ Approval required for: \(operation)\n(Approval workflow not yet implemented - auto-approving)"
            ))
        }

        do {
            let _ = try await toolExecutor.execute(toolName: name, parameters: parameters)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Execute a tool call from LLM response
    func executeToolCall(_ toolCall: OpenAI.Message.ToolCall) async {
        do {
            let _ = try await toolExecutor.execute(toolCall: toolCall)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Cancel any running tool
    func cancelCurrentTool() {
        if let toolName = currentTool {
            Task {
                await toolExecutor.cancel(toolName: toolName)
            }
        }
    }

    // MARK: - Error Handling

    func clearError() {
        errorMessage = nil
    }
}

// MARK: - Chat Message Type

/// Message for display in the chat interface
struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let role: Role
    var content: String
    let timestamp: Date = Date()
    var toolName: String? = nil
    var isCollapsed: Bool = false

    enum Role: Equatable {
        case user
        case assistant
        case system
        case tool
    }

    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        lhs.id == rhs.id
    }
}
