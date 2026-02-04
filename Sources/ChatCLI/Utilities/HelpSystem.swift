//
//  HelpSystem.swift
//  ChatCLI
//
//  Help documentation system
//

import Foundation

/// Provides help documentation
struct HelpSystem {

    // MARK: - Command Help

    /// Generate full help text
    static func fullHelp() -> String {
        """
        ╔════════════════════════════════════════════════════════════════╗
        ║                        ChatCLI Help                            ║
        ╚════════════════════════════════════════════════════════════════╝

        \(CommandParser.helpText())

        ═══════════════════════════════════════════════════════════════════

        KEYBOARD SHORTCUTS
        ──────────────────
        Ctrl+C      Cancel current operation
        Ctrl+L      Clear screen (in some terminals)
        Up/Down     Navigate input history

        ═══════════════════════════════════════════════════════════════════

        TOOL USAGE
        ──────────
        The assistant can use various tools to help you:

        • Read    - Read file contents
        • Write   - Create or overwrite files
        • Edit    - Make precise text replacements
        • Bash    - Execute shell commands
        • Glob    - Find files by pattern
        • Grep    - Search file contents

        ═══════════════════════════════════════════════════════════════════

        AGENT TYPES
        ───────────
        Specialized agents can be spawned for complex tasks:

        • Explore   - Fast codebase exploration (read-only)
        • Plan      - Design implementation approaches
        • General   - Full capabilities for multi-step tasks
        • Bash      - Command execution specialist

        ═══════════════════════════════════════════════════════════════════

        TIPS
        ────
        • Use /status to see current model and context usage
        • Use /compact to reduce context if running low
        • Use /save to save your conversation for later
        • Press Ctrl+C to cancel long-running operations
        • Start messages with / for commands

        For more information, type /help <command>
        """
    }

    // MARK: - Quick Reference

    /// Generate quick reference card
    static func quickReference() -> String {
        """
        Quick Reference
        ───────────────
        /help     - Show this help
        /clear    - Clear history
        /status   - Show status
        /model    - Change model
        /save     - Save session
        /exit     - Quit
        """
    }

    // MARK: - Tool Help

    /// Generate help for a specific tool
    static func toolHelp(for toolName: String) -> String {
        switch toolName.lowercased() {
        case "read":
            return """
            Read Tool
            ─────────
            Reads file contents with line numbers.

            Parameters:
            • file_path (required) - Absolute path to file
            • offset              - Line number to start from
            • limit               - Number of lines to read

            Example: Read the first 50 lines of a file
            """

        case "write":
            return """
            Write Tool
            ──────────
            Creates or overwrites a file.

            Parameters:
            • file_path (required) - Absolute path to file
            • content (required)   - Content to write

            Note: Will overwrite existing files!
            """

        case "edit":
            return """
            Edit Tool
            ─────────
            Makes precise text replacements in files.

            Parameters:
            • file_path (required) - Absolute path to file
            • old_string (required) - Text to find
            • new_string (required) - Replacement text
            • replace_all          - Replace all occurrences

            Note: old_string must be unique unless replace_all is true
            """

        case "bash":
            return """
            Bash Tool
            ─────────
            Executes shell commands.

            Parameters:
            • command (required)    - Command to execute
            • timeout              - Timeout in milliseconds (max 600000)
            • working_directory    - Directory to run in
            • run_in_background    - Run asynchronously

            Note: Be careful with destructive commands!
            """

        case "glob":
            return """
            Glob Tool
            ─────────
            Finds files matching a pattern.

            Parameters:
            • pattern (required) - Glob pattern (e.g., "**/*.swift")
            • path              - Base directory (default: cwd)

            Returns files sorted by modification time.
            """

        case "grep":
            return """
            Grep Tool
            ─────────
            Searches file contents using regex.

            Parameters:
            • pattern (required) - Regex pattern
            • path              - Directory to search
            • glob              - Filter files by pattern
            • output_mode       - "content", "files_with_matches", "count"
            • context_before    - Lines before matches
            • context_after     - Lines after matches
            """

        default:
            return "Unknown tool: \(toolName). Use /tools to see available tools."
        }
    }

    // MARK: - Getting Started

    /// Generate getting started guide
    static func gettingStarted() -> String {
        """
        Getting Started with ChatCLI
        ════════════════════════════

        1. BASIC USAGE
           Just type your message and press Enter.
           The assistant will respond and may use tools to help.

        2. COMMANDS
           Commands start with /
           Try /help, /status, or /model

        3. FILES
           The assistant can read, write, and edit files.
           It will ask for confirmation before making changes.

        4. SHELL
           The assistant can run shell commands.
           Dangerous operations require your approval.

        5. SAVING
           Use /save to save your conversation.
           Use /load <id> to restore a saved session.

        Type /help for more options.
        """
    }
}
