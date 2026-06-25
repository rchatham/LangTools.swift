//
//  ReadTool.swift
//  CLI
//
//  Tool for reading file contents with line numbers
//

import Foundation
import OpenAI

/// Tool for reading files with line number display
struct ReadTool: ExecutableTool {
    static let name = "Read"

    static let description = """
    Reads a file from the local filesystem. Returns content with line numbers.
    The file_path parameter must be an absolute path.
    By default, reads up to 2000 lines starting from the beginning.
    Lines longer than 2000 characters will be truncated.
    """

    static let parametersSchema = OpenAI.Tool.FunctionSchema.Parameters(
        properties: [
            "file_path": .init(
                type: "string",
                description: "The absolute path to the file to read"
            ),
            "offset": .init(
                type: "integer",
                description: "The line number to start reading from (1-indexed, default: 1)"
            ),
            "limit": .init(
                type: "integer",
                description: "The number of lines to read (default: 2000)"
            )
        ],
        required: ["file_path"]
    )

    static func execute(parameters: [String: Any]) async throws -> String {
        let filePath = try parameters.requiredString("file_path", tool: name)
        let offset = parameters.optionalInt("offset") ?? 1
        let limit = parameters.optionalInt("limit") ?? 2000

        do {
            return try FileSystemService.readFile(at: filePath, offset: offset, limit: limit)
        } catch let error as FileSystemError {
            throw ToolError.executionFailed(tool: name, reason: error.localizedDescription)
        }
    }
}
