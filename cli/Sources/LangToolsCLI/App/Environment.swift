//
//  Environment.swift
//  CLI
//
//  Environment detection for working directory, git status, and system info
//

import Foundation

/// Runtime environment information
struct AppEnvironment {
    /// Current working directory
    let workingDirectory: String

    /// Current git branch if in a git repository
    let gitBranch: String?

    /// Whether the current directory is a git repository
    let isGitRepo: Bool

    /// Shortened working directory for display
    var shortWorkingDirectory: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if workingDirectory.hasPrefix(home) {
            return "~" + workingDirectory.dropFirst(home.count)
        }
        return workingDirectory
    }

    /// Initialize by detecting current environment
    static func detect() -> AppEnvironment {
        let cwd = FileManager.default.currentDirectoryPath
        let gitInfo = detectGitInfo(in: cwd)

        return AppEnvironment(
            workingDirectory: cwd,
            gitBranch: gitInfo.branch,
            isGitRepo: gitInfo.isRepo
        )
    }

    /// Detect git repository information
    private static func detectGitInfo(in directory: String) -> (isRepo: Bool, branch: String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["rev-parse", "--abbrev-ref", "HEAD"]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let branch = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return (true, branch)
            }
        } catch {
            // Not a git repository or git not available
        }

        return (false, nil)
    }

    /// Get git status summary
    static func getGitStatus(in directory: String) -> GitStatus? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["status", "--porcelain"]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                return GitStatus.parse(output)
            }
        } catch {
            // Git not available or not a repo
        }

        return nil
    }
}

/// Git repository status
struct GitStatus {
    var modified: Int = 0
    var added: Int = 0
    var deleted: Int = 0
    var untracked: Int = 0

    var isClean: Bool {
        modified == 0 && added == 0 && deleted == 0 && untracked == 0
    }

    var summary: String {
        if isClean {
            return "clean"
        }

        var parts: [String] = []
        if modified > 0 { parts.append("\(modified)M") }
        if added > 0 { parts.append("\(added)A") }
        if deleted > 0 { parts.append("\(deleted)D") }
        if untracked > 0 { parts.append("\(untracked)?") }
        return parts.joined(separator: " ")
    }

    static func parse(_ output: String) -> GitStatus {
        var status = GitStatus()

        for line in output.split(separator: "\n") {
            guard line.count >= 2 else { continue }
            let code = String(line.prefix(2))

            switch code {
            case " M", "M ", "MM":
                status.modified += 1
            case " A", "A ", "AM":
                status.added += 1
            case " D", "D ":
                status.deleted += 1
            case "??":
                status.untracked += 1
            default:
                break
            }
        }

        return status
    }
}

/// System information
struct SystemInfo {
    /// Platform name
    static var platform: String {
        #if os(macOS)
        return "macOS"
        #elseif os(Linux)
        return "Linux"
        #else
        return "Unknown"
        #endif
    }

    /// Swift version
    static var swiftVersion: String {
        #if swift(>=5.9)
        return "5.9+"
        #elseif swift(>=5.8)
        return "5.8"
        #else
        return "5.x"
        #endif
    }

    /// Current date formatted
    static var currentDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: Date())
    }
}
