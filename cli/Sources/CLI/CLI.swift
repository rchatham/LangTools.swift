import Foundation
import LangTools
import OpenAI
import Anthropic
import XAI
import Gemini
import SwiftTUI

let cliVersion = "0.1.0"

var langToolchain = LangToolchain()
let messageService = MessageService()
let networkClient = NetworkClient.shared

@main
struct CLI {
    static func main() async throws {
        let args = CommandLine.arguments

        // --version / -v
        if args.contains("--version") || args.contains("-v") {
            print("langtools \(cliVersion)")
            return
        }

        // --help / -h
        if args.contains("--help") || args.contains("-h") {
            printUsage()
            return
        }

        // --tui flag
        let useTUI = args.contains("--tui")

        if useTUI {
            Application(rootView: MainView()).start()
        } else {
            try await runTraditionalCLI()
        }
    }

    static func printUsage() {
        print("""
        langtools \(cliVersion) — LLM chat CLI with agentic file/shell tools

        USAGE
          langtools [OPTIONS]

        OPTIONS
          --tui         Launch the SwiftTUI interactive interface
          --version     Print version and exit
          --help        Show this help message

        ENVIRONMENT
          ANTHROPIC_API_KEY   Anthropic API key
          OPENAI_API_KEY      OpenAI API key
          XAI_API_KEY         xAI (Grok) API key
          GEMINI_API_KEY      Google Gemini API key

        COMMANDS (in chat)
          /help [command]     Show help
          /model              Change the active model
          /status             Show model, tokens, API key status
          /clear              Clear conversation history
          /save [name]        Save current session
          /load <id>          Load a saved session
          /sessions           List saved sessions
          /compact            Compact conversation context
          /plan               Enter plan mode
          /tasks              Show running background tasks
          /tools              List available tools
          /apikey <svc> [key] Set an API key
          /settings           Open settings menu
          /exit               Quit
        """)
    }

    // MARK: - Traditional CLI

