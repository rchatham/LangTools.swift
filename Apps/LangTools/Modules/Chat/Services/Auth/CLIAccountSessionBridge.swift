import Foundation
#if os(macOS)
import Darwin
#endif

public protocol CommandRunning {
    func run(executable: String, arguments: [String]) async throws -> CommandResult
}

public struct CommandResult: Equatable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
}

public enum CLIAccountSessionBridgeError: LocalizedError, Equatable {
    case cliUnavailable
    case unsupportedPlatform
    case sandboxRequiresPrebuiltCLI
    case commandFailed(String)
    case commandCancelled
    case commandTimedOut
    case invalidSessionData
    case invalidChatResponse

    public var errorDescription: String? {
        switch self {
        case .cliUnavailable:
            return "langtools is not available. Build/install it first."
        case .unsupportedPlatform:
            return "langtools is only available on macOS."
        case .sandboxRequiresPrebuiltCLI:
            return "langtools must be provided as a prebuilt executable when the app is sandboxed. Set LANGTOOLS_AUTH_CLI_PATH or bundle the CLI binary with the app."
        case .commandFailed(let message):
            return message
        case .commandCancelled:
            return "The langtools command was cancelled."
        case .commandTimedOut:
            return "The langtools command timed out."
        case .invalidSessionData:
            return "langtools returned invalid session data."
        case .invalidChatResponse:
            return "langtools returned an invalid chat response."
        }
    }
}

public protocol OpenAIAccountChatBridging {
    func performOpenAIChat(messages: [Message], model: Model) async throws -> Message
}

public struct CLIAccountSessionBridge: OpenAIAccountChatBridging {
    private let runner: CommandRunning
    private let decoder: JSONDecoder
    private let logger: CLIBridgeLogger

