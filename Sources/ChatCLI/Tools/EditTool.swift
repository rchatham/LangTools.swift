//
//  EditTool.swift
//  ChatCLI
//
//  Tool for performing exact string replacements in files
//

import Foundation
import OpenAI

/// Tool for editing files via exact string replacement
struct EditTool: ExecutableTool {
    static let name = "Edit"

    static let description = """
    Performs exact string replacements in files.
    The edit will FAIL if old_string is not unique in the file unless replace_all is true.
    Preserves file permissions and encoding.
    """

    static let parametersSchema = OpenAI.Tool.FunctionSchema.Parameters(
        properties: [
            "file_path": .init(
                type: "string",
                description: "The absolute path to the file to modify"
            ),
            "old_string": .init(
                type: "string",
                description: "The exact text to replace (must be unique unless replace_all is true)"
            ),
            "new_string": .init(
                type: "string",
                description: "The text to replace it with"
            ),
            "replace_all": .init(
                type: "boolean",
                description: "Replace all occurrences instead of just the first (default: false)"
            )
        ],
        required: ["file_path", "old_string", "new_string"]
    )

    static func execute(parameters: [String: Any]) async throws -> String {
        let filePath = try parameters.requiredString("file_path", tool: name)
        let oldString = try parameters.requiredString("old_string", tool: name)
        let newString = try parameters.requiredString("new_string", tool: name)
        let replaceAll = parameters.optionalBool("replace_all") ?? false

        // Validate that old_string and new_string are different
        guard oldString != newString else {
            throw ToolError.invalidParameters(
                tool: name,
                reason: "old_string and new_string must be different"
            )
        }

        do {
            let replacements = try FileSystemService.editFile(
                at: filePath,
                oldString: oldString,
                newString: newString,
                replaceAll: replaceAll
            )

            if replaceAll {
                return "Replaced \(replacements) occurrence(s) in \(filePath)"
            } else {
                return "Replaced 1 occurrence in \(filePath)"
            }
        } catch let error as FileSystemError {
            throw ToolError.executionFailed(tool: name, reason: error.localizedDescription)
        }
    }
}
