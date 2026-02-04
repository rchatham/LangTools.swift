//
//  FileSystemService.swift
//  ChatCLI
//
//  File system operations service for tool implementations
//

import Foundation

/// Service for file system operations
enum FileSystemService {

    // MARK: - Reading

    /// Read file contents with line numbers
    /// - Parameters:
    ///   - path: Absolute path to the file
    ///   - offset: Line number to start from (1-indexed, default: 1)
    ///   - limit: Maximum number of lines to read (default: 2000)
    /// - Returns: Content with line numbers formatted as "   N\t content"
    static func readFile(at path: String, offset: Int = 1, limit: Int = 2000) throws -> String {
        let url = URL(fileURLWithPath: path)

        // Check if file exists
        guard FileManager.default.fileExists(atPath: path) else {
            throw FileSystemError.fileNotFound(path: path)
        }

        // Check if it's a directory
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        if isDirectory.boolValue {
            throw FileSystemError.isDirectory(path: path)
        }

        // Read file contents
        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines)

        // Apply offset and limit
        let startIndex = max(0, offset - 1)
        let endIndex = min(lines.count, startIndex + limit)

        guard startIndex < lines.count else {
            throw FileSystemError.offsetOutOfRange(offset: offset, totalLines: lines.count)
        }

        // Format with line numbers
        var result: [String] = []
        for (index, line) in lines[startIndex..<endIndex].enumerated() {
            let lineNumber = startIndex + index + 1
            let truncatedLine = line.count > 2000 ? String(line.prefix(2000)) + "..." : line
            result.append(String(format: "%5d\t%@", lineNumber, truncatedLine))
        }

