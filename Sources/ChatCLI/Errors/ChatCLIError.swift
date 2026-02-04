//
//  ChatCLIError.swift
//  ChatCLI
//
//  Comprehensive error types for the CLI application
//  Note: Some error types (FileSystemError, ToolExecutionError) are defined
//  in their respective service files. This file provides additional error types.
//

import Foundation

/// Network errors
enum NetworkError: LocalizedError {
    case connectionFailed(url: String, reason: String)
    case timeout(url: String)
    case invalidResponse(url: String, statusCode: Int)
    case sslError(url: String)
    case redirectDetected(from: String, to: String)
    case contentDecodingFailed(url: String)

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let url, let reason):
            return "Connection to '\(url)' failed: \(reason)"
        case .timeout(let url):
            return "Connection to '\(url)' timed out"
        case .invalidResponse(let url, let statusCode):
            return "Invalid response from '\(url)': HTTP \(statusCode)"
        case .sslError(let url):
            return "SSL error for '\(url)'"
        case .redirectDetected(let from, let to):
            return "Redirect from '\(from)' to '\(to)'"
        case .contentDecodingFailed(let url):
            return "Could not decode content from '\(url)'"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .connectionFailed:
            return "Check your internet connection and try again."
        case .timeout:
            return "The server is not responding. Try again later."
        case .invalidResponse:
            return "The server returned an error. Check the URL."
        case .sslError:
            return "There's an SSL certificate issue with this site."
        case .redirectDetected:
            return "Make a new request with the redirect URL."
        case .contentDecodingFailed:
            return "The content format is not supported."
        }
    }
}

/// Configuration errors
enum ConfigurationError: LocalizedError {
    case missingApiKey(provider: String)
    case invalidConfiguration(reason: String)
    case unsupportedModel(model: String)
    case configFileNotFound(path: String)
    case configParseError(reason: String)

    var errorDescription: String? {
        switch self {
        case .missingApiKey(let provider):
            return "Missing API key for \(provider)"
        case .invalidConfiguration(let reason):
            return "Invalid configuration: \(reason)"
        case .unsupportedModel(let model):
            return "Unsupported model: \(model)"
        case .configFileNotFound(let path):
            return "Configuration file not found: \(path)"
        case .configParseError(let reason):
            return "Failed to parse configuration: \(reason)"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .missingApiKey(let provider):
            return "Set the \(provider.uppercased())_API_KEY environment variable."
        case .invalidConfiguration:
            return "Review your configuration settings."
        case .unsupportedModel:
            return "Use /model to see available models."
        case .configFileNotFound:
            return "Create a configuration file or use defaults."
        case .configParseError:
            return "Check the configuration file syntax."
        }
    }
}

/// Agent errors
enum AgentError: LocalizedError {
    case agentNotFound(type: String)
    case executionFailed(agent: String, reason: String)
    case contextPassingFailed(reason: String)
    case maxTurnsExceeded(agent: String, turns: Int)
    case invalidAgentType(type: String)

    var errorDescription: String? {
        switch self {
        case .agentNotFound(let type):
            return "Agent type not found: \(type)"
        case .executionFailed(let agent, let reason):
            return "Agent '\(agent)' failed: \(reason)"
        case .contextPassingFailed(let reason):
            return "Failed to pass context: \(reason)"
        case .maxTurnsExceeded(let agent, let turns):
            return "Agent '\(agent)' exceeded max turns (\(turns))"
        case .invalidAgentType(let type):
            return "Invalid agent type: \(type)"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .agentNotFound:
            return "Check the agent type spelling."
        case .executionFailed:
            return "Try a different approach or simplify the task."
        case .contextPassingFailed:
            return "Reduce context size or simplify the task."
        case .maxTurnsExceeded:
            return "Break the task into smaller subtasks."
        case .invalidAgentType:
            return "Use one of: explore, plan, general, bash."
        }
    }
}

/// Context errors
enum ContextError: LocalizedError {
    case contextTooLarge(currentTokens: Int, maxTokens: Int)
    case compactionFailed(reason: String)
    case summarizationFailed(reason: String)

    var errorDescription: String? {
        switch self {
        case .contextTooLarge(let current, let max):
            return "Context too large: \(current) tokens (max: \(max))"
        case .compactionFailed(let reason):
            return "Context compaction failed: \(reason)"
        case .summarizationFailed(let reason):
            return "Summarization failed: \(reason)"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .contextTooLarge:
            return "Use /compact to reduce context size."
        case .compactionFailed:
            return "Start a new session with /clear."
        case .summarizationFailed:
            return "Try /compact again or start a new session."
        }
    }
}

/// Input errors
enum InputError: LocalizedError {
    case emptyInput
    case invalidCommand(name: String)
    case invalidArguments(command: String, reason: String)
    case cancelledByUser

    var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "No input provided"
        case .invalidCommand(let name):
            return "Unknown command: /\(name)"
        case .invalidArguments(let command, let reason):
            return "Invalid arguments for /\(command): \(reason)"
        case .cancelledByUser:
            return "Operation cancelled"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .emptyInput:
            return "Type a message or /help for commands."
        case .invalidCommand:
            return "Type /help to see available commands."
        case .invalidArguments:
            return "Type /help <command> for usage."
        case .cancelledByUser:
            return nil
        }
    }
}

/// Helper for formatting errors for display
struct ErrorFormatter {
    /// Format an error for display
    static func format(_ error: Error) -> String {
        var result = ""

        if let localizedError = error as? LocalizedError {
            result = "Error: \(localizedError.errorDescription ?? error.localizedDescription)"
            if let suggestion = localizedError.recoverySuggestion {
                result += "\nSuggestion: \(suggestion)"
            }
        } else {
            result = "Error: \(error.localizedDescription)"
        }

        return result
    }

    /// Format an error for logging
    static func formatForLog(_ error: Error) -> String {
        return "[\(Date())] \(format(error))"
    }
}
