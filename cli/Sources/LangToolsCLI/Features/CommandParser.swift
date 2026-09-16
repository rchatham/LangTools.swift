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

struct CommandHelpDefinition {
    let description: String
    let usage: String
    let examples: [String]
    let details: [String]
    let notes: [String]
    let seeAlso: [String]

    init(
        description: String,
        usage: String,
        examples: [String],
        details: [String] = [],
        notes: [String] = [],
        seeAlso: [String] = []
    ) {
        self.description = description
        self.usage = usage
        self.examples = examples
        self.details = details
        self.notes = notes
        self.seeAlso = seeAlso
    }
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

    var help: CommandHelpDefinition {
        switch self {
        case .help:
            return .init(description: "Show available commands", usage: "/help [command]", examples: ["/help", "/help ollama", "/help model"])
        case .clear:
            return .init(description: "Clear the chat history", usage: "/clear", examples: ["/clear"])
        case .exit, .quit:
            return .init(description: "Exit the application", usage: "/exit", examples: ["/exit"])
        case .save:
            return .init(description: "Save current session", usage: "/save [name]", examples: ["/save", "/save refactor-session"])
        case .load:
            return .init(description: "Load a saved session", usage: "/load <session-id>", examples: ["/load 123E4567-E89B-12D3-A456-426614174000"])
        case .sessions:
            return .init(description: "List saved sessions", usage: "/sessions", examples: ["/sessions"])
        case .model:
            return .init(
                description: "Change the current model",
                usage: "/model [model-name]",
                examples: ["/model", "/model claude-4-6-sonnet", "/model llama3.2:latest"],
                details: [
                    "Run /model with no arguments to choose interactively.",
                    "Pass a model name directly to switch without opening the picker.",
                    "The selected model controls provider routing, tool support, and warning behavior."
                ],
                notes: [
                    "Cloud models usually require a matching API key.",
                    "Local Ollama models do not require an API key, but tool reliability may be limited."
                ],
                seeAlso: ["/status", "/apikey", "/help ollama"]
            )
        case .tools:
            return .init(
                description: "List available tools",
                usage: "/tools",
                examples: ["/tools"],
                details: [
                    "Shows the tools the CLI can expose to supported models.",
                    "Tool use depends on the active model and provider capabilities."
                ],
                notes: [
                    "Some models may warn before tool-heavy prompts.",
                    "Unavailable models continue without tools instead of failing silently."
                ],
                seeAlso: ["/status", "/help model"]
            )
        case .status:
            return .init(
                description: "Show current status",
                usage: "/status",
                examples: ["/status"],
                details: [
                    "Displays the active model, provider, generation settings, and API key status.",
                    "Capability lines indicate whether tools, streaming, and structured output are supported or recommended."
                ],
                notes: [
                    "Warnings explain when the current model may be weak or unavailable for tool calling.",
                    "Use this first when diagnosing missing provider or capability issues."
                ],
                seeAlso: ["/model", "/apikey", "/help tools"]
            )
        case .compact:
            return .init(description: "Compact conversation context", usage: "/compact", examples: ["/compact"])
        case .plan:
            return .init(description: "Enter plan mode", usage: "/plan", examples: ["/plan"])
        case .tasks:
            return .init(description: "Show running tasks", usage: "/tasks", examples: ["/tasks"])
        case .cancel:
            return .init(description: "Cancel running operation", usage: "/cancel [task-id]", examples: ["/cancel", "/cancel task-123"])
        case .settings:
            return .init(description: "Open settings menu", usage: "/settings", examples: ["/settings"])
        case .apikey:
            return .init(description: "Set API key for a service", usage: "/apikey <service> [key]", examples: ["/apikey openAI", "/apikey anthropic sk-ant-..."])
        case .ollama:
            return .init(
                description: "Manage local Ollama models",
                usage: "/ollama <subcommand> [name]",
                examples: ["/ollama list", "/ollama pull llama3.2:latest", "/ollama search mistral"],
                details: [
                    "Supported subcommands: list, pull, search, and delete.",
                    "Use /ollama list to inspect local models and /model <name> to switch to one.",
                    "Ollama models run locally and use OLLAMA_HOST if you need a non-default server."
                ],
                notes: [
                    "Local models can be good for basic chat, but tool-heavy flows may be less reliable.",
                    "Pulling and deleting models are interactive or stateful operations."
                ],
                seeAlso: ["/model", "/status"]
            )
        }
    }

    var description: String { help.description }
    var usage: String { help.usage }
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

        var renderedUsages = Set<String>()
        for command in CommandType.allCases {
            guard renderedUsages.insert(command.usage).inserted else { continue }
            help += "\(command.usage.padding(toLength: 28, withPad: " ", startingAt: 0))\(command.description)\n"
        }

        return help
    }

    /// Generate help text for specific command
    static func helpText(for commandName: String) -> String {
        guard let command = commandType(for: commandName) else {
            return "Unknown command: \(commandName)\nType /help for available commands."
        }

        let help = command.help
        let examples = help.examples.map { "  \($0)" }.joined(separator: "\n")
        let details = renderedSection(title: "Details", lines: help.details)
        let notes = renderedSection(title: "Notes", lines: help.notes)
        let seeAlso = help.seeAlso.isEmpty ? "" : "\nSee also:\n  \(help.seeAlso.joined(separator: ", "))"

        return """
        Command: /\(command.rawValue)
        Usage: \(help.usage)
        Description: \(help.description)\(details)
        Examples:
        \(examples)\(notes)\(seeAlso)
        """
    }

    private static func renderedSection(title: String, lines: [String]) -> String {
        guard !lines.isEmpty else { return "" }
        let renderedLines = lines.map { "  • \($0)" }.joined(separator: "\n")
        return "\n\(title):\n\(renderedLines)"
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
