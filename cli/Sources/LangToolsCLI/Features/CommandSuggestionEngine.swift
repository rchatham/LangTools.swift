//
//  CommandSuggestionEngine.swift
//  CLI
//
//  Provides command autocomplete suggestions based on user input
//

import Foundation

/// Engine for generating command suggestions based on partial input
struct CommandSuggestionEngine {
    /// Maximum number of suggestions to return
    static let maxSuggestions = 6

    /// Get command suggestions for the given input prefix
    /// - Parameter prefix: The current input text (should start with "/")
    /// - Returns: Array of matching CommandType values, sorted by relevance
    static func suggestions(for prefix: String) -> [CommandType] {
        // Only suggest for commands starting with /
        guard prefix.hasPrefix("/") else { return [] }

        let query = String(prefix.dropFirst()).lowercased()

        // If just "/", show most common commands
        if query.isEmpty {
            return Array(CommandType.allCases.prefix(maxSuggestions))
        }

        // Filter commands that start with the query
        let matches = CommandType.allCases.filter { command in
            command.rawValue.hasPrefix(query)
        }

        // Sort by exact match first, then alphabetically
        let sorted = matches.sorted { a, b in
            // Exact match comes first
            if a.rawValue == query { return true }
            if b.rawValue == query { return false }
            // Then sort alphabetically
            return a.rawValue < b.rawValue
        }

        return Array(sorted.prefix(maxSuggestions))
    }

    /// Check if input should trigger autocomplete
    /// - Parameter input: The current input text
    /// - Returns: True if autocomplete should be shown
    static func shouldShowAutocomplete(for input: String) -> Bool {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("/") && !trimmed.contains(" ")
    }

    /// Format a command for display in autocomplete
    /// - Parameter command: The command type to format
    /// - Returns: Formatted display string
    static func displayText(for command: CommandType) -> String {
        "/\(command.rawValue)"
    }
}
