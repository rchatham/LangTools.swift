//
//  MainView.swift
//  CLI
//
//  Root SwiftTUI view for the LangTools CLI application
//

import SwiftTUI
import Foundation

/// Settings navigation state for state-based menu handling
enum SettingsMode: Equatable {
    case none
    case main           // Main settings menu
    case apiKeys        // API keys sub-menu
    case apiKeyInput(APIService)  // Entering API key for specific service
    case theme          // Theme selection
    case maxTokens      // Max tokens input
    case temperature    // Temperature input
    case model          // Model selection (provider list)
    case modelProvider  // Provider selection view
    case modelList(Provider)  // List models for specific provider
}

/// Main application view containing the entire chat interface
struct MainView: View {
    @State private var messages: [ChatMessage] = []
    @State private var isStreaming: Bool = false
    @State private var currentTool: String? = nil
    @State private var inputHistory: [String] = []
    @State private var statusMessage: String = "Ready"
    @State private var errorMessage: String? = nil
    @State private var settingsMode: SettingsMode = .none

    // Overlay states
    @State private var showSettingsOverlay: Bool = false
    @State private var showAutocomplete: Bool = false
    @State private var autocompleteSuggestions: [CommandType] = []
    @State private var selectedSuggestionIndex: Int = 0
    @State private var pendingCommandPrefix: String = ""

    private let environment = AppEnvironment.detect()

    var body: some View {
        ZStack {
            // Main content layer
            mainContentView

            // Settings overlay (centered)
            if showSettingsOverlay {
                settingsOverlay
            }
        }
        .padding(2)
    }

    // MARK: - Main Content View

    private var mainContentView: some View {
        VStack(spacing: 1) {
            // Scrollable chat history - fills available space
            ChatHistoryView(
                messages: messages,
                isStreaming: isStreaming
            )

            // Separator above info line
            Text(String(repeating: "─", count: 80))
                .foregroundColor(.blue)

            // Info line - model, path, git branch (above input)
            InfoLineView(
                modelName: UserDefaults.model.rawValue,
                workingDirectory: environment.workingDirectory,
                gitBranch: environment.gitBranch,
                messageCount: messages.count,
                config: Configuration.load().infoLine
            )

            // Autocomplete dropdown (above input when active)
            if showAutocomplete && !autocompleteSuggestions.isEmpty {
                AutocompleteDropdown(
                    suggestions: autocompleteSuggestions,
                    selectedIndex: selectedSuggestionIndex,
                    onSelect: applyAutocomplete
                )
            }

            // Visual spacer before input
            Text("")

            // Input field
            InputView(
                hint: showAutocomplete ? "Select command or type to filter" : nil,
                isDisabled: showSettingsOverlay
            ) { text in
                handleInput(text)
            }

            // Visual spacer before status line
            Text("")

            // Status line - status indicator and errors (bottom)
            StatusLineView(
                status: statusMessage,
                isStreaming: isStreaming,
                currentTool: currentTool,
                errorMessage: errorMessage,
                config: Configuration.load().statusLine
            )
        }
    }

    // MARK: - Settings Overlay

