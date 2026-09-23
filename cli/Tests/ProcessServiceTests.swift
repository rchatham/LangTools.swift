//
//  ProcessServiceTests.swift
//  CLITests
//
//  Tests for shell and direct process execution
//

import Darwin
import Foundation
import XCTest
@testable import CLI

final class ProcessServiceTests: XCTestCase {
    func testExecuteSimpleCommand() async throws {
        let result = try await ProcessService.execute(command: "echo 'Hello, World!'")

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "Hello, World!\n")
        XCTAssertEqual(result.stderr, "")
    }

    func testExecutePreservesExitCodeAndSeparateStderr() async throws {
        let result = try await ProcessService.execute(
            command: "printf output; printf problem >&2; exit 42"
        )

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.exitCode, 42)
        XCTAssertEqual(result.stdout, "output")
        XCTAssertEqual(result.stderr, "problem")
    }

    func testExecuteWithWorkingDirectory() async throws {
        let result = try await ProcessService.execute(command: "pwd", workingDirectory: "/tmp")

        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.stdout == "/tmp\n" || result.stdout == "/private/tmp\n")
    }

    func testShellEnvironmentInheritsAndAppliesOverrides() async throws {
        let result = try await ProcessService.execute(
            command: "printf '%s|%s' \"$TEST_VAR\" \"${PATH:+inherited}\"",
            environment: ["TEST_VAR": "test_value"]
        )

        XCTAssertEqual(result.stdout, "test_value|inherited")
    }

    func testDirectExecutionUsesArgumentsLiterallyAndExactEnvironment() async throws {
        let argumentResult = try await ProcessService.execute(
            executable: "/bin/echo",
            arguments: ["$(printf expanded)"]
        )
        XCTAssertEqual(argumentResult.stdout, "$(printf expanded)\n")

        let environmentResult = try await ProcessService.execute(
            executable: "/usr/bin/env",
            environment: ["LANGTOOLS_PROCESS_TEST": "exact"]
        )
        XCTAssertEqual(environmentResult.stdout, "LANGTOOLS_PROCESS_TEST=exact\n")
    }

    func testConcurrentLargeStdoutAndStderrAreDrainedAndBounded() async throws {
        let emittedByteCount = ProcessService.maxCapturedOutputBytes + (256 * 1024)
        let command = """
        (/usr/bin/yes O | /usr/bin/head -c \(emittedByteCount)) &
        (/usr/bin/yes E | /usr/bin/head -c \(emittedByteCount)) >&2 &
        wait
        """

        let result = try await ProcessService.execute(command: command, timeout: 10)

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.stdout.utf8.count, ProcessService.maxCapturedOutputBytes)
        XCTAssertEqual(result.stderr.utf8.count, ProcessService.maxCapturedOutputBytes)
        XCTAssertTrue(result.stdoutCaptureLimitExceeded)
        XCTAssertTrue(result.stderrCaptureLimitExceeded)
        XCTAssertFalse(result.stdoutIncomplete)
        XCTAssertFalse(result.stderrIncomplete)
        XCTAssertTrue(result.stdout.hasPrefix("O\n"))
        XCTAssertTrue(result.stderr.hasPrefix("E\n"))
    }

    func testTimeoutKillsTermIgnoringProcessGroupIncludingDescendant() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let leaderFile = directory.appendingPathComponent("leader.pid")
        let childFile = directory.appendingPathComponent("child.pid")
        let command = termIgnoringProcessTreeCommand(leaderFile: leaderFile, childFile: childFile)
        let clock = ContinuousClock()
        let started = clock.now
        let task = Task {
            try await ProcessService.execute(command: command, timeout: 1)
        }

        guard let pids = await waitUntilPIDsAvailable([leaderFile, childFile]) else {
            task.cancel()
            _ = try? await task.value
            return XCTFail("Process tree did not become ready")
        }

        do {
            _ = try await task.value
            XCTFail("Expected timeout")
        } catch let error as ProcessError {
            guard case .timeout(_, let timeout) = error else {
                return XCTFail("Expected timeout, received \(error)")
            }
            XCTAssertEqual(timeout, 1, accuracy: 0.001)
        }

        let elapsed = started.duration(to: clock.now)
        XCTAssertTrue(elapsed >= .seconds(1), "Timeout returned too early: \(elapsed)")
        XCTAssertTrue(elapsed < .seconds(3), "Timeout cleanup took too long: \(elapsed)")
        let processesExited = await waitUntilProcessesExit(pids)
        XCTAssertTrue(processesExited, "Timed-out process group survived")
    }

    func testCancellationKillsTermIgnoringProcessGroupAndThrowsCancellationError() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let leaderFile = directory.appendingPathComponent("leader.pid")
        let childFile = directory.appendingPathComponent("child.pid")
        let command = termIgnoringProcessTreeCommand(leaderFile: leaderFile, childFile: childFile)
        let task = Task {
            try await ProcessService.execute(command: command, timeout: 10)
        }

        guard let pids = await waitUntilPIDsAvailable([leaderFile, childFile]) else {
            task.cancel()
            _ = try? await task.value
            return XCTFail("Process tree did not become ready")
        }

        let clock = ContinuousClock()
        let cancelled = clock.now
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, received \(error)")
        }

        let elapsed = cancelled.duration(to: clock.now)
        XCTAssertTrue(elapsed >= .milliseconds(200), "Cancellation returned too early: \(elapsed)")
        XCTAssertTrue(elapsed < .seconds(2), "Cancellation cleanup took too long: \(elapsed)")
        let processesExited = await waitUntilProcessesExit(pids)
        XCTAssertTrue(processesExited, "Cancelled process group survived")
    }

    func testForcedPipeClosureMarksDelayedDescendantOutputIncomplete() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let childFile = directory.appendingPathComponent("child.pid")
        let command = "(/bin/sleep 2; printf late) & pid=$!; echo $pid > '\(childFile.path).tmp'; /bin/mv '\(childFile.path).tmp' '\(childFile.path)'; printf done"
        let clock = ContinuousClock()
        let started = clock.now

        let result = try await ProcessService.execute(command: command, timeout: 5)
        let elapsed = started.duration(to: clock.now)

        let childPID = try readPID(from: childFile)
        XCTAssertEqual(result.stdout, "done")
        XCTAssertFalse(result.stdoutCaptureLimitExceeded)
        XCTAssertFalse(result.stderrCaptureLimitExceeded)
        XCTAssertTrue(result.stdoutIncomplete)
        XCTAssertTrue(result.stderrIncomplete)
        XCTAssertTrue(elapsed < .seconds(1), "Forced pipe closure took too long: \(elapsed)")
        let childExited = await waitUntilProcessExits(childPID)
        XCTAssertTrue(childExited, "Finite pipe-holder did not exit")
    }

    func testQuickCompletionDoesNotTriggerStaleTimeoutCallback() async throws {
        let result = try await ProcessService.execute(command: "printf quick", timeout: 0.5)
        XCTAssertEqual(result.stdout, "quick")
        try await Task.sleep(for: .milliseconds(600))
    }

    func testDisplayOutputTruncationPreservesExistingBehavior() {
        let result = ProcessResult(
            stdout: String(repeating: "x", count: 30_001),
            stderr: "",
            exitCode: 0,
            command: "test"
        )

        XCTAssertEqual(result.truncatedOutput.count, 30_023)
        XCTAssertTrue(result.truncatedOutput.hasSuffix("\n... (output truncated)"))
    }

    func testExecuteSimpleThrowsForNonzeroExit() async {
        do {
            _ = try await ProcessService.executeSimple(command: "printf failure >&2; exit 9")
            XCTFail("Expected nonzero error")
        } catch let error as ProcessError {
            guard case .nonZeroExit(_, let exitCode, let stderr) = error else {
                return XCTFail("Expected nonZeroExit, received \(error)")
            }
            XCTAssertEqual(exitCode, 9)
            XCTAssertEqual(stderr, "failure")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testDirectExecutionClosesUnmappedParentFileDescriptors() async throws {
        let descriptor = Darwin.open("/dev/null", O_RDONLY)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { Darwin.close(descriptor) }

        let result = try await ProcessService.execute(
            executable: "/bin/bash",
            arguments: [
                "-c",
                "if /bin/test -e /dev/fd/\(descriptor); then printf inherited; else printf closed; fi",
            ]
        )

        XCTAssertEqual(result.stdout, "closed")
    }

    func testInvalidWorkingDirectoryAndEnvironmentAreRejected() async {
        await assertInvalidSpawnInput {
            try await ProcessService.execute(
                executable: "/bin/echo",
                workingDirectory: "bad\0directory"
            )
        }
        await assertInvalidSpawnInput {
            try await ProcessService.execute(executable: "/usr/bin/env", environment: ["": "value"])
        }
        await assertInvalidSpawnInput {
            try await ProcessService.execute(
                executable: "/usr/bin/env",
                environment: ["BAD=KEY": "value"]
            )
        }
        await assertInvalidSpawnInput {
            try await ProcessService.execute(
                executable: "/usr/bin/env",
                environment: ["BAD\0KEY": "value"]
            )
        }
    }

    func testDirectLaunchFailureIsExecutionFailed() async {
        do {
            _ = try await ProcessService.execute(executable: "/definitely/not/an/executable")
            XCTFail("Expected launch failure")
        } catch let error as ProcessError {
            guard case .executionFailed = error else {
                return XCTFail("Expected executionFailed, received \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testExecutablePathUsesProvidedPATHWithoutLaunchingWhich() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("test-command")
        XCTAssertTrue(FileManager.default.createFile(atPath: executable.path, contents: Data()))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        XCTAssertEqual(
            ProcessService.executablePath(
                for: "test-command",
                environment: ["PATH": directory.path]
            ),
            executable.path
        )
        XCTAssertNil(
            ProcessService.executablePath(
                for: "missing-command",
                environment: ["PATH": directory.path]
            )
        )
        XCTAssertTrue(ProcessService.commandExists("ls"))
        XCTAssertFalse(ProcessService.commandExists("definitely_not_a_real_command_12345"))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProcessServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func termIgnoringProcessTreeCommand(leaderFile: URL, childFile: URL) -> String {
        """
        trap '' TERM
        echo $$ > '\(leaderFile.path).tmp'
        /bin/mv '\(leaderFile.path).tmp' '\(leaderFile.path)'
        /bin/bash -c 'trap "" TERM; echo $$ > "$1.tmp"; /bin/mv "$1.tmp" "$1"; /bin/sleep 5' bash '\(childFile.path)' &
        wait
        """
    }

    private func readPID(from file: URL) throws -> pid_t {
        let value = try String(contentsOf: file, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = pid_t(value) else {
            throw TestSupportError.invalidPID(value)
        }
        return pid
    }

    private func waitUntilPIDsAvailable(_ files: [URL]) async -> [pid_t]? {
        for _ in 0..<400 {
            let pids = files.compactMap { try? readPID(from: $0) }
            if pids.count == files.count, pids.allSatisfy(processExists) {
                return pids
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    private func waitUntilProcessesExit(_ pids: [pid_t]) async -> Bool {
        for _ in 0..<600 {
            if pids.allSatisfy({ processExists($0) == false }) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private func waitUntilProcessExits(_ pid: pid_t) async -> Bool {
        await waitUntilProcessesExit([pid])
    }

    private func processExists(_ pid: pid_t) -> Bool {
        if Darwin.kill(pid, 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    private func assertInvalidSpawnInput(
        _ operation: () async throws -> ProcessResult
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected invalid spawn input to fail")
        } catch let error as ProcessError {
            guard case .executionFailed(_, let underlying) = error else {
                return XCTFail("Expected executionFailed, received \(error)")
            }
            XCTAssertEqual((underlying as NSError).code, Int(EINVAL))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

private enum TestSupportError: Error {
    case invalidPID(String)
}
