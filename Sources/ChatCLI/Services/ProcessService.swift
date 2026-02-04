//
//  ProcessService.swift
//  ChatCLI
//
//  Shell command execution service for tool implementations
//

import Foundation

/// Service for executing shell commands
enum ProcessService {

    /// Default command timeout in seconds
    static let defaultTimeout: TimeInterval = 120

    /// Maximum allowed timeout in seconds
    static let maxTimeout: TimeInterval = 600

    /// Execute a shell command
    /// - Parameters:
    ///   - command: The command to execute
    ///   - workingDirectory: Optional working directory for the command
    ///   - timeout: Timeout in seconds (default: 120, max: 600)
    ///   - environment: Additional environment variables
    /// - Returns: Command result with stdout, stderr, and exit code
    static func execute(
        command: String,
        workingDirectory: String? = nil,
        timeout: TimeInterval = defaultTimeout,
        environment: [String: String]? = nil
    ) async throws -> ProcessResult {
        let effectiveTimeout = min(timeout, maxTimeout)

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", command]

            // Set working directory
            if let workingDirectory {
                process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
            }

            // Merge environment
            var processEnv = ProcessInfo.processInfo.environment
            if let additionalEnv = environment {
                for (key, value) in additionalEnv {
                    processEnv[key] = value
                }
            }
            process.environment = processEnv

            // Set up pipes
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            // Timeout handling
            var timedOut = false
            let timeoutWorkItem = DispatchWorkItem {
                timedOut = true
                process.terminate()
            }
            DispatchQueue.global().asyncAfter(
                deadline: .now() + effectiveTimeout,
                execute: timeoutWorkItem
            )

            // Run process
            do {
                try process.run()
                process.waitUntilExit()
                timeoutWorkItem.cancel()

                // Read output
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""

                if timedOut {
                    continuation.resume(throwing: ProcessError.timeout(
                        command: command,
                        timeout: effectiveTimeout
                    ))
                } else {
                    continuation.resume(returning: ProcessResult(
                        stdout: stdout,
                        stderr: stderr,
                        exitCode: Int(process.terminationStatus),
                        command: command
                    ))
                }
            } catch {
                timeoutWorkItem.cancel()
                continuation.resume(throwing: ProcessError.executionFailed(
                    command: command,
                    underlying: error
                ))
            }
        }
    }

    /// Execute a command and return combined output
    /// - Parameters:
    ///   - command: The command to execute
    ///   - workingDirectory: Optional working directory
    ///   - timeout: Timeout in seconds
    /// - Returns: Combined stdout and stderr output
    static func executeSimple(
        command: String,
        workingDirectory: String? = nil,
        timeout: TimeInterval = defaultTimeout
    ) async throws -> String {
        let result = try await execute(
            command: command,
            workingDirectory: workingDirectory,
            timeout: timeout
        )

        if result.exitCode != 0 {
            throw ProcessError.nonZeroExit(
                command: command,
                exitCode: result.exitCode,
                stderr: result.stderr
            )
        }

        return result.stdout
    }

    /// Check if a command exists in PATH
    static func commandExists(_ command: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [command]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

/// Result of a process execution
struct ProcessResult {
    let stdout: String
    let stderr: String
    let exitCode: Int
    let command: String

    /// Combined output (stdout + stderr)
    var combinedOutput: String {
        var result = stdout
        if !stderr.isEmpty {
            if !result.isEmpty {
                result += "\n"
            }
            result += stderr
        }
        return result
    }

    /// Whether the command succeeded (exit code 0)
    var succeeded: Bool {
        exitCode == 0
    }

    /// Truncated output for display (max 30000 characters)
    var truncatedOutput: String {
        let output = combinedOutput
        if output.count > 30000 {
            return String(output.prefix(30000)) + "\n... (output truncated)"
        }
        return output
    }
}

/// Process execution errors
enum ProcessError: LocalizedError {
    case timeout(command: String, timeout: TimeInterval)
    case executionFailed(command: String, underlying: Error)
    case nonZeroExit(command: String, exitCode: Int, stderr: String)
    case commandNotFound(command: String)

    var errorDescription: String? {
        switch self {
        case .timeout(let command, let timeout):
            return "Command timed out after \(Int(timeout))s: \(command)"
        case .executionFailed(let command, let underlying):
            return "Failed to execute command '\(command)': \(underlying.localizedDescription)"
        case .nonZeroExit(let command, let exitCode, let stderr):
            var message = "Command '\(command)' exited with code \(exitCode)"
            if !stderr.isEmpty {
                message += "\nStderr: \(stderr)"
            }
            return message
        case .commandNotFound(let command):
            return "Command not found: \(command)"
        }
    }
}