    static func runTraditionalCLI() async throws {
        // Load API keys from environment variables first, then prompt for missing ones
        loadAPIKeysFromEnvironment()
        try await checkAndRequestAPIKeys()

        print("LangTools \(cliVersion)")
        print("Type /help for available commands, or --tui for the TUI mode")
        print("Model: \(UserDefaults.model.rawValue)")

        while true {
            print("\nYou: ".green, terminator: "")
            guard let input = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) else { continue }

            let parsed = CommandParser.parse(input)
            switch parsed {
            case .empty:
                continue
            case .command(let cmd):
                let shouldExit = await handleCommand(cmd)
                if shouldExit { return }
                continue
            case .message(let text):
                // Legacy bare-word shortcuts
                if text.lowercased() == "exit" { print("Goodbye!"); return }
                if text.lowercased() == "model" { try? await changeModel(); continue }
                if text.lowercased() == "test" {
                    await AgentTestRunner.runInteractiveTests(messageService: messageService)
                    continue
                }

                do {
                    try await messageService.performMessageCompletionRequest(message: text, stream: true)
                } catch {
                    print("Error: \(error.localizedDescription)".red)
                }
            }
        }
    }

    // MARK: - Environment variable API key loading

    static func loadAPIKeysFromEnvironment() {
        let envMap: [(APIService, String)] = [
            (.anthropic, "ANTHROPIC_API_KEY"),
            (.openAI,    "OPENAI_API_KEY"),
            (.xAI,       "XAI_API_KEY"),
            (.gemini,    "GEMINI_API_KEY"),
        ]
        for (service, envVar) in envMap {
            if let key = ProcessInfo.processInfo.environment[envVar], !key.isEmpty {
                // Only set if not already stored (env acts as a fallback)
                if UserDefaults.getApiKey(for: service) == nil {
                    try? networkClient.updateApiKey(key, for: service)
                }
            }
        }
    }

    // MARK: - Command dispatch

    /// Handle a parsed slash command. Returns true if the loop should exit.
    static func handleCommand(_ command: SlashCommand) async -> Bool {
        guard let type = CommandParser.commandType(for: command.name) else {
            print("Unknown command: /\(command.name)".red)
            print("Type /help for available commands")
            return false
        }

        switch type {

        case .exit, .quit:
            print("Goodbye!")
            return true

        case .help:
            if command.arguments.isEmpty {
                print(CommandParser.helpText())
            } else {
                print(CommandParser.helpText(for: command.arguments[0]))
            }

        case .model:
            if let name = command.arguments.first {
                // Direct: /model claude-4-6-sonnet
                if let m = Model(rawValue: name) {
                    UserDefaults.model = m
                    print("Model changed to: \(m.rawValue)".green)
                } else {
                    print("Unknown model '\(name)'. Use /model without arguments to pick interactively.".red)
                }
            } else {
                try? await changeModel()
            }

        case .settings:
            await showSettingsMenu()

        case .apikey:
            await handleApiKeyCommand(command)

        case .status:
            showStatus()

        case .clear:
            messageService.clearMessages()
            print("Conversation history cleared.".yellow)

        case .tools:
            showTools()

        case .save:
            await handleSaveCommand(command)

        case .load:
            await handleLoadCommand(command)

        case .sessions:
            showSessions()

        case .compact:
            compactContext()

        case .plan:
            await handlePlanCommand()

        case .tasks:
            await showTasks()

        case .cancel:
            await handleCancelCommand(command)
        }
        return false
    }

    // MARK: - /tools

    static func showTools() {
        let names = ToolRegistry.shared.toolNames
        print("\n\("Available tools (\(names.count))".blue)")
        print("─────────────────")
        for name in names {
            print("  \(name)")
        }
    }

    // MARK: - /save, /load, /sessions

    static func handleSaveCommand(_ command: SlashCommand) async {
        let name = command.arguments.first
        let wd = FileManager.default.currentDirectoryPath
        let session = SessionManager.shared.createSession(
            name: name,
            workingDirectory: wd,
            model: UserDefaults.model.rawValue
        )
        // Persist current messages into the session
        for msg in messageService.messages {
            try? SessionManager.shared.addMessage(
                role: msg.role == .user ? .user : .assistant,
                content: msg.text ?? ""
            )
        }
        print("Session saved: \(session.name) [\(session.id.uuidString.prefix(8))]".green)
    }

    static func handleLoadCommand(_ command: SlashCommand) async {
        guard let idString = command.arguments.first else {
            print("Usage: /load <session-id>".red)
            showSessions()
            return
        }

        // Support prefix matching on UUID
        let sessions = (try? SessionManager.shared.listSessions()) ?? []
        let match = sessions.first { $0.id.uuidString.lowercased().hasPrefix(idString.lowercased()) }

        guard let session = match else {
            print("Session not found: \(idString)".red)
            return
        }

        // Replace current messages with saved ones
        messageService.clearMessages()
        for saved in session.messages {
            let role: Role = saved.role == .user ? .user : .assistant
            messageService.messages.append(Message(text: saved.content, role: role))
        }

        SessionManager.shared.currentSessionId = session.id
        print("Loaded session '\(session.name)' (\(session.messages.count) messages)".green)
    }

    static func showSessions() {
        guard let sessions = try? SessionManager.shared.listSessions() else {
            print("Failed to list sessions".red)
            return
        }
        if sessions.isEmpty {
            print("No saved sessions.".yellow)
            return
        }
        print("\n\("Saved sessions".blue)")
        print("─────────────────")
        for s in sessions {
            let short = s.id.uuidString.prefix(8)
            let date = DateFormatter.localizedString(from: s.updatedAt, dateStyle: .short, timeStyle: .short)
            print("  \(short)  \(s.name)  (\(s.metadata.messageCount) msgs, \(date))")
        }
        print("\nUse /load <id-prefix> to restore a session")
    }

    // MARK: - /compact

    static func compactContext() {
        let before = messageService.messages.count
        let chatMessages = messageService.messages.map {
            ChatMessage(role: $0.role == .user ? .user : .assistant, content: $0.text ?? "")
        }
        let usage = ContextManager.shared.contextUsage(for: chatMessages)
        guard usage.needsCompaction else {
            print("Context is within limits (\(usage.formattedUsage)). No compaction needed.".yellow)
            return
        }
        let compacted = ContextManager.shared.compactMessages(chatMessages)
        messageService.messages = compacted.map {
            Message(text: $0.content, role: $0.role == .user ? .user : .assistant)
        }
        print("Compacted \(before) → \(messageService.messages.count) messages (\(usage.formattedUsage))".green)
    }

    // MARK: - /plan

    static func handlePlanCommand() async {
        let result = await MainActor.run { PlanModeManager.shared.enterPlanMode() }
        print(result.green)
    }

    // MARK: - /tasks, /cancel

    static func showTasks() async {
        let tasks = await TaskManager.shared.allActiveTasks
        if tasks.isEmpty {
            print("No running background tasks.".yellow)
        } else {
            print("\n\("Background tasks".blue)")
            print("─────────────────")
            for task in tasks {
                let shortId = String(task.id.prefix(8))
                print("  \(shortId)  \(task.agentType.rawValue)  \(task.status.rawValue)")
            }
            print("\nUse /cancel <id-prefix> to cancel a task")
        }
    }

    static func handleCancelCommand(_ command: SlashCommand) async {
        guard let prefix = command.arguments.first else {
            print("Usage: /cancel <task-id-prefix>".red)
            await showTasks()
            return
        }
        let tasks = await TaskManager.shared.allActiveTasks
        guard let task = tasks.first(where: { $0.id.lowercased().hasPrefix(prefix.lowercased()) }) else {
            print("No task matching '\(prefix)'".red)
            return
        }
        await TaskManager.shared.cancelTask(id: task.id)
        print("Cancelled task \(String(task.id.prefix(8)))".yellow)
    }

    // MARK: - /apikey

    static func handleApiKeyCommand(_ command: SlashCommand) async {
        if command.arguments.isEmpty {
            await showApiKeyMenu()
            return
        }

        let serviceName = command.arguments[0].lowercased()
        guard let service = APIService.allCases.first(where: { $0.rawValue.lowercased() == serviceName }) else {
            print("Unknown service: \(serviceName)".red)
            print("Available services: \(APIService.allCases.map { $0.rawValue }.joined(separator: ", "))")
            return
        }

        if command.arguments.count > 1 {
            let key = command.arguments.dropFirst().joined(separator: " ")
            do {
                try networkClient.updateApiKey(key, for: service)
                print("\(service.rawValue) API key updated successfully".green)
            } catch {
                print("Failed to update API key: \(error.localizedDescription)".red)
            }
        } else {
            print("Enter \(service.rawValue) API key: ", terminator: "")
            if let key = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
                do {
                    try networkClient.updateApiKey(key, for: service)
                    print("\(service.rawValue) API key updated successfully".green)
                } catch {
                    print("Failed to update API key: \(error.localizedDescription)".red)
                }
            }
        }
    }

    // MARK: - /status

    static func showStatus() {
        print("\n\("Status".blue)")
        print("─────────────────")
        print("Version:     \(cliVersion)")
        print("Model:       \(UserDefaults.model.rawValue)")
        print("Max Tokens:  \(UserDefaults.maxTokens == 0 ? "default" : String(UserDefaults.maxTokens))")
        print("Temperature: \(UserDefaults.temperature)")
        let chatMessages = messageService.messages.map {
            ChatMessage(role: $0.role == .user ? .user : .assistant, content: $0.text ?? "")
        }
        let usage = ContextManager.shared.contextUsage(for: chatMessages)
        print("Context:     \(usage.formattedUsage)")
        print("")
        print("API Keys:")
        for service in APIService.allCases {
            let hasKey = UserDefaults.getApiKey(for: service) != nil
            let status = hasKey ? "✓ set".green : "✗ not set".red
            print("  \(service.rawValue): \(status)")
        }
        print("")
        print("Tools: \(ToolRegistry.shared.toolNames.count) registered")
    }

    // MARK: - API key setup

    static func checkAndRequestAPIKeys() async throws {
        // Only prompt for the default model's provider
        let defaultService: APIService
        switch UserDefaults.model {
        case .anthropic: defaultService = .anthropic
        case .openAI:    defaultService = .openAI
        case .xAI:       defaultService = .xAI
        case .gemini:    defaultService = .gemini
        default:         defaultService = .anthropic
        }

        if UserDefaults.getApiKey(for: defaultService) == nil {
            print("\nNo API key found for \(defaultService.rawValue) (current model provider)")
            print("Enter your \(defaultService.rawValue) API key (or press Enter to skip): ", terminator: "")
            if let apiKey = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty {
                do {
                    try networkClient.updateApiKey(apiKey, for: defaultService)
                    print("\(defaultService.rawValue) API key saved.".green)
                } catch {
                    print("Failed to save API key: \(error.localizedDescription)".red)
                }
            } else {
                print("Skipping — use /apikey or set \(defaultService.rawValue.uppercased())_API_KEY env var later".yellow)
            }
        }
    }

    // MARK: - Model selection

    static func changeModel() async throws {
        let models: [(String, Model)] = [
            ("OpenAI GPT-4o mini",        .openAI(.gpt4o_mini)),
            ("OpenAI GPT-5.2",            .openAI(.gpt5_2)),
            ("Anthropic Claude 4.6 Sonnet", .anthropic(.claude46Sonnet)),
            ("Gemini 3 Flash",            .gemini(.gemini3Flash)),
            ("XAI Grok 4 Fast",           .xAI(.grok4FastReasoning)),
        ]

        print("\n\("Available models".blue)")
        print("─────────────────")
        for (i, (name, _)) in models.enumerated() {
            print("\(i + 1). \(name)")
        }
        print("\nSelect model (1-\(models.count)): ", terminator: "")
        guard let choice = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines),
              let idx = Int(choice), idx >= 1, idx <= models.count else {
            print("Invalid choice. Keeping current model.".yellow)
            return
        }
        let newModel = models[idx - 1].1
        UserDefaults.model = newModel
        print("Model changed to: \(newModel.rawValue)".green)
    }

    // MARK: - Settings Menu

    static func showSettingsMenu() async {
        var config = Configuration.load()

        while true {
            let maxTokensDisplay = UserDefaults.maxTokens == 0 ? "default" : String(UserDefaults.maxTokens)
            let streamingStatus = config.streamingEnabled ? "enabled" : "disabled"

            print("\n\("Settings".blue)")
            print("─────────────────")
            print("1. API Keys")
            print("2. Model (\(UserDefaults.model.rawValue))")
            print("3. Max Tokens (\(maxTokensDisplay))")
            print("4. Temperature (\(UserDefaults.temperature))")
            print("5. Theme (\(config.theme.rawValue))")
            print("6. Streaming (\(streamingStatus))")
            print("7. Back")

            print("\nSelect option (1-7): ", terminator: "")
            guard let choice = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) else { continue }

            switch choice {
            case "1": await showApiKeyMenu()
            case "2": try? await changeModel()
            case "3": updateMaxTokens()
            case "4": updateTemperature()
            case "5": showThemeMenu(&config)
            case "6": toggleStreaming(&config)
            case "7", "": return
            default: print("Invalid choice".red)
            }
        }
    }

    static func showApiKeyMenu() async {
        while true {
            print("\n\("API Keys".blue)")
            print("─────────────────")
            for (index, service) in APIService.allCases.enumerated() {
                let hasKey = UserDefaults.getApiKey(for: service) != nil
                let status = hasKey ? "✓ Set".green : "✗ Not set".red
                print("\(index + 1). \(service.rawValue): \(status)")
            }
            print("\(APIService.allCases.count + 1). Back")

            print("\nSelect service (1-\(APIService.allCases.count + 1)): ", terminator: "")
            guard let choice = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let index = Int(choice) else { continue }

            if index == APIService.allCases.count + 1 { return }
            guard index >= 1, index <= APIService.allCases.count else {
                print("Invalid choice".red)
                continue
            }

            let service = APIService.allCases[index - 1]
            print("Enter \(service.rawValue) API key (or press Enter to cancel): ", terminator: "")
            if let key = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
                do {
                    try networkClient.updateApiKey(key, for: service)
                    print("\(service.rawValue) API key updated successfully".green)
                } catch {
                    print("Failed to update API key: \(error.localizedDescription)".red)
                }
            }
        }
    }

    static func updateMaxTokens() {
        let current = UserDefaults.maxTokens == 0 ? "default" : String(UserDefaults.maxTokens)
        print("\nCurrent max tokens: \(current)")
        print("Enter new value (or press Enter to use default): ", terminator: "")

        guard let input = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) else { return }

        if input.isEmpty {
            UserDefaults.maxTokens = 0
            print("Max tokens reset to default".green)
        } else if let value = Int(input), value > 0 {
            UserDefaults.maxTokens = value
            print("Max tokens set to \(value)".green)
        } else {
            print("Invalid value. Please enter a positive number.".red)
        }
    }

    static func updateTemperature() {
        print("\nCurrent temperature: \(UserDefaults.temperature)")
        print("Enter new value (0.0-2.0): ", terminator: "")

        guard let input = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines),
              let value = Double(input) else {
            print("Invalid value".red)
            return
        }

        if value >= 0.0 && value <= 2.0 {
            UserDefaults.temperature = value
            print("Temperature set to \(value)".green)
        } else {
            print("Value must be between 0.0 and 2.0".red)
        }
    }

    static func showThemeMenu(_ config: inout Configuration) {
        print("\n\("Themes".blue)")
        print("─────────────────")
        for (index, theme) in Theme.allCases.enumerated() {
            let current = theme == config.theme ? " (current)" : ""
            let recommended = theme == .default ? " (Recommended)" : ""
            print("\(index + 1). \(theme.rawValue)\(recommended)\(current)")
        }
        print("\(Theme.allCases.count + 1). Back")

        print("\nSelect theme (1-\(Theme.allCases.count + 1)): ", terminator: "")
        guard let choice = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines),
              let index = Int(choice) else { return }

        if index == Theme.allCases.count + 1 { return }
        guard index >= 1, index <= Theme.allCases.count else {
            print("Invalid choice".red)
            return
        }

        config.theme = Theme.allCases[index - 1]
        do {
            try config.save()
            print("Theme changed to \(config.theme.rawValue)".green)
        } catch {
            print("Failed to save theme: \(error.localizedDescription)".red)
        }
    }

    static func toggleStreaming(_ config: inout Configuration) {
        config.streamingEnabled.toggle()
        do {
            try config.save()
            let status = config.streamingEnabled ? "enabled" : "disabled"
            print("Streaming \(status)".green)
        } catch {
            print("Failed to save setting: \(error.localizedDescription)".red)
        }
    }
}

typealias Colors = ANSIColor
enum ANSIColor: String, CaseIterable {
    case black = "\u{001B}[0;30m"
    case red = "\u{001B}[0;31m"
    case green = "\u{001B}[0;32m"
    case yellow = "\u{001B}[0;33m"
    case blue = "\u{001B}[0;34m"
    case magenta = "\u{001B}[0;35m"
    case cyan = "\u{001B}[0;36m"
    case white = "\u{001B}[0;37m"
    case `default` = "\u{001B}[0;0m"

    static func + (lhs: ANSIColor, rhs: String) -> String {
        return lhs.rawValue + rhs
    }

    static func + (lhs: String, rhs: ANSIColor) -> String {
        return lhs + rhs.rawValue
    }
}

extension String {
    func colored(_ color: ANSIColor) -> String { return color + self + ANSIColor.default }
    var black: String { return colored(.black) }
    var red: String { return colored(.red) }
    var green: String { return colored(.green) }
    var yellow: String { return colored(.yellow) }
    var blue: String { return colored(.blue) }
    var magenta: String { return colored(.magenta) }
    var cyan: String { return colored(.cyan) }
    var white: String { return colored(.white) }
}
