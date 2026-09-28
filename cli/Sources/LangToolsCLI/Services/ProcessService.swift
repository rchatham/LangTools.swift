//
//  ProcessService.swift
//  CLI
//
//  Shell command execution service for tool implementations
//

import Darwin
import Foundation

/// Service for executing shell commands
enum ProcessService {

    /// Default command timeout in seconds
    static let defaultTimeout: TimeInterval = 120

    /// Maximum allowed timeout in seconds
    static let maxTimeout: TimeInterval = 600

    /// Maximum retained output per stream. Additional bytes are drained and discarded.
    static let maxCapturedOutputBytes = 4 * 1024 * 1024

    private static let terminationGracePeriod: TimeInterval = 0.25
    private static let pipeClosureGracePeriod: TimeInterval = 0.25

    /// Execute a shell command.
    ///
    /// The shell inherits the current environment and applies any provided overrides.
    static func execute(
        command: String,
        workingDirectory: String? = nil,
        timeout: TimeInterval = defaultTimeout,
        environment: [String: String]? = nil
    ) async throws -> ProcessResult {
        var processEnvironment = ProcessInfo.processInfo.environment
        if let environment {
            processEnvironment.merge(environment) { _, override in override }
        }

        return try await execute(
            executable: "/bin/bash",
            arguments: ["-c", command],
            workingDirectory: workingDirectory,
            timeout: timeout,
            environment: processEnvironment,
            commandDescription: command
        )
    }

    /// Execute an executable directly without invoking a shell.
    ///
    /// When `environment` is supplied it is used as an exact replacement. Passing
    /// `nil` snapshots and inherits the current process environment.
    static func execute(
        executable: String,
        arguments: [String] = [],
        workingDirectory: String? = nil,
        timeout: TimeInterval = defaultTimeout,
        environment: [String: String]? = nil
    ) async throws -> ProcessResult {
        try await execute(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            timeout: timeout,
            environment: environment ?? ProcessInfo.processInfo.environment,
            commandDescription: executable
        )
    }

    private static func execute(
        executable: String,
        arguments: [String],
        workingDirectory: String?,
        timeout: TimeInterval,
        environment: [String: String],
        commandDescription: String
    ) async throws -> ProcessResult {
        let effectiveTimeout = max(0, min(timeout, maxTimeout))
        let operation = ProcessExecutionOperation(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            commandDescription: commandDescription,
            timeout: effectiveTimeout,
            outputLimit: maxCapturedOutputBytes,
            terminationGracePeriod: terminationGracePeriod,
            pipeClosureGracePeriod: pipeClosureGracePeriod
        )

        return try await withTaskCancellationHandler {
            try await operation.run()
        } onCancel: {
            operation.cancel()
        }
    }

    /// Execute a command and return combined output.
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