    public init(runner: CommandRunning = ProcessRunner(), logger: CLIBridgeLogger = CLIBridgeLogger()) {
        self.runner = runner
        self.logger = logger
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public func loginOpenAI() async throws -> AccountSession {
        let command = try resolveCommand()
        let loginResult = try await runLogged(
            command: command,
            extraArguments: ["auth", "login", "openai"],
            action: "OpenAI login",
            outputVisibility: .redacted
        )
        guard loginResult.status == 0 else {
            throw CLIAccountSessionBridgeError.commandFailed(commandFailureMessage(for: loginResult, action: "OpenAI login", executable: command.executable))
        }
        return try await exportOpenAISession(using: command)
    }

    public func logoutOpenAI() async throws {
        let command = try resolveCommand()
        let result = try await runLogged(
            command: command,
            extraArguments: ["auth", "logout", "openai"],
            action: "OpenAI logout",
            outputVisibility: .metadataOnly
        )
        guard result.status == 0 else {
            throw CLIAccountSessionBridgeError.commandFailed(commandFailureMessage(for: result, action: "OpenAI logout", executable: command.executable))
        }
    }

    public func exportOpenAISession() async throws -> AccountSession {
        try await exportOpenAISession(using: resolveCommand())
    }

    public func performOpenAIChat(messages: [Message], model: Model) async throws -> Message {
        let command = try resolveCommand()
        let requestFileURL = try writeOpenAIChatRequestFile(messages: messages)
        defer { try? FileManager.default.removeItem(at: requestFileURL.deletingLastPathComponent()) }

        let arguments = command.arguments + ["openai-chat", "--model", model.slug, "--messages-file", requestFileURL.path]
        let result = try await runner.run(executable: command.executable, arguments: arguments)
        if logger.isChatResponseLoggingEnabled {
            logger.log(
                action: "OpenAI chat",
                executable: command.executable,
                arguments: arguments,
                result: result,
                outputVisibility: .metadataOnly
            )
        }
        guard result.status == 0 else {
            throw CLIAccountSessionBridgeError.commandFailed(
                commandFailureMessage(
                    for: result,
                    action: "OpenAI chat",
                    executable: command.executable,
                    includeLogReference: false
                )
            )
        }
        guard let data = result.stdout.data(using: .utf8) else {
            throw CLIAccountSessionBridgeError.invalidChatResponse
        }
        let decoder = JSONDecoder()
        guard let response = try? decoder.decode(OpenAIChatCLIResponse.self, from: data) else {
            throw CLIAccountSessionBridgeError.invalidChatResponse
        }
        return Message(text: response.content, role: .assistant)
    }

    private func exportOpenAISession(using command: ResolvedCommand) async throws -> AccountSession {
        let result = try await runLogged(
            command: command,
            extraArguments: ["auth", "export-session", "openai", "--format", "json"],
            action: "OpenAI session export",
            outputVisibility: .redacted
        )
        guard result.status == 0 else {
            throw CLIAccountSessionBridgeError.commandFailed(commandFailureMessage(for: result, action: "OpenAI session export", executable: command.executable))
        }
        guard let data = result.stdout.data(using: .utf8) else {
            throw CLIAccountSessionBridgeError.invalidSessionData
        }
        do {
            return try decoder.decode(AccountSession.self, from: data)
        } catch {
            throw CLIAccountSessionBridgeError.invalidSessionData
        }
    }

    private func writeOpenAIChatRequestFile(messages: [Message]) throws -> URL {
        let payload = OpenAIChatCLIRequestFile(
            messages: messages.map { message in
                OpenAIChatCLIMessage(
                    role: message.role,
                    content: serializedContent(for: message),
                    contentKind: serializedContentKind(for: message)
                )
            }
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(payload)
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "langtools-openai-chat-request-\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o700))],
                ofItemAtPath: directoryURL.path
            )
            let fileURL = directoryURL.appendingPathComponent("request.json")
            guard FileManager.default.createFile(
                atPath: fileURL.path,
                contents: data,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]
            ) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: fileURL.path])
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: fileURL.path
            )
            return fileURL
        } catch {
            try? FileManager.default.removeItem(at: directoryURL)
            throw error
        }
    }

    private func commandFailureMessage(
        for result: CommandResult,
        action: String,
        executable: String,
        includeLogReference: Bool = true
    ) -> String {
        // Helper output may contain exported sessions, tokens, or provider error
        // payloads, so it is never included in app-visible errors.
        let base = "\(action) failed: langtools exited with status \(result.status) at \(executable)."
        guard includeLogReference else { return base }
        return "\(base) See \(logger.logFilePath) for redacted helper diagnostics."
    }

    private func runLogged(
        command: ResolvedCommand,
        extraArguments: [String],
        action: String,
        outputVisibility: CLIBridgeLogOutputVisibility = .plain
    ) async throws -> CommandResult {
        let arguments = command.arguments + extraArguments
        let result = try await runner.run(executable: command.executable, arguments: arguments)
        logger.log(action: action, executable: command.executable, arguments: arguments, result: result, outputVisibility: outputVisibility)
        return result
    }

    private func serializedContent(for message: Message) -> String {
        if let text = message.text, text.isEmpty == false {
            return text
        }

        switch message.contentType {
        case .agentEvent(let content):
            return content.formattedText
        case .contentCards(let cards):
            if let message = cards.message, message.isEmpty == false {
                return message
            }
            return "Structured content cards (\(cards.cardType)), count: \(cards.cardCount)"
        case .array(let items):
            return items.joined(separator: "\n")
        case .string(let text):
            return text
        case .null:
            return "[No content]"
        }
    }

    private func serializedContentKind(for message: Message) -> String? {
        switch message.contentType {
        case .agentEvent:
            return "agentEvent"
        case .contentCards:
            return "contentCards"
        case .array:
            return "array"
        case .string:
            return "string"
        case .null:
            return "null"
        }
    }

    private func resolveCommand() throws -> ResolvedCommand {
        if let explicitPath = ProcessInfo.processInfo.environment["LANGTOOLS_AUTH_CLI_PATH"], explicitPath.isEmpty == false {
            return ResolvedCommand(executable: explicitPath, arguments: [])
        }

        for candidate in bundledCandidatePaths() where FileManager.default.isExecutableFile(atPath: candidate) {
            return ResolvedCommand(executable: candidate, arguments: [])
        }

        let examplePackageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Auth
            .deletingLastPathComponent() // Services
            .deletingLastPathComponent() // Chat
            .deletingLastPathComponent() // Modules
            .deletingLastPathComponent() // LangTools_Example

        let repoRoot = examplePackageRoot.deletingLastPathComponent().deletingLastPathComponent()
        let cliPackageRoot = repoRoot.appendingPathComponent("cli")

        let binaryPath = cliPackageRoot
            .appendingPathComponent(".build")
            .appendingPathComponent("debug")
            .appendingPathComponent("langtools")

        if FileManager.default.isExecutableFile(atPath: binaryPath.path) {
            return ResolvedCommand(executable: binaryPath.path, arguments: [])
        }

        if isSandboxed {
            throw CLIAccountSessionBridgeError.sandboxRequiresPrebuiltCLI
        }

        return ResolvedCommand(
            executable: "/usr/bin/env",
            arguments: ["swift", "run", "--package-path", cliPackageRoot.path, "langtools"]
        )
    }

    private var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"]?.isEmpty == false
    }

    private func bundledCandidatePaths() -> [String] {
        Self.bundledCandidatePaths(bundleURL: Bundle.main.bundleURL)
    }

    static func bundledCandidatePaths(bundleURL: URL) -> [String] {
        let contentsURL = bundleURL.appendingPathComponent("Contents")
        return [
            bundleURL.appendingPathComponent("langtools").path,
            bundleURL.appendingPathComponent("Contents/MacOS/langtools").path,
            bundleURL.appendingPathComponent("Contents/Helpers/langtools").path,
            contentsURL.appendingPathComponent("MacOS/langtools").path,
            contentsURL.appendingPathComponent("Helpers/langtools").path,
        ]
    }
}

