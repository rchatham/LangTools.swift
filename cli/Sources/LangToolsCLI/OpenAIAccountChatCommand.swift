import Foundation
import LangTools
import OpenAI

struct ResolvedCodexCommand: Sendable {
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

        let result = try await runCodex(
            command: codex,
            model: model.rawValue,
            prompt: prompt,
            workspace: workspace
        )

        guard result.exitCode == 0 else {
            throw OpenAIAccountChatCommandError.codexFailed(message: failureMessage(for: result))
        }
        guard result.stdoutCaptureLimitExceeded == false,
              result.stderrCaptureLimitExceeded == false else {
            throw OpenAIAccountChatCommandError.responseTooLarge
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

    /// Runtime-backed chat entry point used by the local helper server. Unlike
    /// the one-shot `run(arguments:)` flow, this delegates to the Codex
    /// app-server runtime so conversations persist across helper requests.
    static func performChat(
        modelID: String,
        messages: [HelperChatMessage],
        codexHomeOverride: String?,
        conversationID: UUID? = nil
    ) async throws -> String {
        if let codexHomeOverride, codexHomeOverride.isEmpty == false {
            let configured = ProcessInfo.processInfo.environment["LANGTOOLS_CODEX_HOME"]
                ?? ProcessInfo.processInfo.environment["CODEX_HOME"]
            guard configured == codexHomeOverride else {
                throw OpenAIAccountChatCommandError.codexHomeMustBeConfiguredInEnvironment
            }
        }
        return try await CodexRuntimeService.shared.chat(
            model: modelID,
            messages: messages,
            conversationID: conversationID
        )
    }

    static func responseData(content: String) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(OpenAIAccountChatResponse(content: content))
        data.append(UInt8(ascii: "\n"))
        return data
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

        if let resolved = ProcessService.executablePath(for: "codex"),
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

    static func runCodex(
        command: ResolvedCodexCommand,
        model: String,
        prompt: String,
        workspace: CodexWorkspace,
        sandboxExecPath: String? = CodexSeatbeltProfile.sandboxExecPath()
    ) async throws -> ProcessResult {
        guard let sandboxExecPath else {
            throw OpenAIAccountChatCommandError.containmentUnavailable
        }
        let inputs = CodexSeatbeltProfile.Inputs(
            codexExecutable: command.executable,
            codexExecutableArguments: command.arguments,
            codexHome: workspace.directoryURL.path,
            workspaceRoot: workspace.directoryURL.path,
            processTemporaryDirectory: workspace.temporaryDirectoryURL.path,
            codexRuntimeCache: CodexSeatbeltProfile.resolvedCodexRuntimeCache(
                environment: workspace.parentEnvironment
            ),
            homeDirectory: workspace.parentEnvironment["HOME"] ?? ""
        )
        let profileURL = try CodexSeatbeltProfile().writeProfile(inputs: inputs)
        defer { try? FileManager.default.removeItem(at: profileURL) }

        do {
            return try await ProcessService.execute(
                executable: sandboxExecPath,
                arguments: ["-f", profileURL.path, command.executable]
                    + command.arguments
                    + ["-q", "-m", model, prompt],
                workingDirectory: workspace.temporaryDirectoryURL.path,
                environment: workspace.environment
            )
        } catch let error as ProcessError {
            if case .executionFailed = error {
                throw OpenAIAccountChatCommandError.codexUnavailable
            }
            throw error
        }
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

    private static func failureMessage(for result: ProcessResult) -> String {
        let stderr = result.stderr.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        if stderr.isEmpty == false {
            return stderr
        }

        let stdout = result.stdout.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        if stdout.isEmpty == false {
            return stdout
        }

        return "Codex CLI exited with status \(result.exitCode)."
    }
}

struct CodexWorkspace {
    private static let directoryPermissions: Int = 0o700
    private static let filePermissions: Int = 0o600

    let directoryURL: URL
    let temporaryDirectoryURL: URL
    let environment: [String: String]
    let parentEnvironment: [String: String]

    init(
        session: StoredAccountSession,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        guard let idToken = session.idToken, idToken.split(separator: ".").count == 3 else {
            throw OpenAIAccountChatCommandError.invalidSession
        }
        guard let refreshToken = session.refreshToken, refreshToken.isEmpty == false else {
            throw OpenAIAccountChatCommandError.invalidSession
        }

        let workspaceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("langtools-codex-account-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspaceURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: Self.directoryPermissions]
        )
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(Self.directoryPermissions))],
                ofItemAtPath: workspaceURL.path
            )
            let authJSON = try Self.makeAuthJSON(session: session, idToken: idToken, refreshToken: refreshToken)
            let authURL = workspaceURL.appendingPathComponent("auth.json")
            try Self.writePrivateFile(contents: authJSON, to: authURL)

            let config = "cli_auth_credentials_store = \"file\"\n"
            let configURL = workspaceURL.appendingPathComponent("config.toml")
            try Self.writePrivateFile(contents: config, to: configURL)

            let processTemp = try CodexProcessTemporaryDirectory.create(
                inside: workspaceURL,
                prefix: "one-shot"
            )
            directoryURL = workspaceURL
            temporaryDirectoryURL = processTemp
            parentEnvironment = environment
            self.environment = CodexChildEnvironment.make(
                parent: environment,
                codexHome: workspaceURL,
                temporaryDirectory: processTemp
            )
        } catch {
            try? FileManager.default.removeItem(at: workspaceURL)
            throw error
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    private static func writePrivateFile(contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: filePermissions], ofItemAtPath: url.path)
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
    case responseTooLarge
    case invalidSession
    case codexUnavailable
    case containmentUnavailable
    case codexFailed(message: String)
    case codexHomeMustBeConfiguredInEnvironment

    var errorDescription: String? {
        switch self {
        case .usage:
            return "Usage: LangToolsCLI openai-chat --model <model-id> --messages-file <path>"
        case .invalidModel(let modelID):
            return "Unsupported OpenAI model: \(modelID)"
        case .invalidResponse:
            return "Codex CLI returned an empty response."
        case .responseTooLarge:
            return "Codex CLI response exceeded the 4 MiB output limit."
        case .invalidSession:
            return "The stored OpenAI account session is missing Codex authentication tokens. Sign in again from Manage Access."
        case .codexUnavailable:
            return "Codex CLI is not available. Install it and ensure the `codex` binary is on your PATH, or set LANGTOOLS_CODEX_PATH."
        case .containmentUnavailable:
            return "Codex read containment is unavailable. Refusing to launch account chat without macOS sandbox-exec."
        case .codexFailed(let message):
            return message
        case .codexHomeMustBeConfiguredInEnvironment:
            return "The requested Codex home must match the LANGTOOLS_CODEX_HOME or CODEX_HOME environment variable."
        }
    }
}