    /// Resolve an executable using PATH without launching a helper process.
    static func executablePath(
        for command: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard command.isEmpty == false, command.contains("\0") == false else {
            return nil
        }

        if command.contains("/") {
            return isExecutableFile(atPath: command) ? command : nil
        }

        guard let path = environment["PATH"] else {
            return nil
        }

        for component in path.split(separator: ":", omittingEmptySubsequences: false) {
            let directory = component.isEmpty ? FileManager.default.currentDirectoryPath : String(component)
            let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(command)
                .path
            if isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Check if a command exists in PATH.
    static func commandExists(_ command: String) -> Bool {
        executablePath(for: command) != nil
    }

    private static func isExecutableFile(atPath path: String) -> Bool {
        var isDirectory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue == false
            && FileManager.default.isExecutableFile(atPath: path)
    }
}

/// Result of a process execution
struct ProcessResult {
    let stdout: String
    let stderr: String
    let exitCode: Int
    let command: String
    let stdoutCaptureLimitExceeded: Bool
    let stderrCaptureLimitExceeded: Bool
    let stdoutIncomplete: Bool
    let stderrIncomplete: Bool

    init(
        stdout: String,
        stderr: String,
        exitCode: Int,
        command: String,
        stdoutCaptureLimitExceeded: Bool = false,
        stderrCaptureLimitExceeded: Bool = false,
        stdoutIncomplete: Bool = false,
        stderrIncomplete: Bool = false
    ) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.command = command
        self.stdoutCaptureLimitExceeded = stdoutCaptureLimitExceeded
        self.stderrCaptureLimitExceeded = stderrCaptureLimitExceeded
        self.stdoutIncomplete = stdoutIncomplete
        self.stderrIncomplete = stderrIncomplete
    }

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

private struct CapturedProcessOutput: Sendable {
    let data: Data
    let captureLimitExceeded: Bool
    let wasIncomplete: Bool
}

private final class PipeDrainControl: @unchecked Sendable {
    private let lock = NSLock()
    private var closureDeadlineNanoseconds: UInt64?

    func processDidExit(after gracePeriod: TimeInterval) {
        let delay = UInt64(max(0, gracePeriod) * 1_000_000_000)
        lock.lock()
        closureDeadlineNanoseconds = DispatchTime.now().uptimeNanoseconds &+ delay
        lock.unlock()
    }

    func millisecondsUntilForcedClosure(maximum: Int32) -> Int32? {
        lock.lock()
        let deadline = closureDeadlineNanoseconds
        lock.unlock()

        guard let deadline else {
            return maximum
        }

        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline else {
            return nil
        }
        let remainingMilliseconds = max(1, Int32((deadline - now) / 1_000_000))
        return min(maximum, remainingMilliseconds)
    }
}

private final class ProcessLifecycle: @unchecked Sendable {
    enum ForcedTermination {
        case timeout
        case cancellation
    }

    private let lock = NSLock()
    private let terminationGracePeriod: TimeInterval
    private var launchID: UUID?
    private var processGroupID: pid_t?
    private var leaderExited = false
    private var leaderReaped = false
    private var finished = false
    private var forcedTermination: ForcedTermination?
    private var escalationScheduled = false
    private var escalationCompleted = false
    private var escalationWaiters: [CheckedContinuation<Void, Never>] = []

    init(terminationGracePeriod: TimeInterval) {
        self.terminationGracePeriod = terminationGracePeriod
    }

    func register(processGroupID: pid_t, launchID: UUID) {
        lock.lock()
        guard finished == false else {
            lock.unlock()
            return
        }
        self.processGroupID = processGroupID
        self.launchID = launchID
        let action = terminationActionIfNeededLocked()
        lock.unlock()
        perform(action)
    }

    func requestTimeout(launchID: UUID) {
        lock.lock()
        guard finished == false,
              leaderExited == false,
              leaderReaped == false,
              self.launchID == launchID,
              forcedTermination == nil
        else {
            lock.unlock()
            return
        }
        forcedTermination = .timeout
        let action = terminationActionIfNeededLocked()
        lock.unlock()
        perform(action)
    }

    func requestCancellation() {
        lock.lock()
        guard finished == false,
              leaderExited == false,
              leaderReaped == false,
              forcedTermination == nil
        else {
            lock.unlock()
            return
        }
        forcedTermination = .cancellation
        let action = terminationActionIfNeededLocked()
        lock.unlock()
        perform(action)
    }

    func markLeaderExited(launchID: UUID) {
        lock.lock()
        if finished == false, self.launchID == launchID {
            leaderExited = true
        }
        lock.unlock()
    }

    func forcedTerminationAfterLeaderExit() -> ForcedTermination? {
        lock.lock()
        defer { lock.unlock() }
        return forcedTermination
    }

    func markLeaderReapedAndFinished(launchID: UUID) {
        lock.lock()
        if self.launchID == launchID {
            leaderReaped = true
            finished = true
            self.launchID = nil
            processGroupID = nil
        }
        lock.unlock()
    }

    func cancellationWasRequestedBeforeLaunchCompleted() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return forcedTermination == .cancellation
    }

    func waitForEscalation() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            guard escalationCompleted == false else {
                lock.unlock()
                continuation.resume()
                return
            }
            escalationWaiters.append(continuation)
            lock.unlock()
        }
    }

    private struct TerminationAction {
        let processGroupID: pid_t
        let launchID: UUID
    }

    private func terminationActionIfNeededLocked() -> TerminationAction? {
        guard forcedTermination != nil,
              leaderExited == false,
              leaderReaped == false,
              escalationScheduled == false,
              let processGroupID,
              let launchID
        else {
            return nil
        }
        escalationScheduled = true
        return TerminationAction(processGroupID: processGroupID, launchID: launchID)
    }

    private func perform(_ action: TerminationAction?) {
        guard let action else { return }
        _ = Darwin.kill(-action.processGroupID, SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + terminationGracePeriod
        ) { [weak self] in
            self?.forceKillIfCurrent(action)
        }
    }

    private func forceKillIfCurrent(_ action: TerminationAction) {
        lock.lock()
        let shouldKill = finished == false
            && leaderReaped == false
            && launchID == action.launchID
            && processGroupID == action.processGroupID
            && forcedTermination != nil
        lock.unlock()

        if shouldKill {
            // If the leader has exited, waitid(WNOWAIT) keeps it as a zombie,
            // preventing its PID/process-group ID from being reused until this
            // final group-wide escalation has completed.
            _ = Darwin.kill(-action.processGroupID, SIGKILL)
        }

        lock.lock()
        if launchID == action.launchID, escalationCompleted == false {
            escalationCompleted = true
            let waiters = escalationWaiters
            escalationWaiters.removeAll()
            lock.unlock()
            waiters.forEach { $0.resume() }
        } else {
            lock.unlock()
        }
    }
}