private struct ResolvedCommand {
    let executable: String
    let arguments: [String]
}

private struct OpenAIChatCLIRequestFile: Codable {
    let messages: [OpenAIChatCLIMessage]
}

private struct OpenAIChatCLIMessage: Codable {
    let role: Role
    let content: String
    let contentKind: String?
}

private struct OpenAIChatCLIResponse: Codable {
    let content: String
}

public enum CLIBridgeLogOutputVisibility {
    case plain
    case redacted
    case metadataOnly
}

public struct CLIBridgeLogger {
    private let fileURL: URL
    private let formatter: ISO8601DateFormatter
    public let isChatResponseLoggingEnabled: Bool

    public init(fileURL: URL? = nil, logChatResponses: Bool? = nil) {
        self.formatter = ISO8601DateFormatter()
        self.formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.isChatResponseLoggingEnabled = logChatResponses
            ?? (ProcessInfo.processInfo.environment["LANGTOOLS_LOG_CHAT_METADATA"] == "1")

        if let fileURL {
            self.fileURL = fileURL
        } else {
            let baseDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let logsDirectory = baseDirectory
                .appendingPathComponent("LangTools_Example", isDirectory: true)
                .appendingPathComponent("Logs", isDirectory: true)
            try? FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
            self.fileURL = logsDirectory.appendingPathComponent("langtools-bridge.log")
        }
    }

    public var logFilePath: String {
        fileURL.path
    }

    public func log(
        action: String,
        executable: String,
        arguments: [String],
        result: CommandResult,
        outputVisibility: CLIBridgeLogOutputVisibility = .plain
    ) {
        let stdout = formattedOutput(result.stdout, visibility: outputVisibility)
        let stderr = formattedOutput(result.stderr, visibility: outputVisibility)
        let lines = [
            "[\(formatter.string(from: Date()))] \(action)",
            "executable: \(executable)",
            "arguments: \(arguments.joined(separator: " "))",
            "status: \(result.status)",
            "stdout:",
            stdout,
            "stderr:",
            stderr,
            String(repeating: "-", count: 80)
        ]
        let entry = lines.joined(separator: "\n") + "\n"

        if let data = entry.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: fileURL.path) == false {
                FileManager.default.createFile(atPath: fileURL.path, contents: data)
            } else if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        }

        NSLog("%@", entry)
    }

    private func formattedOutput(_ text: String, visibility: CLIBridgeLogOutputVisibility) -> String {
        switch visibility {
        case .plain:
            return text.isEmpty ? "<empty>" : text
        case .redacted:
            return text.isEmpty ? "<empty>" : "<redacted>"
        case .metadataOnly:
            return "<\(text.utf8.count) bytes>"
        }
    }
}

