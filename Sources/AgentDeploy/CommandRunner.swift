//
//  CommandRunner.swift
//  AgentDeploy
//
//  Runs the external tools the deploy commands drive: `doctl` and `ssh`.
//

import Foundation

public struct CommandOutput: Equatable {
    public var status: Int32
    public var stdout: Data
    public var stderr: Data

    public init(status: Int32, stdout: Data = Data(), stderr: Data = Data()) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }

    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrString: String { String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
}

public protocol CommandRunner {
    /// Runs `executable` (looked up on PATH) with `arguments`, feeding `stdin` if given.
    func run(_ executable: String, _ arguments: [String], stdin: Data?) async throws -> CommandOutput
}

extension CommandRunner {
    /// Runs the command and returns its output, throwing when it exits non-zero.
    func checked(_ executable: String, _ arguments: [String], stdin: Data? = nil) async throws -> CommandOutput {
        let output = try await run(executable, arguments, stdin: stdin)
        // /usr/bin/env exits 127 when it can't find the executable.
        if output.status == 127, output.stderrString.hasPrefix("/usr/bin/env:") {
            throw DeployError.invalidArgument("Could not find `\(executable)`. Install it and make sure it is on PATH.")
        }
        guard output.status == 0 else { throw DeployError.commandFailed(executable: executable, status: output.status, message: output.stderrString) }
        return output
    }
}

public enum DeployError: Error, LocalizedError, Equatable {
    case commandFailed(executable: String, status: Int32, message: String)
    case invalidArgument(String)
    case workerNotFound(String)
    case workerExists(String)
    case notReady(String)
    case unexpectedOutput(String)

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let executable, let status, let message):
            return "\(executable) exited with status \(status)\(message.isEmpty ? "" : ": \(message)")"
        case .invalidArgument(let message), .notReady(let message), .unexpectedOutput(let message):
            return message
        case .workerNotFound(let name):
            return "No worker named '\(name)'. Run `langtools-agent-deploy list` to see workers."
        case .workerExists(let name):
            return "A worker named '\(name)' already exists."
        }
    }
}

#if os(macOS) || os(Linux)
/// Runs commands with `Process`, resolving the executable through `/usr/bin/env`.
public struct ProcessCommandRunner: CommandRunner {
    public init() {}

    // Writing to a pipe whose reader has exited raises SIGPIPE, which would end this process.
    // Ignored once, writes to a closed pipe fail with EPIPE instead.
    private static let ignoreBrokenPipe: Void = { signal(SIGPIPE, SIG_IGN) }()

    public func run(_ executable: String, _ arguments: [String], stdin: Data?) async throws -> CommandOutput {
        _ = Self.ignoreBrokenPipe
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments
            let stdoutPipe = Pipe(), stderrPipe = Pipe(), stdinPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            process.standardInput = stdin == nil ? FileHandle.nullDevice : stdinPipe

            // Pipes are drained on their own threads so a chatty command can't fill one and block.
            let group = DispatchGroup()
            let out = LockedData(), err = LockedData()
            group.enter()
            DispatchQueue.global().async { out.set(stdoutPipe.fileHandleForReading.readDataToEndOfFile()); group.leave() }
            group.enter()
            DispatchQueue.global().async { err.set(stderrPipe.fileHandleForReading.readDataToEndOfFile()); group.leave() }

            process.terminationHandler = { process in
                group.notify(queue: .global()) {
                    continuation.resume(returning: CommandOutput(status: process.terminationStatus, stdout: out.value, stderr: err.value))
                }
            }
            do {
                try process.run()
            } catch {
                stdoutPipe.fileHandleForWriting.closeFile()
                stderrPipe.fileHandleForWriting.closeFile()
                continuation.resume(throwing: error)
                return
            }
            if let stdin {
                DispatchQueue.global().async {
                    // A child that exits without reading all of stdin closes the pipe; that's
                    // its business, and its exit status reports it, so the error is ignored.
                    try? stdinPipe.fileHandleForWriting.write(contentsOf: stdin)
                    try? stdinPipe.fileHandleForWriting.close()
                }
            }
        }
    }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    var value: Data { lock.lock(); defer { lock.unlock() }; return data }
    func set(_ newValue: Data) { lock.lock(); data = newValue; lock.unlock() }
}
#endif
