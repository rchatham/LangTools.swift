import Foundation

struct AuthCLI {
    static func run(arguments: [String]) async throws {
        let command = try AuthSubcommand(arguments: arguments)
        switch command {
        case .login:
            let session = try await loginOpenAI()
            print("Logged in to OpenAI as \(session.accountIdentifier)")
        case .exportSession(_, let format):
            try await exportSession(format: format)
        case .status(_, let format):
            try await printStatus(format: format)
        case .logout:
            try await logoutOpenAI()
            print("Logged out of OpenAI")
        }
    }

    static func loginOpenAI() async throws -> StoredAccountSession {
        try await CodexRuntimeService.shared.login()
    }

    static func exportOpenAISession() async throws -> StoredAccountSession {
        let status = try await CodexRuntimeService.shared.accountStatus(refreshToken: true)
        guard status.authenticated else { throw AuthCLIError.missingSession }
        return StoredAccountSession(
            provider: "openAI",
            accountIdentifier: status.accountIdentifier ?? "ChatGPT Account",
            accessToken: CodexRuntimeService.sessionMarker,
            refreshToken: nil,
            idToken: nil,
            tokenType: nil,
            expiresAt: nil,
            accessibleModelIDs: try await openAIAccessibleModelIDs(),
            createdAt: Date(),
            id: UUID()
        )
    }

    static func logoutOpenAI() async throws {
        try await CodexRuntimeService.shared.logout()
    }

    static func openAIAccessibleModelIDs() async throws -> [String] {
        try await CodexRuntimeService.shared.modelSlugs()
    }

    static let usage = """
    Usage:
      LangToolsCLI auth login openai
      LangToolsCLI auth export-session openai --format json
      LangToolsCLI auth status openai --format json
      LangToolsCLI auth logout openai
    """

    private static func exportSession(format: OutputFormat) async throws {
        try writeJSON(try await exportOpenAISession(), format: format)
    }

    private static func printStatus(format: OutputFormat) async throws {
        do {
            let status = try await CodexRuntimeService.shared.accountStatus()
            let models = status.authenticated ? try await openAIAccessibleModelIDs() : nil
            try writeJSON(HelperAuthStatusResponse(
                provider: "openAI",
                authenticated: status.authenticated,
                accountIdentifier: status.accountIdentifier,
                expiresAt: nil,
                accessibleModelIDs: models
            ), format: format)
        } catch let error as CodexRuntimeError {
            if case .accountConflict = error {
                try writeJSON(HelperAuthStatusResponse(
                    provider: "openAI",
                    authenticated: false,
                    accountIdentifier: nil,
                    expiresAt: nil,
                    accessibleModelIDs: nil
                ), format: format)
                return
            }
            throw error
        }
    }

    private static func writeJSON<T: Encodable>(_ value: T, format: OutputFormat) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

private enum AuthSubcommand {
    case login(Provider)
    case exportSession(Provider, OutputFormat)
    case status(Provider, OutputFormat)
    case logout(Provider)

    init(arguments: [String]) throws {
        guard let command = arguments.first else { throw AuthCLIError.usage(AuthCLI.usage) }
        let remaining = Array(arguments.dropFirst())
        switch command {
        case "login": self = .login(try Provider(arguments: remaining))
        case "export-session": self = .exportSession(try Provider(arguments: remaining), try OutputFormat(arguments: remaining))
        case "status": self = .status(try Provider(arguments: remaining), try OutputFormat(arguments: remaining))
        case "logout": self = .logout(try Provider(arguments: remaining))
        default: throw AuthCLIError.usage(AuthCLI.usage)
        }
    }
}

private enum Provider: String {
    case openai

    init(arguments: [String]) throws {
        guard let first = arguments.first, let provider = Provider(rawValue: first.lowercased()) else {
            throw AuthCLIError.usage(AuthCLI.usage)
        }
        self = provider
    }
}

private enum OutputFormat: String {
    case json

    init(arguments: [String]) throws {
        if let index = arguments.firstIndex(of: "--format"), arguments.indices.contains(index + 1) {
            guard let format = OutputFormat(rawValue: arguments[index + 1].lowercased()) else {
                throw AuthCLIError.usage(AuthCLI.usage)
            }
            self = format
        } else {
            self = .json
        }
    }
}

private enum AuthCLIError: LocalizedError {
    case usage(String)
    case missingSession

    var errorDescription: String? {
        switch self {
        case .usage(let text): return text
        case .missingSession: return "No authenticated ChatGPT account session was found."
        }
    }
}

struct StoredAccountSession: Codable, Sendable {
    let provider: String
    let accountIdentifier: String
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let tokenType: String?
    let expiresAt: Date?
    let accessibleModelIDs: [String]
    let createdAt: Date
    let id: UUID
}
