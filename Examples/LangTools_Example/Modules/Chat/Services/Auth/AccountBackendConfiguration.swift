import Foundation

public enum AccountBackendDestination: Equatable {
    case codexHelper
    case claudeCodeBackend
}

public enum AccountBackendCredential: Equatable {
    case codexHelperToken(String)
    case accountAccessToken(String)

    public var value: String {
        switch self {
        case .codexHelperToken(let value), .accountAccessToken(let value):
            return value
        }
    }
}

public struct AccountBackendRoute: Equatable {
    public let destination: AccountBackendDestination
    public let baseURL: URL
    public let credential: AccountBackendCredential

    public func endpoint(_ path: String) -> URL {
        baseURL.appending(path: path)
    }
}

public enum AccountBackendConfigurationError: LocalizedError, Equatable {
    case invalidDestination(AccountBackendDestination)
    case missingCredential(AccountBackendDestination)
    case credentialMismatch(AccountBackendDestination)

    public var errorDescription: String? {
        switch self {
        case .invalidDestination(.codexHelper):
            return "The Codex helper URL must use HTTP, a loopback host, and an explicit port, without credentials, a query, or a fragment."
        case .invalidDestination(.claudeCodeBackend):
            return "The Claude Code backend URL must use HTTPS, or HTTP on a loopback host, without credentials, a query, or a fragment."
        case .missingCredential(.codexHelper):
            return "Enter the Codex helper token in Settings before continuing."
        case .missingCredential(.claudeCodeBackend):
            return "The Claude Code account session does not contain an access token."
        case .credentialMismatch:
            return "The account session cannot be used with the selected backend."
        }
    }
}

public struct AccountBackendConfiguration: Equatable {
    public static let callbackScheme = "langtools-example-auth"
    public static let callbackHost = "auth"
    private static let loopbackHosts: Set<String> = ["127.0.0.1", "::1"]

    public let baseURL: URL
    public let codexHelperBaseURL: URL
    public let codexHelperToken: String

    public init(
        baseURL: URL = UserDefaults.accountBackendBaseURL,
        codexHelperBaseURL: URL = UserDefaults.codexHelperBaseURL,
        codexHelperToken: String = UserDefaults.codexHelperToken
    ) {
        self.baseURL = baseURL
        self.codexHelperBaseURL = codexHelperBaseURL
        self.codexHelperToken = codexHelperToken
    }

    public func callbackURL(for provider: AccountLoginProvider) -> URL {
        var components = URLComponents()
        components.scheme = Self.callbackScheme
        components.host = Self.callbackHost
        components.path = "/callback/\(provider.rawValue)"
        guard let url = components.url else {
            preconditionFailure("Failed to build callback URL for \(provider.rawValue)")
        }
        return url
    }

    public func openAILocalhostCallbackURL(port: UInt16, host: String = "127.0.0.1") -> URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = Int(port)
        components.path = "/auth/callback"
        guard let url = components.url else {
            preconditionFailure("Failed to build the OpenAI callback URL.")
        }
        return url
    }

    public func route(for provider: AccountLoginProvider, session: AccountSession) throws -> AccountBackendRoute {
        guard session.provider == provider else {
            throw AccountBackendConfigurationError.credentialMismatch(destination(for: provider))
        }

        switch provider {
        case .openAI:
            guard session.accessToken == CodexSessionMarker.value else {
                throw AccountBackendConfigurationError.credentialMismatch(.codexHelper)
            }
            return try route(to: .codexHelper, credential: .codexHelperToken(codexHelperToken))
        case .claudeCode:
            return try route(to: .claudeCodeBackend, credential: .accountAccessToken(session.accessToken))
        }
    }

    public func codexHelperRoute() throws -> AccountBackendRoute {
        try route(to: .codexHelper, credential: .codexHelperToken(codexHelperToken))
    }

    public func claudeCodeRoute(accessToken: String) throws -> AccountBackendRoute {
        try route(to: .claudeCodeBackend, credential: .accountAccessToken(accessToken))
    }

    public func loginStartURL(for provider: AccountLoginProvider, state: String) throws -> URL {
        guard var components = URLComponents(url: try claudeCodeURL(path: "/auth/\(provider.startPathComponent)/start"), resolvingAgainstBaseURL: false) else {
            throw AccountBackendConfigurationError.invalidDestination(.claudeCodeBackend)
        }
        components.queryItems = [
            URLQueryItem(name: "redirect_uri", value: callbackURL(for: provider).absoluteString),
            URLQueryItem(name: "state", value: state)
        ]
        guard let url = components.url else {
            throw AccountBackendConfigurationError.invalidDestination(.claudeCodeBackend)
        }
        return url
    }

    public func exchangeURL(for provider: AccountLoginProvider) throws -> URL {
        try claudeCodeURL(path: "/auth/\(provider.startPathComponent)/exchange")
    }

    public func logoutURL(for provider: AccountLoginProvider) throws -> URL {
        try claudeCodeURL(path: "/auth/\(provider.startPathComponent)/logout")
    }

    public func modelsURL(for provider: AccountLoginProvider) throws -> URL {
        try claudeCodeURL(path: "/auth/\(provider.startPathComponent)/models")
    }

    public func claudeCodeURL(path: String) throws -> URL {
        try validatedBaseURL(for: .claudeCodeBackend).appending(path: path)
    }

    private func route(to destination: AccountBackendDestination, credential: AccountBackendCredential) throws -> AccountBackendRoute {
        switch (destination, credential) {
        case (.codexHelper, .codexHelperToken), (.claudeCodeBackend, .accountAccessToken):
            break
        default:
            throw AccountBackendConfigurationError.credentialMismatch(destination)
        }
        guard credential.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw AccountBackendConfigurationError.missingCredential(destination)
        }
        return AccountBackendRoute(destination: destination, baseURL: try validatedBaseURL(for: destination), credential: credential)
    }

    private func destination(for provider: AccountLoginProvider) -> AccountBackendDestination {
        provider == .openAI ? .codexHelper : .claudeCodeBackend
    }

    private func validatedBaseURL(for destination: AccountBackendDestination) throws -> URL {
        let url = destination == .codexHelper ? codexHelperBaseURL : baseURL
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil
        else {
            throw AccountBackendConfigurationError.invalidDestination(destination)
        }

        let scheme = components.scheme?.lowercased()
        let host = (components.host?.lowercased() ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        switch destination {
        case .codexHelper:
            guard scheme == "http", components.port != nil, Self.loopbackHosts.contains(host) else {
                throw AccountBackendConfigurationError.invalidDestination(destination)
            }
        case .claudeCodeBackend:
            guard scheme == "https" || (scheme == "http" && Self.loopbackHosts.contains(host)) else {
                throw AccountBackendConfigurationError.invalidDestination(destination)
            }
        }
        return url
    }
}
