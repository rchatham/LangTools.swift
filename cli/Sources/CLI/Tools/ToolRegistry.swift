//
//  ToolRegistry.swift
//  CLI
//
//  Central registry for all available tools
//

import Foundation
import LangTools
import OpenAI

/// Protocol for tools that can be executed
protocol ExecutableTool {
    /// Tool name
    static var name: String { get }

    /// Tool description for LLM
    static var description: String { get }

    /// JSON schema for parameters
    static var parametersSchema: OpenAI.Tool.FunctionSchema.Parameters { get }

    /// Execute the tool with given parameters
    static func execute(parameters: [String: Any]) async throws -> String
}

/// Central registry for all Claude Code-like tools
final class ToolRegistry {
    /// Shared singleton instance
    static let shared = ToolRegistry()

    // MARK: - Parameter Extraction Helpers

    /// Extract a string value from parameters
    static func extractString(_ params: [String: Any], key: String) -> String? {
        params[key] as? String
    }

    /// Extract an optional string value from parameters
    static func extractOptionalString(_ params: [String: Any], key: String) -> String? {
        params[key] as? String
    }

    /// Extract an integer value from parameters
    static func extractInt(_ params: [String: Any], key: String) -> Int? {
        if let int = params[key] as? Int { return int }
        if let double = params[key] as? Double { return Int(double) }
        if let string = params[key] as? String { return Int(string) }
        return nil
    }

    /// Extract a boolean value from parameters
    static func extractBool(_ params: [String: Any], key: String) -> Bool? {
        if let bool = params[key] as? Bool { return bool }
        if let string = params[key] as? String { return string.lowercased() == "true" }
        if let int = params[key] as? Int { return int != 0 }
        return nil
    }

    /// Registered tools by name
    private var tools: [String: any ExecutableTool.Type] = [:]

    /// Initialize with default tools
    private init() {
        registerDefaultTools()
    }

    /// Register default tools
    private func registerDefaultTools() {
        // Core file and shell tools
        register(ReadTool.self)
        register(WriteTool.self)
        register(EditTool.self)
        register(BashTool.self)
        register(GlobTool.self)
        register(GrepTool.self)

        // Advanced tools
        register(TaskTool.self)
        register(TodoWriteTool.self)
        register(WebFetchTool.self)
        register(EnterPlanModeTool.self)
        register(ExitPlanModeTool.self)
        register(AskUserQuestionTool.self)
    }

    /// Register a new tool
    func register<T: ExecutableTool>(_ tool: T.Type) {
        tools[T.name] = tool
    }

    /// Get a tool by name
    func tool(named name: String) -> (any ExecutableTool.Type)? {
        return tools[name]
    }

    /// Execute a tool by name with parameters
    func execute(toolName: String, parameters: [String: Any]) async throws -> String {
        guard let tool = tools[toolName] else {
            throw ToolError.toolNotFound(name: toolName)
        }
        return try await tool.execute(parameters: parameters)
    }

    /// Get all registered tools as OpenAI function tools
    func asOpenAITools() -> [OpenAI.Tool] {
        return tools.values.map { tool in
            .function(.init(
                name: tool.name,
                description: tool.description,
                parameters: tool.parametersSchema,
                callback: nil
            ))
        }
    }

    /// List all registered tool names
    var toolNames: [String] {
        return Array(tools.keys).sorted()
    }
}

/// Tool execution errors
enum ToolError: LocalizedError {
    case toolNotFound(name: String)
    case invalidParameters(tool: String, reason: String)
    case executionFailed(tool: String, reason: String)
    case missingRequiredParameter(tool: String, parameter: String)

    var errorDescription: String? {
        switch self {
        case .toolNotFound(let name):
            return "Tool not found: \(name)"
        case .invalidParameters(let tool, let reason):
            return "Invalid parameters for tool '\(tool)': \(reason)"
        case .executionFailed(let tool, let reason):
            return "Tool '\(tool)' execution failed: \(reason)"
        case .missingRequiredParameter(let tool, let parameter):
            return "Missing required parameter '\(parameter)' for tool '\(tool)'"
        }
    }
}

// MARK: - Parameter Extraction Helpers

extension Dictionary where Key == String, Value == Any {

    /// Get required string parameter
    func requiredString(_ key: String, tool: String) throws -> String {
        guard let value = self[key] else {
            throw ToolError.missingRequiredParameter(tool: tool, parameter: key)
        }
        guard let stringValue = value as? String else {
            throw ToolError.invalidParameters(tool: tool, reason: "\(key) must be a string")
        }
        return stringValue
    }

    /// Get optional string parameter
    func optionalString(_ key: String) -> String? {
        return self[key] as? String
    }

    /// Get optional integer parameter
    func optionalInt(_ key: String) -> Int? {
        if let intValue = self[key] as? Int {
            return intValue
        }
        if let doubleValue = self[key] as? Double {
            return Int(doubleValue)
        }
        return nil
    }

    /// Get optional boolean parameter
    func optionalBool(_ key: String) -> Bool? {
        return self[key] as? Bool
    }
}
