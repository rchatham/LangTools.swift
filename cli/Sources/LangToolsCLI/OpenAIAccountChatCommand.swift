import Foundation
import LangTools
import OpenAI

private struct ProcessResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

struct ResolvedCodexCommand {
    let executable: String
    let arguments: [String]
}

struct OpenAIAccountChatCommand {
    static func run(arguments: [String]) async throws {
        let request = try OpenAIAccountChatRequest(arguments: arguments)
        let content = try await performChat(
            modelID: request.modelID,
            messages: try request.messages().map { .init(role: $0.role.rawValue, content: $0.text ?? "") },
            codexHomeOverride: request.codexHome
        )

        let payload = OpenAIAccountChatResponse(content: content)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    static func performChat(modelID: String, messages: [HelperChatMessage], codexHomeOverride: String?) async throws -> String {
        guard let model = Model(rawValue: modelID) else {
            throw OpenAIAccountChatCommandError.invalidModel(modelID)
        }
        guard case .openAI = model else {
            throw OpenAIAccountChatCommandError.invalidModel(modelID)
        }

        let codex = try resolveCodexCommand()
        let prompt = renderPrompt(messages: messages.map { Message(text: $0.content, role: OpenAI.Message.Role(rawValue: $0.role) ?? .user) })
        let sourceCodexHome = try CodexAuthPreflight.validate(codexHomeOverride: codexHomeOverride)
        let runtimeCodexHome = try prepareRuntimeCodexHome(from: sourceCodexHome)
        defer { try? FileManager.default.removeItem(at: runtimeCodexHome) }

        let result = try runCodex(
            command: codex,
            model: model.rawValue,
            prompt: prompt,
            runtimeCodexHome: runtimeCodexHome
        )

        guard result.status == 0 else {
            throw OpenAIAccountChatCommandError.codexFailed(message: failureMessage(for: result))
        }

        let content = result.stdout.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard content.isEmpty == false else {
            throw OpenAIAccountChatCommandError.invalidResponse
        }

        return content
    }

    static func resolveCodexCommand() throws -> ResolvedCodexCommand {
        if let explicitPath = ProcessInfo.processInfo.environment["LANGTOOLS_CODEX_PATH"],
           explicitPath.isEmpty == false {
            if let command = codexCommand(for: explicitPath) {
                return command
            }
        }

        let candidates = bundledCodexCandidates() + [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/usr/bin/codex"
        ]

        for candidate in candidates {
            if let command = codexCommand(for: candidate) {
                return command
            }
        }

        let result = try runProcess(executable: "/usr/bin/which", arguments: ["codex"])
        let resolved = result.stdout.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        if result.status == 0, resolved.isEmpty == false,
           let command = codexCommand(for: resolved) {
            return command
        }

        throw OpenAIAccountChatCommandError.codexUnavailable
    }

    private static func bundledCodexCandidates() -> [String] {
        let executableURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let appBundleURL = enclosingAppBundle(for: executableURL)
        let bundleURL = Bundle.main.bundleURL

        return [
            appBundleURL?.appendingPathComponent("Contents/Resources/CodexCLI/codex").path,
            appBundleURL?.appendingPathComponent("Contents/Resources/CodexCLI/bin/codex").path,
            appBundleURL?.appendingPathComponent("Contents/Helpers/CodexCLI/bin/codex").path,
            bundleURL.appendingPathComponent("Contents/Resources/CodexCLI/codex").path,
            bundleURL.appendingPathComponent("Contents/Resources/CodexCLI/bin/codex").path,
            bundleURL.appendingPathComponent("Resources/CodexCLI/codex").path,
            bundleURL.appendingPathComponent("Resources/CodexCLI/bin/codex").path,
        ].compactMap { $0 }
    }

    private static func codexCommand(for path: String) -> ResolvedCodexCommand? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path) else {
            return nil
        }

        if let runtimeCommand = runtimeBackedCodexCommand(for: path) {
            return runtimeCommand
        }

        if fileManager.isExecutableFile(atPath: path) {
            return ResolvedCodexCommand(executable: path, arguments: [])
        }

