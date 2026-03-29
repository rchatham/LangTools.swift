//
//  CommandParser.swift
//  CLI
//
//  Parses slash commands from user input
//

import Foundation

/// Result of parsing a command
enum ParsedInput {
    case command(SlashCommand)
    case message(String)
    case empty
}

/// A parsed slash command
struct SlashCommand {
    let name: String
    let arguments: [String]
    let rawArguments: String
}

/// Available slash commands
enum CommandType: String, CaseIterable {
    case help = "help"
    case clear = "clear"
    case exit = "exit"
    case quit = "quit"
    case save = "save"
    case load = "load"
    case sessions = "sessions"
    case model = "model"
    case tools = "tools"
    case status = "status"
    case compact = "compact"
    case plan = "plan"
    case tasks = "tasks"
    case cancel = "cancel"
    case settings = "settings"
    case apikey = "apikey"
    case ollama = "ollama"

    var description: String {
        switch self {
        case .help: return "Show available commands"
        case .clear: return "Clear the chat history"
        case .exit, .quit: return "Exit the application"
        case .save: return "Save current session"
        case .load: return "Load a saved session"
        case .sessions: return "List saved sessions"
        case .model: return "Change the current model"
        case .tools: return "List available tools"
        case .status: return "Show current status"
        case .compact: return "Compact conversation context"
        case .plan: return "Enter plan mode"
        case .tasks: return "Show running tasks"
        case .cancel: return "Cancel running operation"
        case .settings: return "Open settings menu"
        case .apikey: return "Set API key for a service"
        case .ollama: return "Manage local Ollama models"
        }
    }

    var usage: String {
        switch self {
        case .help: return "/help [command]"
        case .clear: return "/clear"
        case .exit, .quit: return "/exit"
        case .save: return "/save [name]"
        case .load: return "/load <session-id>"
        case .sessions: return "/sessions"
        case .model: return "/model [model-name]"
        case .tools: return "/tools"
        case .status: return "/status"
        case .compact: return "/compact"
        case .plan: return "/plan"
        case .tasks: return "/tasks"
        case .cancel: return "/cancel [task-id]"
        case .settings: return "/settings"
        case .apikey: return "/apikey <service> [key]"
        case .ollama: return "/ollama <list|pull|search|delete> [name]"
        }
    }
}

/// Parses user input for commands
struct CommandParser {
    /// Parse user input
    static func parse(_ input: String) -> ParsedInput {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            return .empty
        }

        guard trimmed.hasPrefix("/") else {
            return .message(trimmed)
        }

        // Parse command
        let withoutSlash = String(trimmed.dropFirst())
        let components = withoutSlash.components(separatedBy: .whitespaces)

        guard let commandName = components.first?.lowercased() else {
            return .message(trimmed) // Treat as message if no command name
        }

        let arguments = Array(components.dropFirst())
        let rawArguments = components.dropFirst().joined(separator: " ")

        return .command(SlashCommand(
            name: commandName,
            arguments: arguments,
            rawArguments: rawArguments
        ))
    }

    /// Get command type if valid
    static func commandType(for name: String) -> CommandType? {
        CommandType(rawValue: name.lowercased())
    }

    /// Check if input is a command
    static func isCommand(_ input: String) -> Bool {
        input.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/")
    }

    /// Generate help text for all commands
    static func helpText() -> String {
        var help = "Available Commands:\n"
        help += "─────────────────────\n"

        for command in CommandType.allCases {
            help += "\(command.usage.padding(toLength: 25, withPad: " ", startingAt: 0))\(command.description)\n"
        }

        return help
    }

    /// Generate help text for specific command
    static func helpText(for commandName: String) -> String {
        guard let command = commandType(for: commandName) else {
            return "Unknown command: \(commandName)\nType /help for available commands."
        }

        return """
        Command: /\(command.rawValue)
        Usage: \(command.usage)
        Description: \(command.description)
        """
    }
}

/// Command execution results
enum CommandResult {
    case success(String)
    case error(String)
    case action(CommandAction)
    case none
}

/// Actions that commands can trigger
enum CommandAction {
    case clearHistory
    case exit
    case showHelp(String)
    case showStatus
    case showTools
    case showSessions
    case loadSession(UUID)
    case saveSession(String?)
    case changeModel(String)
    case enterPlanMode
    case compactContext
    case showTasks
    case cancelTask(String?)
    case showSettings
    case setApiKey(service: String?, key: String?)
}
