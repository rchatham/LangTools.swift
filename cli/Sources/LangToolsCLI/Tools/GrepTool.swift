//
//  GrepTool.swift
//  CLI
//
//  Tool for regex-based content search
//

import Foundation
import OpenAI

/// Tool for searching file contents using regex
struct GrepTool: ExecutableTool {
    static let name = "Grep"

    static let description = """
    A powerful search tool for finding patterns in file contents.
    Supports full regex syntax (e.g., "log.*Error", "function\\s+\\w+").
    Filter files with glob parameter or type parameter.
    Returns matching lines with file paths and line numbers.
    """

    static let parametersSchema = OpenAI.Tool.FunctionSchema.Parameters(
        properties: [
            "pattern": .init(
                type: "string",
                description: "The regex pattern to search for in file contents"
            ),
            "path": .init(
                type: "string",
                description: "File or directory to search in (default: current directory)"
            ),
            "glob": .init(
                type: "string",
                description: "Glob pattern to filter files (e.g., '*.swift')"
            ),
            "context_before": .init(
                type: "integer",
                description: "Number of lines to show before each match"
            ),
            "context_after": .init(
                type: "integer",
                description: "Number of lines to show after each match"
            ),
            "output_mode": .init(
                type: "string",
                description: "Output mode: 'content' (default), 'files_with_matches', or 'count'"
            ),
            "limit": .init(
                type: "integer",
                description: "Maximum number of matches to return (default: 100)"
            )
        ],
        required: ["pattern"]
    )

    static func execute(parameters: [String: Any]) async throws -> String {
        let pattern = try parameters.requiredString("pattern", tool: name)
        let path = parameters.optionalString("path")
            ?? FileManager.default.currentDirectoryPath
        let glob = parameters.optionalString("glob")
        let contextBefore = parameters.optionalInt("context_before") ?? 0
        let contextAfter = parameters.optionalInt("context_after") ?? 0
        let outputMode = parameters.optionalString("output_mode") ?? "content"
        let limit = parameters.optionalInt("limit") ?? 100

        do {
            let matches = try FileSystemService.grep(
                pattern: pattern,
                in: path,
                fileGlob: glob,
                contextBefore: contextBefore,
                contextAfter: contextAfter
            )

            if matches.isEmpty {
                return "No matches found for pattern '\(pattern)'"
            }

            // Format based on output mode
            switch outputMode {
            case "files_with_matches":
                return formatFilesOnly(matches: matches, limit: limit)
            case "count":
                return formatCount(matches: matches)
            default:
                return formatContent(matches: matches, limit: limit, hasContext: contextBefore > 0 || contextAfter > 0)
            }
        } catch let error as FileSystemError {
            throw ToolError.executionFailed(tool: name, reason: error.localizedDescription)
        }
    }

    private static func formatContent(matches: [GrepMatch], limit: Int, hasContext: Bool) -> String {
        var result = "Found \(matches.count) match(es):\n\n"
        var currentFile = ""

        for match in matches.prefix(limit) {
            if match.file != currentFile {
                currentFile = match.file
                result += "─── \(match.file) ───\n"
            }

            if hasContext {
                for (index, line) in match.context.enumerated() {
                    let lineNum = match.lineNumber - (match.context.count - index - 1) + index
                    let prefix = index == match.context.count - 1 - match.context.count / 2 ? ">" : " "
                    result += "\(prefix) \(lineNum): \(line)\n"
                }
                result += "\n"
            } else {
                result += "  \(match.lineNumber): \(match.content)\n"
            }
        }

        if matches.count > limit {
            result += "\n... and \(matches.count - limit) more matches"
        }

        return result
    }

    private static func formatFilesOnly(matches: [GrepMatch], limit: Int) -> String {
        let uniqueFiles = Array(Set(matches.map { $0.file })).sorted()
        var result = "Found matches in \(uniqueFiles.count) file(s):\n"

        for file in uniqueFiles.prefix(limit) {
            let count = matches.filter { $0.file == file }.count
            result += "  \(file) (\(count) matches)\n"
        }

        if uniqueFiles.count > limit {
            result += "\n... and \(uniqueFiles.count - limit) more files"
        }

        return result
    }

    private static func formatCount(matches: [GrepMatch]) -> String {
        let fileGroups = Dictionary(grouping: matches) { $0.file }
        var result = "Match counts by file:\n"

        for (file, fileMatches) in fileGroups.sorted(by: { $0.value.count > $1.value.count }) {
            result += "  \(fileMatches.count): \(file)\n"
        }

        result += "\nTotal: \(matches.count) matches in \(fileGroups.count) files"
        return result
    }
}
