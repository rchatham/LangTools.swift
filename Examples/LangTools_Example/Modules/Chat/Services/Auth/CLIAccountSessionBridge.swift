import Foundation

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
    case invalidSessionData
    case invalidChatResponse

    public var errorDescription: String? {
        switch self {
        case .cliUnavailable:
            return "LangToolsCLI is not available. Build/install it first."
        case .unsupportedPlatform:
            return "LangToolsCLI is only available on macOS."
        case .sandboxRequiresPrebuiltCLI:
            return "LangToolsCLI must be provided as a prebuilt executable when the app is sandboxed. Set LANGTOOLS_AUTH_CLI_PATH or bundle the CLI binary with the app."
        case .commandFailed(let message):
            return message
        case .invalidSessionData:
            return "LangToolsCLI returned invalid session data."
        case .invalidChatResponse:
            return "LangToolsCLI returned an invalid chat response."
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
        let loginResult = try await runLogged(command: command, extraArguments: ["auth", "login", "openai"], action: "OpenAI login")
        guard loginResult.status == 0 else {
            throw CLIAccountSessionBridgeError.commandFailed(commandFailureMessage(for: loginResult, action: "OpenAI login", executable: command.executable))
        }
        return try await exportOpenAISession(using: command)
    }

    public func logoutOpenAI() async throws {
        let command = try resolveCommand()
        let result = try await runLogged(command: command, extraArguments: ["auth", "logout", "openai"], action: "OpenAI logout")
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
        defer { try? FileManager.default.removeItem(at: requestFileURL) }

        let result = try await runLogged(
            command: command,
            extraArguments: ["openai-chat", "--model", model.rawValue, "--messages-file", requestFileURL.path],
            action: "OpenAI chat"
        )
        guard result.status == 0 else {
            throw CLIAccountSessionBridgeError.commandFailed(commandFailureMessage(for: result, action: "OpenAI chat", executable: command.executable))
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
        let result = try await runLogged(command: command, extraArguments: ["auth", "export-session", "openai", "--format", "json"], action: "OpenAI session export")
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
            messages: messages.compactMap { message in
                guard let content = message.text else { return nil }
                return OpenAIChatCLIMessage(role: message.role, content: content)
            }
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(payload)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("langtools-openai-chat-")
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL)
        return fileURL
    }

    private func commandFailureMessage(for result: CommandResult, action: String, executable: String) -> String {
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let logHint = "See \(logger.logFilePath) for helper output."

        if stderr.isEmpty == false {
            return "\(stderr)\n\n\(logHint)"
        }

        if stdout.isEmpty == false {
            return "\(stdout)\n\n\(logHint)"
        }

        return "\(action) failed: LangToolsCLI exited with status \(result.status) at \(executable). \(logHint)"
    }

    private func runLogged(command: ResolvedCommand, extraArguments: [String], action: String) async throws -> CommandResult {
        let arguments = command.arguments + extraArguments
        let result = try await runner.run(executable: command.executable, arguments: arguments)
        logger.log(action: action, executable: command.executable, arguments: arguments, result: result)
        return result
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
            .appendingPathComponent("LangToolsCLI")

        if FileManager.default.isExecutableFile(atPath: binaryPath.path) {
            return ResolvedCommand(executable: binaryPath.path, arguments: [])
        }

        if isSandboxed {
            throw CLIAccountSessionBridgeError.sandboxRequiresPrebuiltCLI
        }

        return ResolvedCommand(
            executable: "/usr/bin/env",
            arguments: ["swift", "run", "--package-path", cliPackageRoot.path, "LangToolsCLI"]
        )
    }

    private var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"]?.isEmpty == false
    }

    private func bundledCandidatePaths() -> [String] {
        let bundleURL = Bundle.main.bundleURL
        let contentsURL = bundleURL.appendingPathComponent("Contents")
        return [
            bundleURL.appendingPathComponent("LangToolsCLI").path,
            bundleURL.appendingPathComponent("Contents/MacOS/LangToolsCLI").path,
            bundleURL.appendingPathComponent("Contents/Helpers/LangToolsCLI").path,
            contentsURL.appendingPathComponent("MacOS/LangToolsCLI").path,
            contentsURL.appendingPathComponent("Helpers/LangToolsCLI").path,
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
}

private struct OpenAIChatCLIResponse: Codable {
    let content: String
}

public struct CLIBridgeLogger {
    private let fileURL: URL
    private let formatter: ISO8601DateFormatter

    public init(fileURL: URL? = nil) {
        self.formatter = ISO8601DateFormatter()
        self.formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        if let fileURL {
            self.fileURL = fileURL
        } else {
            let baseDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let logsDirectory = baseDirectory
                .appendingPathComponent("LangTools_Example", isDirectory: true)
                .appendingPathComponent("Logs", isDirectory: true)
            try? FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
            self.fileURL = logsDirectory.appendingPathComponent("LangToolsCLI-bridge.log")
        }
    }

    public var logFilePath: String {
        fileURL.path
    }

    public func log(action: String, executable: String, arguments: [String], result: CommandResult) {
        let lines = [
            "[\(formatter.string(from: Date()))] \(action)",
            "executable: \(executable)",
            "arguments: \(arguments.joined(separator: " "))",
            "status: \(result.status)",
            "stdout:",
            result.stdout.isEmpty ? "<empty>" : result.stdout,
            "stderr:",
            result.stderr.isEmpty ? "<empty>" : result.stderr,
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
}

public struct ProcessRunner: CommandRunning {
    public init() {}

    public func run(executable: String, arguments: [String]) async throws -> CommandResult {
        #if os(macOS)
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            process.terminationHandler = { process in
                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: CommandResult(
                    status: process.terminationStatus,
                    stdout: String(decoding: outData, as: UTF8.self),
                    stderr: String(decoding: errData, as: UTF8.self)
                ))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: CLIAccountSessionBridgeError.cliUnavailable)
            }
        }
        #else
        throw CLIAccountSessionBridgeError.unsupportedPlatform
        #endif
    }
}
