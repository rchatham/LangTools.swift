//
//  GlobTool.swift
//  CLI
//
//  Tool for pattern-based file matching
//

import Foundation
import OpenAI

/// Tool for finding files using glob patterns
struct GlobTool: ExecutableTool {
    static let name = "Glob"

    static let description = """
    Fast file pattern matching tool that works with any codebase size.
    Supports glob patterns like "**/*.swift" or "src/**/*.ts".
    Returns matching file paths sorted by modification time (newest first).
    """

    static let parametersSchema = OpenAI.Tool.FunctionSchema.Parameters(
        properties: [
            "pattern": .init(
                type: "string",
                description: "The glob pattern to match files against (e.g., '**/*.swift')"
            ),
            "path": .init(
                type: "string",
                description: "The directory to search in (default: current working directory)"
            )
        ],
        required: ["pattern"]
    )

    static func execute(parameters: [String: Any]) async throws -> String {
        let pattern = try parameters.requiredString("pattern", tool: name)
        let basePath = parameters.optionalString("path")
            ?? FileManager.default.currentDirectoryPath

        do {
            let files = try FileSystemService.glob(pattern: pattern, in: basePath)

            if files.isEmpty {
                return "No files matching pattern '\(pattern)' found in \(basePath)"
            }

            // Format output
            var result = "Found \(files.count) file(s):\n"
            for file in files.prefix(100) { // Limit to 100 results
                result += "  \(file)\n"
            }

            if files.count > 100 {
                result += "\n... and \(files.count - 100) more files"
            }

            return result
        } catch let error as FileSystemError {
            throw ToolError.executionFailed(tool: name, reason: error.localizedDescription)
        }
    }
}
