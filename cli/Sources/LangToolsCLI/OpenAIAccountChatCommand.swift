import Foundation
import LangTools
import OpenAI

private struct CodexProcessResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

private struct ResolvedCodexCommand {
    let executable: String
    let arguments: [String]
}

struct OpenAIAccountChatCommand {
    static func run(arguments: [String]) async throws {
        let request = try OpenAIAccountChatRequest(arguments: arguments)
        let model = try request.model()
        let messages = try request.messages()
        let session = try SessionStore().load()
        let codex = try resolveCodexCommand()
        let prompt = renderPrompt(messages: messages)

        let workspace = try CodexWorkspace(session: session)
        defer { workspace.remove() }

        let result = try runCodex(
            command: codex,
            model: model.rawValue,
            prompt: prompt,
            workspace: workspace
        )

        guard result.status == 0 else {
            throw OpenAIAccountChatCommandError.codexFailed(message: failureMessage(for: result))
        }

        let content = result.stdout.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard content.isEmpty == false else {
            throw OpenAIAccountChatCommandError.invalidResponse
        }

        let payload = OpenAIAccountChatResponse(content: content)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func resolveCodexCommand() throws -> ResolvedCodexCommand {
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
            appBundleURL?.appendingPathComponent("Contents/Resources/CodexCLI/bin/codex").path,
            appBundleURL?.appendingPathComponent("Contents/Helpers/CodexCLI/bin/codex").path,
            bundleURL.appendingPathComponent("Contents/Resources/CodexCLI/bin/codex").path,
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

    private static func runCodex(command: ResolvedCodexCommand, model: String, prompt: String, workspace: CodexWorkspace) throws -> CodexProcessResult {
        try runProcess(
            executable: command.executable,
            arguments: command.arguments + ["-q", "-m", model, prompt],
            environment: workspace.environment
        )
    }

    private static func runProcess(executable: String, arguments: [String], environment: [String: String]? = nil) throws -> CodexProcessResult {
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
        return CodexProcessResult(
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
            let contentLabel = message.contentKind.map { " | \($0)" } ?? ""
            let content = message.text?.isEmpty == false ? message.text! : "[No content]"
            return "[\(role)\(contentLabel)]\n\(content)"
        }.joined(separator: "\n\n")

        return """
        Continue this conversation and reply as the assistant. Return only the assistant's next message with no extra framing.

        \(transcript)
        """
    }

    private static func failureMessage(for result: CodexProcessResult) -> String {
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

private struct CodexWorkspace {
    let directoryURL: URL
    let environment: [String: String]

    init(session: StoredAccountSession) throws {
        guard let idToken = session.idToken, idToken.split(separator: ".").count == 3 else {
            throw OpenAIAccountChatCommandError.invalidSession
        }
        guard let refreshToken = session.refreshToken, refreshToken.isEmpty == false else {
            throw OpenAIAccountChatCommandError.invalidSession
        }

        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("langtools-codex-", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let authJSON = try Self.makeAuthJSON(session: session, idToken: idToken, refreshToken: refreshToken)
        try authJSON.write(to: directoryURL.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)

        let config = "cli_auth_credentials_store = \"file\"\n"
        try config.write(to: directoryURL.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)

        var env = ProcessInfo.processInfo.environment
        env["CODEX_HOME"] = directoryURL.path
        env.removeValue(forKey: "CODEX_API_KEY")
        env.removeValue(forKey: "OPENAI_API_KEY")
        env.removeValue(forKey: "OPENAI_BASE_URL")
        environment = env
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    private static func makeAuthJSON(session: StoredAccountSession, idToken: String, refreshToken: String) throws -> String {
        let payload: [String: Any?] = [
            "auth_mode": "chatgptAuthTokens",
            "tokens": [
                "id_token": idToken,
                "access_token": session.accessToken,
                "refresh_token": refreshToken,
                "account_id": chatGPTAccountID(from: idToken) ?? chatGPTAccountID(from: session.accessToken) ?? session.accountIdentifier
            ]
        ]

        let sanitized = payload.compactMapValues { $0 }
        let data = try JSONSerialization.data(withJSONObject: sanitized, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static func chatGPTAccountID(from token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let auth = object["https://api.openai.com/auth"] as? [String: Any],
              let accountID = auth["chatgpt_account_id"] as? String,
              accountID.isEmpty == false else {
            return nil
        }
        return accountID
    }
}

private struct OpenAIAccountChatRequest {
    let modelID: String
    let messagesFile: String

    init(arguments: [String]) throws {
        self.modelID = try Self.value(for: "--model", in: arguments)
        self.messagesFile = try Self.value(for: "--messages-file", in: arguments)
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
        return payload.messages.map {
            let message = Message(text: $0.content, role: $0.role)
            message.contentKind = $0.contentKind
            return message
        }
    }

    private static func value(for flag: String, in arguments: [String]) throws -> String {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            throw OpenAIAccountChatCommandError.usage
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
    let contentKind: String?
}

private struct OpenAIAccountChatResponse: Codable {
    let content: String
}

private enum OpenAIAccountChatCommandError: LocalizedError {
    case usage
    case invalidModel(String)
    case invalidResponse
    case invalidSession
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
        case .invalidSession:
            return "The stored OpenAI account session is missing Codex authentication tokens. Sign in again from Manage Access."
        case .codexUnavailable:
            return "Codex CLI is not available. Install it and ensure the `codex` binary is on your PATH, or set LANGTOOLS_CODEX_PATH."
        case .codexFailed(let message):
            return message
        }
    }
}