    private var settingsOverlay: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                SettingsPanel(
                    mode: $settingsMode,
                    statusMessage: $statusMessage,
                    onClose: closeSettings
                )
                Spacer()
            }
            Spacer()
        }
    }

    private func closeSettings() {
        showSettingsOverlay = false
        settingsMode = .none
        statusMessage = "Ready"
    }

    // MARK: - Input Handling

    private func handleInput(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Clear any previous errors
        errorMessage = nil

        // If settings overlay is open, route input there for API key entry, etc.
        if showSettingsOverlay {
            handleSettingsOverlayInput(trimmed)
            return
        }

        // If autocomplete is showing, handle selection or filter
        if showAutocomplete {
            handleAutocompleteInput(trimmed)
            return
        }

        // Check if this should trigger autocomplete
        if CommandSuggestionEngine.shouldShowAutocomplete(for: trimmed) {
            triggerAutocomplete(for: trimmed)
            return
        }

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

        // Add placeholder for assistant response
        messages.append(ChatMessage(role: .assistant, content: ""))

        // Call LLM via MessageService (silent mode to avoid stdout corruption in TUI)
        Task {
            do {
                try await messageService.performMessageCompletionRequest(
                    message: trimmed,
                    stream: true,
                    silent: true
                )

                // Copy the response from MessageService to our ChatMessage array
                if let lastMessage = messageService.messages.last,
                   lastMessage.role == .assistant,
                   let content = lastMessage.text {
                    messages[messages.count - 1] = ChatMessage(
                        role: .assistant,
                        content: content
                    )
                }

                statusMessage = "Ready"
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = "Error"
                // Remove empty placeholder if error occurred
                if messages.last?.content.isEmpty == true {
                    messages.removeLast()
                }
            }
            isStreaming = false
        }
    }

    // MARK: - Autocomplete Handling

    private func triggerAutocomplete(for prefix: String) {
        pendingCommandPrefix = prefix
        autocompleteSuggestions = CommandSuggestionEngine.suggestions(for: prefix)
        selectedSuggestionIndex = 0
        showAutocomplete = !autocompleteSuggestions.isEmpty
        statusMessage = "Select command"
    }

    private func handleAutocompleteInput(_ text: String) {
        let trimmed = text.lowercased()

        // Check for numeric selection (1-6)
        if let index = Int(trimmed), index >= 1, index <= autocompleteSuggestions.count {
            applyAutocomplete(autocompleteSuggestions[index - 1])
            return
        }

        // Check if it's a refined filter (starts with /)
        if text.hasPrefix("/") {
            let newSuggestions = CommandSuggestionEngine.suggestions(for: text)
            if newSuggestions.count == 1 {
                // Exact match - apply it
                applyAutocomplete(newSuggestions[0])
            } else if !newSuggestions.isEmpty {
                // Update suggestions
                pendingCommandPrefix = text
                autocompleteSuggestions = newSuggestions
                selectedSuggestionIndex = 0
            } else {
                // No matches - close autocomplete and try as command
                dismissAutocomplete()
                _ = handleCommand(text)
            }
            return
        }

        // Cancel autocomplete and process as regular input
        dismissAutocomplete()
        // Re-process the input
        handleInput(text)
    }

    private func applyAutocomplete(_ command: CommandType) {
        dismissAutocomplete()
        // Execute the selected command
        _ = handleCommand("/\(command.rawValue)")
    }

    private func dismissAutocomplete() {
        showAutocomplete = false
        autocompleteSuggestions = []
        selectedSuggestionIndex = 0
        pendingCommandPrefix = ""
        statusMessage = "Ready"
    }

    // MARK: - Settings Overlay Input

    private func handleSettingsOverlayInput(_ text: String) {
        // Handle input when settings overlay is showing
        // This is for API key entry, max tokens, temperature, etc.
        switch settingsMode {
        case .apiKeyInput(let service):
            if text.isEmpty {
                statusMessage = "Cancelled"
            } else {
                do {
                    try NetworkClient.shared.updateApiKey(text, for: service)
                    statusMessage = "\(service.rawValue) key saved"
                } catch {
                    statusMessage = "Failed to save key"
                }
            }
            settingsMode = .apiKeys

        case .maxTokens:
            if let value = Int(text), value >= 0 {
                UserDefaults.maxTokens = value
                statusMessage = "Max tokens set to \(value == 0 ? "default" : String(value))"
            } else if !text.isEmpty {
                statusMessage = "Invalid number"
            }
            settingsMode = .main

        case .temperature:
            if let value = Double(text), value >= 0, value <= 2.0 {
                UserDefaults.temperature = value
                statusMessage = "Temperature set to \(value == 0 ? "default" : String(format: "%.1f", value))"
            } else if !text.isEmpty {
                statusMessage = "Invalid value (0.0-2.0)"
            }
            settingsMode = .main

        default:
            // For other modes, close the overlay
            closeSettings()
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
            messageService.clearMessages()
            statusMessage = "Cleared"
            return true

        case "help":
            showHelp()
            return true

        case "model":
            // Open settings overlay directly to model menu
            settingsMode = .model
            showSettingsOverlay = true
            statusMessage = "Settings"
            return true

        case "tools":
            showTools()
            return true

        case "history":
            showHistory()
            return true

        case "settings":
            // Open settings overlay instead of printing menu
            settingsMode = .main
            showSettingsOverlay = true
            statusMessage = "Settings"
            return true

        case "status":
            showStatus()
            return true

        case "apikey":
            // Open API keys submenu directly
            settingsMode = .apiKeys
            showSettingsOverlay = true
            statusMessage = "API Keys"
            return true

        case "save":
            let name: String? = nil // no arg parsing in TUI single-input currently
            let wd = FileManager.default.currentDirectoryPath
            let session = SessionManager.shared.createSession(
                name: name,
                workingDirectory: wd,
                model: UserDefaults.model.rawValue
            )
            for msg in messageService.messages {
                try? SessionManager.shared.addMessage(
                    role: msg.role == .user ? .user : .assistant,
                    content: msg.text ?? ""
                )
            }
            messages.append(ChatMessage(role: .system,
                content: "Session saved: \(session.name) [\(session.id.uuidString.prefix(8))]"))
            return true

        case "sessions":
            let sessions = (try? SessionManager.shared.listSessions()) ?? []
            if sessions.isEmpty {
                messages.append(ChatMessage(role: .system, content: "No saved sessions."))
            } else {
                let lines = sessions.map { s -> String in
                    let short = s.id.uuidString.prefix(8)
                    let date = DateFormatter.localizedString(from: s.updatedAt, dateStyle: .short, timeStyle: .short)
                    return "  \(short)  \(s.name)  (\(s.metadata.messageCount) msgs, \(date))"
                }
                messages.append(ChatMessage(role: .system,
                    content: "Saved sessions:\n\(lines.joined(separator: "\n"))\n\nUse /load <id-prefix> to restore"))
            }
            return true

        case "compact":
            let before = messages.count
            let chatMsgs = messageService.messages.map {
                ChatMessage(role: $0.role == .user ? .user : .assistant, content: $0.text ?? "")
            }
            let usage = ContextManager.shared.contextUsage(for: chatMsgs)
            if !usage.needsCompaction {
                messages.append(ChatMessage(role: .system,
                    content: "Context within limits (\(usage.formattedUsage)). No compaction needed."))
            } else {
                let compacted = ContextManager.shared.compactMessages(chatMsgs)
                messageService.messages = compacted.map {
                    Message(text: $0.content, role: $0.role == .user ? .user : .assistant)
                }
                messages = compacted
                messages.append(ChatMessage(role: .system,
                    content: "Compacted \(before) → \(compacted.count) messages"))
            }
            return true

        case "plan":
            Task {
                let result = await MainActor.run { PlanModeManager.shared.enterPlanMode() }
                messages.append(ChatMessage(role: .system, content: result))
            }
            return true

        case "tasks":
            Task {
                let tasks = await TaskManager.shared.allActiveTasks
                if tasks.isEmpty {
                    messages.append(ChatMessage(role: .system, content: "No running background tasks."))
                } else {
                    let lines = tasks.map { t -> String in
                        "  \(String(t.id.prefix(8)))  \(t.agentType.rawValue)  \(t.status.rawValue)"
                    }
                    messages.append(ChatMessage(role: .system,
                        content: "Background tasks:\n\(lines.joined(separator: "\n"))"))
                }
            }
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
          /help      - Show this help message
          /settings  - Open settings overlay
          /status    - Show current configuration
          /clear     - Clear chat history
          /model     - Change model (opens settings)
          /apikey    - Set API keys (opens settings)
          /tools     - List available tools
          /history   - Show input history
          /save      - Save current session
          /sessions  - List saved sessions
          /compact   - Compact conversation context
          /plan      - Enter plan mode
          /tasks     - Show running background tasks
          /exit      - Exit the application

        Tips:
          Type "/" and press Enter for command autocomplete
          In autocomplete: type number or refine with /prefix

        Keyboard shortcuts:
          Enter     - Send message / confirm selection
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

    // MARK: - Status Display (still shows in chat)

    private func showStatus() {
        let config = Configuration.load()
        var lines = ["── Status ──────────────────────────"]
        lines.append("Model: \(UserDefaults.model.rawValue)")
        lines.append("Max Tokens: \(UserDefaults.maxTokens == 0 ? "default" : String(UserDefaults.maxTokens))")
        lines.append("Temperature: \(UserDefaults.temperature == 0 ? "default" : String(format: "%.1f", UserDefaults.temperature))")
        lines.append("Theme: \(config.theme.rawValue)")
        lines.append("Streaming: \(config.streamingEnabled ? "enabled" : "disabled")")
        lines.append("")
        lines.append("API Keys:")
        for service in APIService.allCases {
            let status = UserDefaults.getApiKey(for: service) != nil ? "✓ Set" : "✗ Not set"
            lines.append("  \(service.rawValue): \(status)")
        }
        lines.append("────────────────────────────────────")
        messages.append(ChatMessage(role: .system, content: lines.joined(separator: "\n")))
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