public struct ProcessRunner: CommandRunning {
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 330) {
        self.timeout = timeout
    }

    public func run(executable: String, arguments: [String]) async throws -> CommandResult {
        #if os(macOS)
        let operation = ProcessRunOperation(executable: executable, arguments: arguments, timeout: timeout)
        return try await withTaskCancellationHandler {
            try await operation.run()
        } onCancel: {
            operation.cancel()
        }
        #else
        throw CLIAccountSessionBridgeError.unsupportedPlatform
        #endif
    }
}

#if os(macOS)
private final class ProcessRunOperation: @unchecked Sendable {
    private let executable: String
    private let arguments: [String]
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var processGroupID: pid_t?
    private var continuation: CheckedContinuation<CommandResult, Error>?
    private var timeoutWorkItem: DispatchWorkItem?
    private var killWorkItem: DispatchWorkItem?
    private var forcedError: Error?
    private var hasFinished = false
    private var stdoutData = Data()
    private var stderrData = Data()

    init(executable: String, arguments: [String], timeout: TimeInterval) {
        self.executable = executable
        self.arguments = arguments
        self.timeout = timeout
    }

    func run() async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let forcedError {
                lock.unlock()
                continuation.resume(throwing: forcedError)
                return
            }
            self.continuation = continuation
            lock.unlock()

            let stdout = Pipe()
            let stderr = Pipe()
            let pid: pid_t
            do {
                pid = try spawn(stdout: stdout, stderr: stderr)
            } catch {
                stdout.fileHandleForWriting.closeFile()
                stderr.fileHandleForWriting.closeFile()
                finish(throwing: CLIAccountSessionBridgeError.cliUnavailable)
                return
            }
            stdout.fileHandleForWriting.closeFile()
            stderr.fileHandleForWriting.closeFile()

            lock.lock()
            processGroupID = pid
            let shouldAbort = forcedError != nil
            lock.unlock()

