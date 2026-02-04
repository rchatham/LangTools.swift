//
//  WriteTool.swift
//  ChatCLI
//
//  Tool for writing files
//

import Foundation
import OpenAI

/// Tool for creating or overwriting files
struct WriteTool: ExecutableTool {
    static let name = "Write"

    static let description = """
    Writes content to a file on the local filesystem.
    The file_path parameter must be an absolute path.
    This tool will overwrite existing files and create parent directories if needed.
    """

    static let parametersSchema = OpenAI.Tool.FunctionSchema.Parameters(
        properties: [
            "file_path": .init(
                type: "string",
                description: "The absolute path to the file to write"
            ),
            "content": .init(
                type: "string",
                description: "The content to write to the file"
            )
        ],
        required: ["file_path", "content"]
    )

    static func execute(parameters: [String: Any]) async throws -> String {
        let filePath = try parameters.requiredString("file_path", tool: name)
        let content = try parameters.requiredString("content", tool: name)

        // Check if file exists for appropriate message
        let fileExists = FileManager.default.fileExists(atPath: filePath)

        do {
            try FileSystemService.writeFile(at: filePath, content: content)

            let lineCount = content.components(separatedBy: .newlines).count
            let action = fileExists ? "Updated" : "Created"
            return "\(action) file: \(filePath) (\(lineCount) lines)"
        } catch {
            throw ToolError.executionFailed(tool: name, reason: error.localizedDescription)
        }
    }
}