        return result.joined(separator: "\n")
    }

    // MARK: - Writing

    /// Write content to a file, creating parent directories if needed
    /// - Parameters:
    ///   - path: Absolute path to the file
    ///   - content: Content to write
    static func writeFile(at path: String, content: String) throws {
        let url = URL(fileURLWithPath: path)

        // Create parent directories if needed
        let parentDir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        // Write content
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Editing

    /// Replace exact string in file
    /// - Parameters:
    ///   - path: Absolute path to the file
    ///   - oldString: Exact text to find
    ///   - newString: Replacement text
    ///   - replaceAll: Whether to replace all occurrences
    /// - Returns: Number of replacements made
    static func editFile(at path: String, oldString: String, newString: String, replaceAll: Bool = false) throws -> Int {
        let url = URL(fileURLWithPath: path)

        // Read current content
        guard FileManager.default.fileExists(atPath: path) else {
            throw FileSystemError.fileNotFound(path: path)
        }

        var content = try String(contentsOf: url, encoding: .utf8)

        // Count occurrences
        let occurrences = content.components(separatedBy: oldString).count - 1

        if occurrences == 0 {
            throw FileSystemError.stringNotFound(search: oldString)
        }

        if occurrences > 1 && !replaceAll {
            throw FileSystemError.stringNotUnique(search: oldString, occurrences: occurrences)
        }

        // Perform replacement
        if replaceAll {
            content = content.replacingOccurrences(of: oldString, with: newString)
        } else {
            if let range = content.range(of: oldString) {
                content.replaceSubrange(range, with: newString)
            }
        }

        // Write back
        try content.write(to: url, atomically: true, encoding: .utf8)

        return replaceAll ? occurrences : 1
    }

    // MARK: - Glob

    /// Find files matching a glob pattern
    /// - Parameters:
    ///   - pattern: Glob pattern (e.g., "**/*.swift")
    ///   - basePath: Base directory for the search
    /// - Returns: Array of matching file paths sorted by modification time (newest first)
    static func glob(pattern: String, in basePath: String) throws -> [String] {
        let baseURL = URL(fileURLWithPath: basePath)

        guard FileManager.default.fileExists(atPath: basePath) else {
            throw FileSystemError.directoryNotFound(path: basePath)
        }

        // Convert glob pattern to regex
        let regexPattern = globToRegex(pattern)

        // Find all files
        var matchingFiles: [(path: String, modTime: Date)] = []

        if let enumerator = FileManager.default.enumerator(
            at: baseURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            while let url = enumerator.nextObject() as? URL {
                let resourceValues = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])

                guard resourceValues?.isRegularFile == true else { continue }

                let relativePath = url.path.replacingOccurrences(of: basePath + "/", with: "")

                if matches(relativePath, pattern: regexPattern) {
                    let modTime = resourceValues?.contentModificationDate ?? Date.distantPast
                    matchingFiles.append((url.path, modTime))
                }
            }
        }

        // Sort by modification time (newest first)
        return matchingFiles
            .sorted { $0.modTime > $1.modTime }
            .map { $0.path }
    }

    /// Convert glob pattern to regex
    private static func globToRegex(_ pattern: String) -> String {
        var regex = "^"
        var i = pattern.startIndex

        while i < pattern.endIndex {
            let c = pattern[i]
            switch c {
            case "*":
                let next = pattern.index(after: i)
                if next < pattern.endIndex && pattern[next] == "*" {
                    // ** matches any path including /
                    regex += ".*"
                    i = pattern.index(after: next)
                    continue
                } else {
                    // * matches any non-/ characters
                    regex += "[^/]*"
                }
            case "?":
                regex += "[^/]"
            case ".":
                regex += "\\."
            case "/":
                regex += "/"
            default:
                if "[]{}()^$|+\\".contains(c) {
                    regex += "\\\(c)"
                } else {
                    regex += String(c)
                }
            }
            i = pattern.index(after: i)
        }

        regex += "$"
        return regex
    }

    /// Check if path matches regex pattern
    private static func matches(_ path: String, pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return false
        }
        let range = NSRange(path.startIndex..., in: path)
        return regex.firstMatch(in: path, options: [], range: range) != nil
    }

    // MARK: - Grep

    /// Search for regex pattern in files
    /// - Parameters:
    ///   - pattern: Regex pattern to search for
    ///   - path: Directory or file to search in
    ///   - fileGlob: Optional glob pattern to filter files
    ///   - contextBefore: Lines before match to include
    ///   - contextAfter: Lines after match to include
    /// - Returns: Array of matches with file, line number, and content
    static func grep(
        pattern: String,
        in path: String,
        fileGlob: String? = nil,
        contextBefore: Int = 0,
        contextAfter: Int = 0
    ) throws -> [GrepMatch] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            throw FileSystemError.invalidRegex(pattern: pattern)
        }

        var matches: [GrepMatch] = []

        // Determine files to search
        var filesToSearch: [String] = []

        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)

        if isDirectory.boolValue {
            let globPattern = fileGlob ?? "**/*"
            filesToSearch = try glob(pattern: globPattern, in: path)
        } else {
            filesToSearch = [path]
        }

        // Search each file
        for filePath in filesToSearch {
            guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else {
                continue
            }

            let lines = content.components(separatedBy: .newlines)

            for (lineIndex, line) in lines.enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                if regex.firstMatch(in: line, options: [], range: range) != nil {
                    // Collect context lines
                    var contextLines: [String] = []

                    // Before context
                    let beforeStart = max(0, lineIndex - contextBefore)
                    for i in beforeStart..<lineIndex {
                        contextLines.append(lines[i])
                    }

                    // Match line
                    contextLines.append(line)

                    // After context
                    let afterEnd = min(lines.count, lineIndex + contextAfter + 1)
                    for i in (lineIndex + 1)..<afterEnd {
                        contextLines.append(lines[i])
                    }

                    matches.append(GrepMatch(
                        file: filePath,
                        lineNumber: lineIndex + 1,
                        content: line,
                        context: contextLines
                    ))
                }
            }
        }

        return matches
    }
}

/// Grep match result
struct GrepMatch {
    let file: String
    let lineNumber: Int
    let content: String
    let context: [String]
}

/// File system errors
enum FileSystemError: LocalizedError {
    case fileNotFound(path: String)
    case directoryNotFound(path: String)
    case isDirectory(path: String)
    case offsetOutOfRange(offset: Int, totalLines: Int)
    case stringNotFound(search: String)
    case stringNotUnique(search: String, occurrences: Int)
    case invalidRegex(pattern: String)
    case permissionDenied(path: String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .directoryNotFound(let path):
            return "Directory not found: \(path)"
        case .isDirectory(let path):
            return "Path is a directory, not a file: \(path)"
        case .offsetOutOfRange(let offset, let totalLines):
            return "Offset \(offset) is out of range. File has \(totalLines) lines."
        case .stringNotFound(let search):
            return "String not found: \(search)"
        case .stringNotUnique(let search, let occurrences):
            return "String '\(search)' found \(occurrences) times. Use replace_all=true or provide more context."
        case .invalidRegex(let pattern):
            return "Invalid regex pattern: \(pattern)"
        case .permissionDenied(let path):
            return "Permission denied: \(path)"
        }
    }
}
