import Foundation

struct ResolvedCodexCommand: Sendable {
    let executable: String
    let arguments: [String]
}

public struct OpenAIAccountChatCommand {
    public static func run(arguments: [String]) async throws {
        let request = try OpenAIAccountChatRequest(arguments: arguments)
        let content = try await performChat(
            modelID: request.modelID,
            messages: try request.messages(),
            codexHomeOverride: request.codexHome,
            conversationID: request.conversationID
        )
        FileHandle.standardOutput.write(try responseData(content: content))
    }

    static func responseData(content: String) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(OpenAIAccountChatResponse(content: content))
        data.append(UInt8(ascii: "\n"))
        return data
    }

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

    static func resolveCodexCommand(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> ResolvedCodexCommand {
        if let explicitPath = environment["LANGTOOLS_CODEX_PATH"], explicitPath.isEmpty == false,
           let command = codexCommand(for: explicitPath, fileManager: fileManager) {
            return command
        }

        let candidates = bundledCodexCandidates() + [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/usr/bin/codex"
        ]
        for candidate in candidates {
            if let command = codexCommand(for: candidate, fileManager: fileManager) { return command }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["codex"]
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do { try process.run() } catch { throw OpenAIAccountChatCommandError.codexUnavailable }
        process.waitUntilExit()
        let resolved = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        if process.terminationStatus == 0, resolved.isEmpty == false,
           let command = codexCommand(for: resolved, fileManager: fileManager) {
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
            bundleURL.appendingPathComponent("Resources/CodexCLI/bin/codex").path
        ].compactMap { $0 }
    }

    private static func codexCommand(for path: String, fileManager: FileManager) -> ResolvedCodexCommand? {
        guard fileManager.fileExists(atPath: path) else { return nil }
        if let runtimeCommand = runtimeBackedCodexCommand(for: path, fileManager: fileManager) {
            return runtimeCommand
        }
        return fileManager.isExecutableFile(atPath: path)
            ? ResolvedCodexCommand(executable: path, arguments: [])
            : nil
    }

    private static func runtimeBackedCodexCommand(for path: String, fileManager: FileManager) -> ResolvedCodexCommand? {
        let scriptURL = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let cliURL = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("dist/cli.js")
        guard fileManager.fileExists(atPath: cliURL.path) else { return nil }
        for runtime in ["bun", "node"] {
            for candidate in runtimeCandidates(named: runtime) where fileManager.isExecutableFile(atPath: candidate) {
                return ResolvedCodexCommand(executable: candidate, arguments: [cliURL.path])
            }
        }
        return nil
    }

    private static func runtimeCandidates(named runtime: String) -> [String] {
        let executableURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let appBundleURL = enclosingAppBundle(for: executableURL)
        let bundleURL = Bundle.main.bundleURL
        let system: [String]
        switch runtime {
        case "bun": system = [NSHomeDirectory() + "/.bun/bin/bun", "/opt/homebrew/bin/bun", "/usr/local/bin/bun", "/usr/bin/bun"]
        case "node": system = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
        default: system = []
        }
        return [
            appBundleURL?.appendingPathComponent("Contents/Helpers/\(runtime)").path,
            appBundleURL?.appendingPathComponent("Contents/MacOS/\(runtime)").path,
            bundleURL.appendingPathComponent("Contents/Helpers/\(runtime)").path,
            bundleURL.appendingPathComponent("Contents/MacOS/\(runtime)").path,
            bundleURL.appendingPathComponent("Helpers/\(runtime)").path,
            bundleURL.appendingPathComponent("MacOS/\(runtime)").path
        ].compactMap { $0 } + system
    }

    private static func enclosingAppBundle(for executableURL: URL) -> URL? {
        var candidate = executableURL.deletingLastPathComponent()
        while candidate.path != "/" {
            if candidate.pathExtension == "app" { return candidate }
            candidate.deleteLastPathComponent()
        }
        return nil
    }
}

private struct OpenAIAccountChatRequest {
    let modelID: String
    let messagesFile: String
    let codexHome: String?
    let conversationID: UUID?

    init(arguments: [String]) throws {
        modelID = try Self.value(for: "--model", in: arguments)
        messagesFile = try Self.value(for: "--messages-file", in: arguments)
        codexHome = Self.optionalValue(for: "--codex-home", in: arguments)
        if let rawID = Self.optionalValue(for: "--conversation-id", in: arguments) {
            guard let parsed = UUID(uuidString: rawID) else { throw OpenAIAccountChatCommandError.usage }
            conversationID = parsed
        } else {
            conversationID = nil
        }
    }

    func messages() throws -> [HelperChatMessage] {
        let data = try Data(contentsOf: URL(fileURLWithPath: messagesFile))
        return try JSONDecoder().decode(OpenAIAccountChatMessagesFile.self, from: data).messages
    }

    private static func value(for flag: String, in arguments: [String]) throws -> String {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            throw OpenAIAccountChatCommandError.usage
        }
        return arguments[index + 1]
    }

    private static func optionalValue(for flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}

private struct OpenAIAccountChatMessagesFile: Decodable { let messages: [HelperChatMessage] }
private struct OpenAIAccountChatResponse: Encodable { let content: String }

private enum OpenAIAccountChatCommandError: LocalizedError {
    case usage
    case codexUnavailable
    case codexHomeMustBeConfiguredInEnvironment

    var errorDescription: String? {
        switch self {
        case .usage: return "Usage: LangToolsCLI openai-chat --model <model-id> --messages-file <path> [--conversation-id <uuid>]"
        case .codexUnavailable: return "Codex CLI is not available. Install it and ensure `codex` is on PATH, or set LANGTOOLS_CODEX_PATH."
        case .codexHomeMustBeConfiguredInEnvironment:
            return "--codex-home must match LANGTOOLS_CODEX_HOME or CODEX_HOME so the shared Codex app-server uses the requested account."
        }
    }
}
