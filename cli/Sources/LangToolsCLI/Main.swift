import Foundation

@main
struct LangToolsCLI {
    static func main() async {
        do {
            try await CommandRouter().run(arguments: Array(CommandLine.arguments.dropFirst()))
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}

private enum CommandRouterError: LocalizedError {
    case usage(String)

    var errorDescription: String? {
        switch self {
        case .usage(let text):
            return text
        }
    }
}

private struct CommandRouter {
    func run(arguments: [String]) async throws {
        guard let first = arguments.first else {
            try await ChatCommand.run()
            return
        }

        switch first {
        case "chat":
            try await ChatCommand.run()
        case "auth":
            try await AuthCLI.run(arguments: Array(arguments.dropFirst()))
        case "openai-chat":
            try await OpenAIAccountChatCommand.run(arguments: Array(arguments.dropFirst()))
        case "help", "--help", "-h":
            print(Self.usage)
        default:
            throw CommandRouterError.usage(Self.usage)
        }
    }

    static let usage = """
    Usage:
      LangToolsCLI
      LangToolsCLI chat
      LangToolsCLI auth login openai
      LangToolsCLI auth export-session openai --format json
      LangToolsCLI auth status openai --format json
      LangToolsCLI auth logout openai
      LangToolsCLI openai-chat --model <model-id> --messages-file <path>
    """
}