private final class ProcessExecutionOperation: @unchecked Sendable {
    private let executable: String
    private let arguments: [String]
    private let workingDirectory: String?
    private let environment: [String: String]
    private let commandDescription: String
    private let timeout: TimeInterval
    private let outputLimit: Int
    private let pipeClosureGracePeriod: TimeInterval
    private let lifecycle: ProcessLifecycle

    init(
        executable: String,
        arguments: [String],
        workingDirectory: String?,
        environment: [String: String],
        commandDescription: String,
        timeout: TimeInterval,
        outputLimit: Int,
        terminationGracePeriod: TimeInterval,
        pipeClosureGracePeriod: TimeInterval
    ) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.commandDescription = commandDescription
        self.timeout = timeout
        self.outputLimit = outputLimit
        self.pipeClosureGracePeriod = pipeClosureGracePeriod
        self.lifecycle = ProcessLifecycle(terminationGracePeriod: terminationGracePeriod)
    }

    func cancel() {
        lifecycle.requestCancellation()
    }

    func run() async throws -> ProcessResult {
        if Task.isCancelled {
            lifecycle.requestCancellation()
            throw CancellationError()
        }

        let launchID = UUID()
        let spawned: SpawnedProcess
        do {
            spawned = try spawn()
        } catch {
            if Task.isCancelled || lifecycle.cancellationWasRequestedBeforeLaunchCompleted() {
                throw CancellationError()
            }
            throw ProcessError.executionFailed(command: commandDescription, underlying: error)
        }

        lifecycle.register(processGroupID: spawned.pid, launchID: launchID)
        let drainControl = PipeDrainControl()
        async let stdout = Self.drain(
            fileDescriptor: spawned.stdoutRead,
            limit: outputLimit,
            control: drainControl
        )
        async let stderr = Self.drain(
            fileDescriptor: spawned.stderrRead,
            limit: outputLimit,
            control: drainControl
        )

        let timeoutWorkItem = DispatchWorkItem { [weak lifecycle] in
            lifecycle?.requestTimeout(launchID: launchID)
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + timeout,
            execute: timeoutWorkItem
        )

        let exitObservation = await Self.observeProcessExit(
            spawned.pid,
            lifecycle: lifecycle,
            launchID: launchID
        )
        timeoutWorkItem.cancel()

        let forcedTermination = lifecycle.forcedTerminationAfterLeaderExit()
        if forcedTermination != nil {
            // Keep the observed leader unreaped until the group-wide KILL has
            // run. Its zombie reserves the PID/process-group ID, so the delayed
            // escalation cannot target a reused process group.
            await lifecycle.waitForEscalation()
        }

        let rawStatus = await Self.reapProcess(spawned.pid)
        lifecycle.markLeaderReapedAndFinished(launchID: launchID)
        drainControl.processDidExit(after: pipeClosureGracePeriod)

        let capturedStdout = await stdout
        let capturedStderr = await stderr

        if let forcedTermination {
            switch forcedTermination {
            case .timeout:
                throw ProcessError.timeout(command: commandDescription, timeout: timeout)
            case .cancellation:
                throw CancellationError()
            }
        }

        if case .failure(let error) = exitObservation {
            throw ProcessError.executionFailed(command: commandDescription, underlying: error)
        }

        switch rawStatus {
        case .success(let status):
            return ProcessResult(
                stdout: String(decoding: capturedStdout.data, as: UTF8.self),
                stderr: String(decoding: capturedStderr.data, as: UTF8.self),
                exitCode: Self.terminationStatus(status),
                command: commandDescription,
                stdoutCaptureLimitExceeded: capturedStdout.captureLimitExceeded,
                stderrCaptureLimitExceeded: capturedStderr.captureLimitExceeded,
                stdoutIncomplete: capturedStdout.wasIncomplete,
                stderrIncomplete: capturedStderr.wasIncomplete
            )
        case .failure(let error):
            throw ProcessError.executionFailed(command: commandDescription, underlying: error)
        }
    }

    private struct SpawnedProcess {
        let pid: pid_t
        let stdoutRead: Int32
        let stderrRead: Int32
    }

    private func spawn() throws -> SpawnedProcess {
        try Self.validateSpawnInputs(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment
        )

        let stdoutPipe = try Self.makePipe()
        let stderrPipe: (read: Int32, write: Int32)
        do {
            stderrPipe = try Self.makePipe()
        } catch {
            Darwin.close(stdoutPipe.read)
            Darwin.close(stdoutPipe.write)
            throw error
        }

        var preserveReadDescriptors = false
        defer {
            Darwin.close(stdoutPipe.write)
            Darwin.close(stderrPipe.write)
            if preserveReadDescriptors == false {
                Darwin.close(stdoutPipe.read)
                Darwin.close(stderrPipe.read)
            }
        }

        var fileActions: posix_spawn_file_actions_t?
        let actionsResult = posix_spawn_file_actions_init(&fileActions)
        guard actionsResult == 0 else {
            throw Self.posixError(actionsResult)
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        if let workingDirectory {
            let chdirResult = posix_spawn_file_actions_addchdir_np(&fileActions, workingDirectory)
            guard chdirResult == 0 else {
                throw Self.posixError(chdirResult)
            }
        }

        var actionResults: [Int32] = []
        if Darwin.fcntl(STDIN_FILENO, F_GETFD) >= 0 {
            actionResults.append(
                posix_spawn_file_actions_addinherit_np(&fileActions, STDIN_FILENO)
            )
        }
        actionResults.append(contentsOf: [
            posix_spawn_file_actions_adddup2(&fileActions, stdoutPipe.write, STDOUT_FILENO),
            posix_spawn_file_actions_adddup2(&fileActions, stderrPipe.write, STDERR_FILENO),
            posix_spawn_file_actions_addclose(&fileActions, stdoutPipe.read),
            posix_spawn_file_actions_addclose(&fileActions, stderrPipe.read),
            posix_spawn_file_actions_addclose(&fileActions, stdoutPipe.write),
            posix_spawn_file_actions_addclose(&fileActions, stderrPipe.write),
        ])
        if let failure = actionResults.first(where: { $0 != 0 }) {
            throw Self.posixError(failure)
        }

        var attributes: posix_spawnattr_t?
        let attributesResult = posix_spawnattr_init(&attributes)
        guard attributesResult == 0 else {
            throw Self.posixError(attributesResult)
        }
        defer { posix_spawnattr_destroy(&attributes) }

        let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
        let flagsResult = posix_spawnattr_setflags(&attributes, flags)
        guard flagsResult == 0 else {
            throw Self.posixError(flagsResult)
        }
        let groupResult = posix_spawnattr_setpgroup(&attributes, 0)
        guard groupResult == 0 else {
            throw Self.posixError(groupResult)
        }

        let argumentStrings = [executable] + arguments
        var argumentPointers = try Self.makeCStringArray(argumentStrings)
        defer { Self.freeCStringArray(argumentPointers) }
        let environmentStrings = environment
            .map { "\($0.key)=\($0.value)" }
            .sorted()
        var environmentPointers = try Self.makeCStringArray(environmentStrings)
        defer { Self.freeCStringArray(environmentPointers) }

        var pid: pid_t = 0
        let spawnResult = argumentPointers.withUnsafeMutableBufferPointer { argumentBuffer in
            environmentPointers.withUnsafeMutableBufferPointer { environmentBuffer in
                posix_spawn(
                    &pid,
                    executable,
                    &fileActions,
                    &attributes,
                    argumentBuffer.baseAddress,
                    environmentBuffer.baseAddress
                )
            }
        }
        guard spawnResult == 0 else {
            throw Self.posixError(spawnResult)
        }

        preserveReadDescriptors = true
        return SpawnedProcess(
            pid: pid,
            stdoutRead: stdoutPipe.read,
            stderrRead: stderrPipe.read
        )
    }

    private static func validateSpawnInputs(
        executable: String,
        arguments: [String],
        workingDirectory: String?,
        environment: [String: String]
    ) throws {
        guard executable.contains("\0") == false,
              arguments.allSatisfy({ $0.contains("\0") == false }),
              workingDirectory?.contains("\0") != true,
              environment.allSatisfy({ key, value in
                  key.isEmpty == false
                      && key.contains("=") == false
                      && key.contains("\0") == false
                      && value.contains("\0") == false
              })
        else {
            throw posixError(EINVAL)
        }
    }

    private static func makePipe() throws -> (read: Int32, write: Int32) {
        var descriptors = [Int32](repeating: 0, count: 2)
        guard Darwin.pipe(&descriptors) == 0 else {
            throw posixError(errno)
        }

        do {
            descriptors[0] = try moveAboveStandardDescriptors(descriptors[0])
            descriptors[1] = try moveAboveStandardDescriptors(descriptors[1])
            return (descriptors[0], descriptors[1])
        } catch {
            Darwin.close(descriptors[0])
            Darwin.close(descriptors[1])
            throw error
        }
    }

    private static func moveAboveStandardDescriptors(_ descriptor: Int32) throws -> Int32 {
        if descriptor > STDERR_FILENO {
            guard Darwin.fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
                throw posixError(errno)
            }
            return descriptor
        }

        let duplicated = Darwin.fcntl(descriptor, F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
        guard duplicated >= 0 else {
            throw posixError(errno)
        }
        Darwin.close(descriptor)
        return duplicated
    }

    private static func makeCStringArray(_ strings: [String]) throws -> [UnsafeMutablePointer<CChar>?] {
        var pointers: [UnsafeMutablePointer<CChar>?] = []
        pointers.reserveCapacity(strings.count + 1)
        for string in strings {
            guard string.contains("\0") == false, let pointer = strdup(string) else {
                freeCStringArray(pointers)
                throw posixError(EINVAL)
            }
            pointers.append(pointer)
        }
        pointers.append(nil)
        return pointers
    }

    private static func freeCStringArray(_ pointers: [UnsafeMutablePointer<CChar>?]) {
        pointers.forEach { pointer in
            if let pointer {
                free(pointer)
            }
        }
    }

    private static func drain(
        fileDescriptor: Int32,
        limit: Int,
        control: PipeDrainControl
    ) async -> CapturedProcessOutput {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                defer { Darwin.close(fileDescriptor) }
                let existingFlags = Darwin.fcntl(fileDescriptor, F_GETFL)
                if existingFlags >= 0 {
                    _ = Darwin.fcntl(fileDescriptor, F_SETFL, existingFlags | O_NONBLOCK)
                }

                var retained = Data()
                retained.reserveCapacity(min(limit, 64 * 1024))
                var captureLimitExceeded = false
                var wasIncomplete = false
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)

                while true {
                    guard control.millisecondsUntilForcedClosure(maximum: 50) != nil else {
                        // The process leader exited but a descendant kept this pipe
                        // open. The retained bytes may be a complete leader response,
                        // but EOF was not observed before the safety deadline.
                        wasIncomplete = true
                        break
                    }

                    let bytesRead = Darwin.read(fileDescriptor, &buffer, buffer.count)
                    if bytesRead > 0 {
                        let count = Int(bytesRead)
                        let remaining = max(0, limit - retained.count)
                        if remaining > 0 {
                            retained.append(contentsOf: buffer.prefix(min(count, remaining)))
                        }
                        if count > remaining {
                            captureLimitExceeded = true
                        }
                        continue
                    }
                    if bytesRead == 0 {
                        break
                    }
                    if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                        break
                    }
                    if errno == EINTR {
                        continue
                    }

                    guard let pollTimeout = control.millisecondsUntilForcedClosure(maximum: 50) else {
                        wasIncomplete = true
                        break
                    }
                    var descriptor = pollfd(
                        fd: fileDescriptor,
                        events: Int16(POLLIN | POLLHUP | POLLERR),
                        revents: 0
                    )
                    _ = Darwin.poll(&descriptor, 1, pollTimeout)
                }

                continuation.resume(returning: CapturedProcessOutput(
                    data: retained,
                    captureLimitExceeded: captureLimitExceeded,
                    wasIncomplete: wasIncomplete
                ))
            }
        }
    }

    private static func observeProcessExit(
        _ pid: pid_t,
        lifecycle: ProcessLifecycle,
        launchID: UUID
    ) async -> Result<Void, Error> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var information = siginfo_t()
                var result: Int32
                repeat {
                    result = Darwin.waitid(
                        P_PID,
                        id_t(pid),
                        &information,
                        WEXITED | WNOWAIT
                    )
                } while result == -1 && errno == EINTR

                // This lock transition arbitrates leader exit against timeout
                // and cancellation. The WNOWAIT zombie remains unreaped until
                // any already-active escalation has safely signaled the group.
                lifecycle.markLeaderExited(launchID: launchID)
                if result == 0 {
                    continuation.resume(returning: .success(()))
                } else {
                    continuation.resume(returning: .failure(posixError(errno)))
                }
            }
        }
    }

    private static func reapProcess(_ pid: pid_t) async -> Result<Int32, Error> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var status: Int32 = 0
                var result: pid_t
                repeat {
                    result = Darwin.waitpid(pid, &status, 0)
                } while result == -1 && errno == EINTR

                if result == pid {
                    continuation.resume(returning: .success(status))
                } else {
                    continuation.resume(returning: .failure(posixError(errno)))
                }
            }
        }
    }

    private static func terminationStatus(_ rawStatus: Int32) -> Int {
        let signal = rawStatus & 0x7f
        return Int(signal == 0 ? (rawStatus >> 8) & 0xff : signal)
    }

    private static func posixError(_ code: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}
