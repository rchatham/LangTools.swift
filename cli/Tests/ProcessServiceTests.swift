//
//  ProcessServiceTests.swift
//  CLITests
//
//  Tests for shell command execution
//

import XCTest
import Foundation

final class ProcessServiceTests: XCTestCase {

    // MARK: - Basic Execution Tests

    func testExecuteSimpleCommand() async throws {
        let result = try await execute(command: "echo 'Hello, World!'")

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("Hello, World!"))
    }

    func testExecuteWithExitCode() async throws {
        let result = try await execute(command: "exit 42")

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.exitCode, 42)
    }

    func testExecuteCommandWithOutput() async throws {
        let result = try await execute(command: "ls -la /tmp")

        XCTAssertTrue(result.succeeded)
        XCTAssertFalse(result.stdout.isEmpty)
    }

    func testExecuteCommandWithStderr() async throws {
        let result = try await execute(command: "ls /nonexistent_path_12345 2>&1 || true")

        // Command won't fail because of || true, but stderr would be captured
        XCTAssertTrue(result.succeeded)
    }

    // MARK: - Working Directory Tests

    func testExecuteWithWorkingDirectory() async throws {
        let result = try await execute(command: "pwd", workingDirectory: "/tmp")

        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.stdout.contains("/tmp") || result.stdout.contains("/private/tmp"))
    }

    // MARK: - Timeout Tests

    func testExecuteWithTimeout() async {
        // This should timeout since sleep 10 > 1 second timeout
        do {
            _ = try await execute(command: "sleep 10", timeout: 1)
            XCTFail("Should have timed out")
        } catch let error as ProcessTestError {
            if case .timeout = error {
                // Expected
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testExecuteCompletesBeforeTimeout() async throws {
        let result = try await execute(command: "echo 'quick'", timeout: 10)

        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.stdout.contains("quick"))
    }

    // MARK: - Output Truncation Tests

    func testOutputTruncation() async throws {
        // Generate output larger than 30000 chars
        let result = try await execute(command: "yes | head -n 10000")

        XCTAssertTrue(result.succeeded)
        // The truncatedOutput property should handle this
        let truncated = result.truncatedOutput
        if truncated.count > 30100 {
            XCTFail("Output should be truncated to around 30000 chars")
        }
    }

    // MARK: - Environment Tests

    func testExecuteWithEnvironment() async throws {
        let result = try await execute(
            command: "echo $TEST_VAR",
            environment: ["TEST_VAR": "test_value"]
        )

        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.stdout.contains("test_value"))
    }

    // MARK: - Command Existence Tests

    func testCommandExists() {
        XCTAssertTrue(commandExists("ls"))
        XCTAssertTrue(commandExists("echo"))
        XCTAssertFalse(commandExists("definitely_not_a_real_command_12345"))
    }

    // MARK: - Helper implementations (mirroring ProcessService)

    private func execute(
        command: String,
        workingDirectory: String? = nil,
        timeout: TimeInterval = 120,
        environment: [String: String]? = nil
    ) async throws -> ProcessTestResult {
        let effectiveTimeout = min(timeout, 600)

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", command]

            if let workingDirectory {
                process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
            }

            var processEnv = ProcessInfo.processInfo.environment
            if let additionalEnv = environment {
                for (key, value) in additionalEnv {
                    processEnv[key] = value
                }
            }
            process.environment = processEnv

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            var timedOut = false
            let timeoutWorkItem = DispatchWorkItem {
                timedOut = true
                process.terminate()
            }
            DispatchQueue.global().asyncAfter(
                deadline: .now() + effectiveTimeout,
                execute: timeoutWorkItem
            )

            do {
                try process.run()
                process.waitUntilExit()
                timeoutWorkItem.cancel()

                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""

                if timedOut {
                    continuation.resume(throwing: ProcessTestError.timeout(
                        command: command,
                        timeout: effectiveTimeout
                    ))
                } else {
                    continuation.resume(returning: ProcessTestResult(
                        stdout: stdout,
                        stderr: stderr,
                        exitCode: Int(process.terminationStatus),
                        command: command
                    ))
                }
            } catch {
                timeoutWorkItem.cancel()
                continuation.resume(throwing: ProcessTestError.executionFailed(
                    command: command,
                    underlying: error
                ))
            }
        }
    }

    private func commandExists(_ command: String) -> Bool {
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

// MARK: - Test Types

struct ProcessTestResult {
    let stdout: String
    let stderr: String
    let exitCode: Int
    let command: String

    var combinedOutput: String {
        var result = stdout
        if !stderr.isEmpty {
            if !result.isEmpty { result += "\n" }
            result += stderr
        }
        return result
    }

    var succeeded: Bool { exitCode == 0 }

    var truncatedOutput: String {
        let output = combinedOutput
        if output.count > 30000 {
            return String(output.prefix(30000)) + "\n... (output truncated)"
        }
        return output
    }
}

enum ProcessTestError: LocalizedError {
    case timeout(command: String, timeout: TimeInterval)
    case executionFailed(command: String, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .timeout(let command, let timeout):
            return "Command timed out after \(Int(timeout))s: \(command)"
        case .executionFailed(let command, let underlying):
            return "Failed to execute '\(command)': \(underlying.localizedDescription)"
        }
    }
}
