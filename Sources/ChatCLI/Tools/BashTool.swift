//
//  BashTool.swift
//  ChatCLI
//
//  Tool for executing shell commands
//

import Foundation
import OpenAI

/// Tool for executing bash commands
struct BashTool: ExecutableTool {
    static let name = "Bash"

    static let description = """
    Executes a bash command with optional timeout.
    The command runs in a bash shell with the user's environment.
    Output is truncated if it exceeds 30000 characters.
    Default timeout is 120 seconds, maximum is 600 seconds.
    """

    static let parametersSchema = OpenAI.Tool.FunctionSchema.Parameters(
        properties: [
            "command": .init(
                type: "string",
                description: "The bash command to execute"
            ),
            "timeout": .init(
                type: "integer",
                description: "Optional timeout in seconds (default: 120, max: 600)"
            ),
            "working_directory": .init(
                type: "string",
                description: "Optional working directory for the command"
            )
        ],
        required: ["command"]
    )

    static func execute(parameters: [String: Any]) async throws -> String {
        let command = try parameters.requiredString("command", tool: name)
        let timeoutSeconds = parameters.optionalInt("timeout") ?? 120
        let workingDirectory = parameters.optionalString("working_directory")

        // Validate timeout
        let effectiveTimeout = min(max(timeoutSeconds, 1), 600)

        do {
            let result = try await ProcessService.execute(
                command: command,
                workingDirectory: workingDirectory,
                timeout: TimeInterval(effectiveTimeout)
            )

            var output = result.truncatedOutput

            // Add exit code info if non-zero
            if !result.succeeded {
                output += "\n\nExit code: \(result.exitCode)"
            }

            return output.isEmpty ? "(no output)" : output
        } catch let error as ProcessError {
            throw ToolError.executionFailed(tool: name, reason: error.localizedDescription)
        }
    }
}