            let drains = DispatchGroup()
            drains.enter()
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.recordStdout(stdout.fileHandleForReading.readDataToEndOfFile())
                drains.leave()
            }
            drains.enter()
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.recordStderr(stderr.fileHandleForReading.readDataToEndOfFile())
                drains.leave()
            }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                var rawStatus: Int32 = 0
                _ = Darwin.waitpid(pid, &rawStatus, 0)
                drains.notify(queue: .global(qos: .utility)) {
                    self?.complete(status: Self.terminationStatus(rawStatus))
                }
            }

            // Cancellation can arrive while posix_spawn is running. Recheck
            // after registering the atomically-created child process group.
            if shouldAbort {
                terminateProcessGroup(pid)
            }
            scheduleTimeout()
        }
    }

    func cancel() {
        forceStop(with: CLIAccountSessionBridgeError.commandCancelled)
    }

    private func spawn(stdout: Pipe, stderr: Pipe) throws -> pid_t {
        var fileActions: posix_spawn_file_actions_t? = nil
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            throw CLIAccountSessionBridgeError.cliUnavailable
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        let stdoutRead = stdout.fileHandleForReading.fileDescriptor
        let stdoutWrite = stdout.fileHandleForWriting.fileDescriptor
        let stderrRead = stderr.fileHandleForReading.fileDescriptor
        let stderrWrite = stderr.fileHandleForWriting.fileDescriptor
        guard posix_spawn_file_actions_adddup2(&fileActions, stdoutWrite, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&fileActions, stderrWrite, STDERR_FILENO) == 0,
              posix_spawn_file_actions_addclose(&fileActions, stdoutRead) == 0,
              posix_spawn_file_actions_addclose(&fileActions, stderrRead) == 0,
              posix_spawn_file_actions_addclose(&fileActions, stdoutWrite) == 0,
              posix_spawn_file_actions_addclose(&fileActions, stderrWrite) == 0
        else {
            throw CLIAccountSessionBridgeError.cliUnavailable
        }

        var attributes: posix_spawnattr_t? = nil
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw CLIAccountSessionBridgeError.cliUnavailable
        }
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = Int16(POSIX_SPAWN_SETPGROUP)
        guard posix_spawnattr_setflags(&attributes, flags) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0
        else {
            throw CLIAccountSessionBridgeError.cliUnavailable
        }

        var argumentPointers = ([executable] + arguments).map { strdup($0) }
        defer { argumentPointers.forEach { free($0) } }
        argumentPointers.append(nil)

        var environmentPointers = ProcessInfo.processInfo.environment.map { key, value in
            strdup("\(key)=\(value)")
        }
        defer { environmentPointers.forEach { free($0) } }
        environmentPointers.append(nil)

        var pid: pid_t = 0
        let spawnResult = argumentPointers.withUnsafeMutableBufferPointer { argumentsBuffer in
            environmentPointers.withUnsafeMutableBufferPointer { environmentBuffer in
                posix_spawn(
                    &pid,
                    executable,
                    &fileActions,
                    &attributes,
                    argumentsBuffer.baseAddress!,
                    environmentBuffer.baseAddress!
                )
            }
        }
        guard spawnResult == 0 else {
            throw CLIAccountSessionBridgeError.cliUnavailable
        }
        return pid
    }

    private func scheduleTimeout() {
        guard timeout > 0 else {
            forceStop(with: CLIAccountSessionBridgeError.commandTimedOut)
            return
        }
        let workItem = DispatchWorkItem { [weak self] in
            self?.forceStop(with: CLIAccountSessionBridgeError.commandTimedOut)
        }
        lock.lock()
        guard hasFinished == false else {
            lock.unlock()
            return
        }
        timeoutWorkItem = workItem
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: workItem)
    }

    private func forceStop(with error: Error) {
        lock.lock()
        guard hasFinished == false, forcedError == nil else {
            lock.unlock()
            return
        }
        forcedError = error
        let groupID = processGroupID
        lock.unlock()

        guard let groupID else { return }
        terminateProcessGroup(groupID)
    }

    private func terminateProcessGroup(_ groupID: pid_t) {
        // Wrappers such as `swift run` can outlive their immediate parent and
        // retain stdout/stderr pipe handles. The group is created atomically by
        // posix_spawn so cancellation always reaches the entire command tree.
        _ = Darwin.kill(-groupID, SIGTERM)

        let workItem = DispatchWorkItem { [weak self] in
            self?.forceKillProcessGroup(groupID)
        }
        lock.lock()
        guard hasFinished == false else {
            lock.unlock()
            return
        }
        killWorkItem?.cancel()
        killWorkItem = workItem
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1, execute: workItem)
    }

    private func forceKillProcessGroup(_ groupID: pid_t) {
        lock.lock()
        let shouldKill = hasFinished == false && processGroupID == groupID
        lock.unlock()
        if shouldKill {
            _ = Darwin.kill(-groupID, SIGKILL)
        }
    }

    private func recordStdout(_ data: Data) {
        lock.lock()
        stdoutData = data
        lock.unlock()
    }

    private func recordStderr(_ data: Data) {
        lock.lock()
        stderrData = data
        lock.unlock()
    }

    private func complete(status: Int32) {
        lock.lock()
        let error = forcedError
        let result = CommandResult(
            status: status,
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self)
        )
        lock.unlock()

        if let error {
            finish(throwing: error)
        } else {
            finish(returning: result)
        }
    }

    private static func terminationStatus(_ rawStatus: Int32) -> Int32 {
        let signal = rawStatus & 0x7f
        return signal == 0 ? (rawStatus >> 8) & 0xff : signal
    }

    private func finish(returning result: CommandResult) {
        finish(with: .success(result))
    }

    private func finish(throwing error: Error) {
        finish(with: .failure(error))
    }

    private func finish(with result: Result<CommandResult, Error>) {
        lock.lock()
        guard hasFinished == false, let continuation else {
            lock.unlock()
            return
        }
        hasFinished = true
        self.continuation = nil
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        killWorkItem?.cancel()
        killWorkItem = nil
        processGroupID = nil
        lock.unlock()
        continuation.resume(with: result)
    }
}
#endif
