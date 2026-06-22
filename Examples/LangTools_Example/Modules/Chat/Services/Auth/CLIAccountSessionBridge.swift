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

    public var errorDescription: String? {
        switch self {
        case .cliUnavailable:
            return "LangToolsAuthCLI is not available. Build/install it first."
        case .unsupportedPlatform:
            return "LangToolsAuthCLI is only available on macOS."
        case .sandboxRequiresPrebuiltCLI:
            return "LangToolsAuthCLI must be provided as a prebuilt executable when the app is sandboxed. Set LANGTOOLS_AUTH_CLI_PATH or bundle the CLI binary with the app."
        case .commandFailed(let message):
            return message
        case .invalidSessionData:
            return "LangToolsAuthCLI returned invalid session data."
        }
    }
}

public struct CLIAccountSessionBridge {
    private let runner: CommandRunning
    private let decoder: JSONDecoder

    public init(runner: CommandRunning = ProcessRunner()) {
        self.runner = runner
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public func loginOpenAI() async throws -> AccountSession {
        let command = try resolveCommand()
        let loginResult = try await runner.run(executable: command.executable, arguments: command.arguments + ["auth", "login", "openai"])
        guard loginResult.status == 0 else {
            throw CLIAccountSessionBridgeError.commandFailed(commandFailureMessage(for: loginResult, action: "OpenAI login", executable: command.executable))
        }
        return try await exportOpenAISession(using: command)
    }

    public func logoutOpenAI() async throws {
        let command = try resolveCommand()
        let result = try await runner.run(executable: command.executable, arguments: command.arguments + ["auth", "logout", "openai"])
        guard result.status == 0 else {
            throw CLIAccountSessionBridgeError.commandFailed(commandFailureMessage(for: result, action: "OpenAI logout", executable: command.executable))
        }
    }

    public func exportOpenAISession() async throws -> AccountSession {
        try await exportOpenAISession(using: resolveCommand())
    }

    private func exportOpenAISession(using command: ResolvedCommand) async throws -> AccountSession {
        let result = try await runner.run(executable: command.executable, arguments: command.arguments + ["auth", "export-session", "openai", "--format", "json"])
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

    private func commandFailureMessage(for result: CommandResult, action: String, executable: String) -> String {
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if stderr.isEmpty == false {
            return stderr
        }

        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if stdout.isEmpty == false {
            return stdout
        }

        return "\(action) failed: LangToolsAuthCLI exited with status \(result.status) at \(executable)."
    }

    private func resolveCommand() throws -> ResolvedCommand {
        if let explicitPath = ProcessInfo.processInfo.environment["LANGTOOLS_AUTH_CLI_PATH"], explicitPath.isEmpty == false {
            return ResolvedCommand(executable: explicitPath, arguments: [])
        }

        for candidate in bundledCandidatePaths() where FileManager.default.isExecutableFile(atPath: candidate) {
            return ResolvedCommand(executable: candidate, arguments: [])
        }

        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Auth
            .deletingLastPathComponent() // Services
            .deletingLastPathComponent() // Chat
            .deletingLastPathComponent() // Modules
            .deletingLastPathComponent() // LangTools_Example
            .deletingLastPathComponent() // Examples

        let binaryPath = packageRoot
            .appendingPathComponent(".build")
            .appendingPathComponent("debug")
            .appendingPathComponent("LangToolsAuthCLI")

        if FileManager.default.isExecutableFile(atPath: binaryPath.path) {
            return ResolvedCommand(executable: binaryPath.path, arguments: [])
        }

        if isSandboxed {
            throw CLIAccountSessionBridgeError.sandboxRequiresPrebuiltCLI
        }

        return ResolvedCommand(
            executable: "/usr/bin/env",
            arguments: ["swift", "run", "--package-path", packageRoot.path, "LangToolsAuthCLI"]
        )
    }

    private var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"]?.isEmpty == false
    }

    private func bundledCandidatePaths() -> [String] {
        let bundleURL = Bundle.main.bundleURL
        let contentsURL = bundleURL.appendingPathComponent("Contents")
        return [
            bundleURL.appendingPathComponent("LangToolsAuthCLI").path,
            bundleURL.appendingPathComponent("Contents/MacOS/LangToolsAuthCLI").path,
            bundleURL.appendingPathComponent("Contents/Helpers/LangToolsAuthCLI").path,
            contentsURL.appendingPathComponent("MacOS/LangToolsAuthCLI").path,
            contentsURL.appendingPathComponent("Helpers/LangToolsAuthCLI").path,
        ]
    }
}

private struct ResolvedCommand {
    let executable: String
    let arguments: [String]
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