        return nil
    }

    private static func runtimeBackedCodexCommand(for path: String) -> ResolvedCodexCommand? {
        let fileManager = FileManager.default
        let resolvedPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let scriptURL = URL(fileURLWithPath: resolvedPath)
        let cliURL = scriptURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("dist")
            .appendingPathComponent("cli.js")

        guard fileManager.fileExists(atPath: cliURL.path) else {
            return nil
        }

        for candidate in runtimeCandidates(named: "bun") where fileManager.isExecutableFile(atPath: candidate) {
            return ResolvedCodexCommand(executable: candidate, arguments: [cliURL.path])
        }

        for candidate in runtimeCandidates(named: "node") where fileManager.isExecutableFile(atPath: candidate) {
            return ResolvedCodexCommand(executable: candidate, arguments: [cliURL.path])
        }

        return nil
    }

    private static func runtimeCandidates(named runtime: String) -> [String] {
        let executableURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let appBundleURL = enclosingAppBundle(for: executableURL)
        let bundleURL = Bundle.main.bundleURL
        let systemCandidates: [String]

        switch runtime {
        case "bun":
            systemCandidates = [
                NSHomeDirectory() + "/.bun/bin/bun",
                "/opt/homebrew/bin/bun",
                "/usr/local/bin/bun",
                "/usr/bin/bun",
            ]
        case "node":
            systemCandidates = [
                "/opt/homebrew/bin/node",
                "/usr/local/bin/node",
                "/usr/bin/node",
            ]
        default:
            systemCandidates = []
        }

        return [
            appBundleURL?.appendingPathComponent("Contents/Helpers/\(runtime)").path,
            appBundleURL?.appendingPathComponent("Contents/MacOS/\(runtime)").path,
            bundleURL.appendingPathComponent("Contents/Helpers/\(runtime)").path,
            bundleURL.appendingPathComponent("Contents/MacOS/\(runtime)").path,
            bundleURL.appendingPathComponent("Helpers/\(runtime)").path,
            bundleURL.appendingPathComponent("MacOS/\(runtime)").path,
        ].compactMap { $0 } + systemCandidates
    }

    private static func enclosingAppBundle(for executableURL: URL) -> URL? {
        var candidate = executableURL.deletingLastPathComponent()
        while candidate.path != "/" {
            if candidate.pathExtension == "app" {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        return nil
    }

    private static func runCodex(command: ResolvedCodexCommand, model: String, prompt: String, runtimeCodexHome: URL) throws -> ProcessResult {
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = runtimeCodexHome.path
        environment["LANGTOOLS_CODEX_HOME"] = runtimeCodexHome.path
        environment["CODEX_INTERNAL_APP_SERVER_REMOTE_CONTROL_DISABLED"] = "1"

        return try runProcess(
            executable: command.executable,
            arguments: command.arguments + [
                "exec",
                "--ignore-user-config",
                "--skip-git-repo-check",
                "--disable", "apps",
                "--disable", "browser_use",
                "--disable", "computer_use",
                "--disable", "in_app_browser",
                "--disable", "plugins",
                "-C", "/Users/reidchatham",
                "--model", model,
                prompt,
            ],
            environment: environment
        )
    }

    private static func prepareRuntimeCodexHome(from sourceCodexHome: URL) throws -> URL {
        let fileManager = FileManager.default
        let baseDirectory = try runtimeCodexBaseDirectory()
        let runtimeCodexHome = baseDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        try fileManager.createDirectory(at: runtimeCodexHome, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: runtimeCodexHome.appendingPathComponent("log", isDirectory: true), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: runtimeCodexHome.appendingPathComponent("process_manager", isDirectory: true), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: runtimeCodexHome.appendingPathComponent("sessions", isDirectory: true), withIntermediateDirectories: true)

        for relativePath in [
            "auth.json",
            "models_cache.json",
            "version.json",
            "installation_id",
            "config.json"
        ] {
            let sourceURL = sourceCodexHome.appendingPathComponent(relativePath)
            let destinationURL = runtimeCodexHome.appendingPathComponent(relativePath)
            if fileManager.fileExists(atPath: sourceURL.path) {
                try fileManager.copyItem(at: sourceURL, to: destinationURL)
            }
        }

        return runtimeCodexHome
    }

    private static func runtimeCodexBaseDirectory() throws -> URL {
        let fileManager = FileManager.default

        if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let directory = appSupport
                .appendingPathComponent("LangToolsCLI", isDirectory: true)
                .appendingPathComponent("CodexRuntime", isDirectory: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }

        let fallback = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("LangToolsCLI", isDirectory: true)
            .appendingPathComponent("CodexRuntime", isDirectory: true)
        try fileManager.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    private static func runProcess(executable: String, arguments: [String], environment: [String: String]? = nil) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw OpenAIAccountChatCommandError.codexUnavailable
        }

        process.waitUntilExit()
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        return ProcessResult(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }

    private static func renderPrompt(messages: [Message]) -> String {
        let transcript = messages.map { message in
            let role: String
            switch message.role {
            case .system:
                role = "System"
            case .assistant:
                role = "Assistant"
            case .tool:
                role = "Tool"
            default:
                role = "User"
            }
            return "[\(role)]\n\(message.text ?? "")"
        }.joined(separator: "\n\n")

        return """
        Continue this conversation and reply as the assistant. Return only the assistant's next message with no extra framing.

        \(transcript)
        """
    }

    private static func failureMessage(for result: ProcessResult) -> String {
        let stderr = result.stderr.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        if stderr.isEmpty == false {
            return stderr
        }

        let stdout = result.stdout.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        if stdout.isEmpty == false {
            return stdout
        }

        return "Codex CLI exited with status \(result.status)."
    }
}

private enum CodexAuthPreflight {
    static func validate(codexHomeOverride: String?) throws -> URL {
        let codexHome = resolvedCodexHome(codexHomeOverride: codexHomeOverride)
        let authFileURL = codexHome
            .appendingPathComponent("auth.json")

        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: authFileURL.path) else {
            throw OpenAIAccountChatCommandError.codexNotLoggedIn(checkedPath: authFileURL.path)
        }

        let data = try Data(contentsOf: authFileURL)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenAIAccountChatCommandError.codexAuthInvalid
        }

        let authMode = (object["auth_mode"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard authMode.isEmpty == false else {
            throw OpenAIAccountChatCommandError.codexAuthInvalid
        }

        if authMode == "apikey" {
            throw OpenAIAccountChatCommandError.codexUsingAPIKey
        }

        return codexHome
    }

    private static func resolvedCodexHome(codexHomeOverride: String?) -> URL {
        let fileManager = FileManager.default
        let argumentCandidate = codexHomeOverride.flatMap { value -> URL? in
            guard value.isEmpty == false else { return nil }
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        let envCandidates = ["LANGTOOLS_CODEX_HOME", "CODEX_HOME"]
            .compactMap { key -> URL? in
                guard let value = ProcessInfo.processInfo.environment[key], value.isEmpty == false else {
                    return nil
                }
                return URL(fileURLWithPath: value, isDirectory: true)
            }

        let userHome = NSHomeDirectoryForUser(NSUserName()).map { URL(fileURLWithPath: $0, isDirectory: true) }
        let fallbackCandidates = [
            userHome,
            fileManager.homeDirectoryForCurrentUser,
        ].compactMap { $0?.appendingPathComponent(".codex", isDirectory: true) }

        let candidates = (argumentCandidate.map { [$0] } ?? []) + envCandidates + fallbackCandidates
        for candidate in candidates {
            let authFile = candidate.appendingPathComponent("auth.json")
            if fileManager.fileExists(atPath: authFile.path) {
                return candidate
            }
        }

        return candidates.first ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

}

private struct OpenAIAccountChatRequest {
    let modelID: String
    let messagesFile: String
    let codexHome: String?

    init(arguments: [String]) throws {
        self.modelID = try Self.value(for: "--model", in: arguments)
        self.messagesFile = try Self.value(for: "--messages-file", in: arguments)
        self.codexHome = Self.optionalValue(for: "--codex-home", in: arguments)
    }

    func model() throws -> Model {
        guard let model = Model(rawValue: modelID) else {
            throw OpenAIAccountChatCommandError.invalidModel(modelID)
        }
        guard case .openAI = model else {
            throw OpenAIAccountChatCommandError.invalidModel(modelID)
        }
        return model
    }

    func messages() throws -> [Message] {
        let data = try Data(contentsOf: URL(fileURLWithPath: messagesFile))
        let decoder = JSONDecoder()
        let payload = try decoder.decode(OpenAIAccountChatMessagesFile.self, from: data)
        return payload.messages.map { Message(text: $0.content, role: $0.role) }
    }

    private static func value(for flag: String, in arguments: [String]) throws -> String {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            throw OpenAIAccountChatCommandError.usage
        }
        return arguments[index + 1]
    }

    private static func optionalValue(for flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}

private struct OpenAIAccountChatMessagesFile: Codable {
    let messages: [OpenAIAccountChatMessage]
}

private struct OpenAIAccountChatMessage: Codable {
    let role: OpenAI.Message.Role
    let content: String
}

private struct OpenAIAccountChatResponse: Codable {
    let content: String
}

private enum OpenAIAccountChatCommandError: LocalizedError {
    case usage
    case invalidModel(String)
    case invalidResponse
    case codexNotLoggedIn(checkedPath: String)
    case codexUsingAPIKey
    case codexAuthInvalid
    case codexUnavailable
    case codexFailed(message: String)

    var errorDescription: String? {
        switch self {
        case .usage:
            return "Usage: LangToolsCLI openai-chat --model <model-id> --messages-file <path>"
        case .invalidModel(let modelID):
            return "Unsupported OpenAI model: \(modelID)"
        case .invalidResponse:
            return "Codex CLI returned an empty response."
        case .codexNotLoggedIn(let checkedPath):
            return "Codex is not logged in. Checked \(checkedPath). Run `codex login` and sign in with your OpenAI account, then try again."
        case .codexUsingAPIKey:
            return "Codex is currently configured for Platform API key auth in ~/.codex/auth.json. To use OpenAI account-backed Codex chat, run `codex logout`, then `codex login`, and sign in with your OpenAI account instead of using an API key."
        case .codexAuthInvalid:
            return "Codex auth state could not be read from ~/.codex/auth.json. Re-run `codex login` and try again."
        case .codexUnavailable:
            return "Codex CLI is not available. Install it and ensure the `codex` binary is on your PATH, or set LANGTOOLS_CODEX_PATH."
        case .codexFailed(let message):
            return message
        }
    }
}
